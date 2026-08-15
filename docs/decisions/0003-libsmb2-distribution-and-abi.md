# ADR-0003：固定 libsmb2 来源、C ABI 与私有静态链接边界

状态：已接受

日期：2026-08-16

## 背景

Swift reference implementation 的第一个真实数据里程碑是在 Linux 上只读访问 SMB2/3。libsmb2 必须可重复构建，且不能因宿主进程或其他 SDK 同时使用另一版本的 libsmb2 而产生符号抢占、链接顺序依赖或全局安装污染。

libsmb2 的 client library 由上游声明为 LGPL-2.1-or-later。静态链接会产生额外的源码、对象文件和重新链接交付要求。本 ADR 固定工程边界，不构成法律意见；对外发布二进制前仍需完成许可证审查。

## 决策

### 1. 来源与版本固定

- 唯一上游为 [`sahlberg/libsmb2`](https://github.com/sahlberg/libsmb2)。
- reference v1 基线固定到 commit [`aedafb2c8742c83188e27841e270fdaad6035d41`](https://github.com/sahlberg/libsmb2/tree/aedafb2c8742c83188e27841e270fdaad6035d41)。
- 机器可读记录位于 [`third_party/libsmb2.lock.json`](../../third_party/libsmb2.lock.json)。构建脚本必须 checkout detached commit 并核对完整 SHA，不得使用默认 branch、移动 tag 或 `latest`。
- 该提交的 CMake version 是 `6.1.0`。公开头中的 `LIBSMB2_MAJOR_VERSION` 等宏仍报告旧值，不能作为 provenance 或运行时版本判断依据。
- 升级必须单独变更 lock、ADR 证据、symbol map 和兼容性测试，不能随普通功能变更漂移。

### 2. 私有静态构建与隔离

- 所有由本项目提供的 libsmb2 构建均使用 `BUILD_SHARED_LIBS=OFF`、`CMAKE_POSITION_INDEPENDENT_CODE=ON`、`ENABLE_EXAMPLES=OFF`、`ENABLE_LIBKRB5=OFF` 和 `ENABLE_GSSAPI=OFF`。S2 只支持内建 NTLMSSP。
- 构建只写入任务私有且原本为空的 prefix，不使用 `/usr/local`、Homebrew prefix 或其他系统目录，也不执行上游 `cmake --install`。
- 原始 `libsmb2.a` 不进入最终链接。构建脚本枚举 archive 中全部已定义全局 symbol，并使用 GNU `objcopy --redefine-syms` 统一加项目唯一的 `stellar_user_media_sdk_libsmb2_` 前缀，生成 `libstellar_libsmb2_private.a` 后删除原始 archive。
- 私有 prefix 接收编译所需 header、前缀化 archive 和 `stellar-libsmb2-private.pc`，以及 `share/stellar-libsmb2-private` 下的对应源码、许可证、symbol map 和构建元数据；不接收或暴露公共 `libsmb2.a`、`libsmb2.pc`、CMake package 元数据，也不使用 `-lsmb2`。
- 私有 pkg-config 只提供 SwiftPM 允许的私有 `-L`/`-lstellar_libsmb2_private`；该目录不得包含同名 shared object，因此最终仍解析到私有静态 archive。Linux wrapper target 通过 linker setting 加入 `--exclude-libs=libstellar_libsmb2_private.a`，防止内部 symbol 进入最终 ELF 动态导出表。
- `CStellarLibsmb2Private` 只在 Linux Package graph 中存在。其 shim 把允许使用的上游函数名映射到私有前缀；Swift target 禁止直接 import，后续只能 import 项目自有的 allowlisted C wrapper。
- 最终 SDK/CLI 不得产生 `DT_NEEDED`/等价的 libsmb2 共享库依赖，也不得导出未前缀的 libsmb2 symbol。

这三个边界共同防止相互影响：

1. 私有 archive 不受系统动态库版本和加载顺序影响；
2. 全符号前缀防止宿主中的其他静态或动态 libsmb2 满足内部引用；
3. 私有 pkg-config、私有 prefix 和隐藏导出防止 SDK 污染其他库。

### 3. C ABI 基线

首个 binding allowlist：

- context lifecycle：`smb2_init_context`、`smb2_close_context`、`smb2_destroy_context`；
- policy/auth：`smb2_set_timeout`、`smb2_set_version`、`smb2_set_security_mode`、`smb2_set_sign`、`smb2_set_seal`、`smb2_set_authentication`、`smb2_set_domain`、`smb2_set_user`、`smb2_set_password`；
- session/event：`smb2_fd_event_callbacks`、`smb2_connect_share`、`smb2_disconnect_share`、`smb2_get_dialect`、`smb2_get_error`；
- read-only I/O：`smb2_opendir`、`smb2_readdir`、`smb2_closedir`、`smb2_stat`、`smb2_open`、`smb2_pread`、`smb2_close`。

任何 create、write、truncate、unlink、mkdir、rename 或其他 mutating symbol 都不得进入项目自有 C wrapper 或 Swift transport。CI 必须编译、静态链接并运行只读 ABI smoke test。

### 4. Swift 所有权和并发

- `smb2_context`、directory handle、file handle 和 callback userdata 只由一个 session actor/串行执行器拥有，不声明为无条件 `Sendable`，也不跨 executor 裸传。
- 公共 `SMB2Transport`/`SMB2Session` seam 只暴露 Swift 值模型、`Data` 和稳定 SDK errors；C pointer、errno、NT status 与 callback 类型不能穿透模块边界。
- 同步 C API 必须进入专用有界 blocking executor，不能在 Swift cooperative executor 或 actor isolation 上直接阻塞。
- timeout 由 SDK deadline 与 libsmb2 command timeout 共同约束。包装层在连接前登记 libsmb2 的 fd 增删 callback；Swift task 取消时对全部活动 socket 执行 `shutdown()`，使同步 API 的 `poll()` 立即返回，并在原 worker 上以 `ECANCELED` 收尾和释放 context。取消线程不得并发 destroy context。CI 使用不回复 SMB negotiation 的 loopback TCP peer 证明 in-flight 连接在 2 秒内结束并可确定性释放。

### 5. 凭据与日志

- 用户名、domain 和密码通过 setter 传入，不构造含 userinfo/password 的 SMB URL。
- 密码只来自 stdin、Credential Vault 或进程外 secret provider；禁止 CLI `--password` 参数、环境回显、JSON 输出和持久化。
- transport 错误在进入 logger、stderr 或报告前映射到 `SDKError` 并经过统一 redactor。完整主机、用户名和远端路径默认按敏感元数据处理。
- Swift `String` 无法保证可靠清零，因此明文凭据只在连接所需的最小作用域存在。

### 6. LGPL 静态分发

- libsmb2 的 `lib/` 与 `include/` 由上游声明为 LGPL-2.1-or-later；示例代码的 BSD 条款不改变 client library 的许可证。
- 分发含私有静态 archive 的 Linux 或 Apple binary 时，必须提供上游 copyright、许可证全文、固定 commit、完整对应源码和本项目使用的构建/symbol-prefix 修改材料。
- 分发包还必须提供适合重新链接的应用/SDK object code 或其他经审查的等效材料、重新链接说明及必要安装信息，使接收者能够用修改后的兼容 libsmb2 重新生成组合产物。
- 商业条款不得禁止用户为调试这些修改而进行许可证允许的 reverse engineering。
- symbol prefix 属于构建隔离步骤；relink kit 必须包含可重建相同前缀 archive 的脚本和 map 生成方式，不能只提供已经前缀化的二进制。
- `create_linux_smb_lgpl_kit.sh` 从正式 release 的 SwiftPM `Objects.LinkFileList` 收集组合产物 object code，加入固定源码、许可、集成源码、原始私有 archive、修改后库重建脚本、重链接脚本和逐文件 SHA-256 manifest。CI 必须从交付的源码重新构建私有 archive，再用交付 object 实际生成并运行替换后的 executable。
- Apple backend 也只能采用同样的私有静态隔离，但在 object/relink kit、代码签名、重新安装和商店分发义务完成审查前不得启用或发布。

## 后果

优点：

- 运行时不依赖系统或宿主提供的 libsmb2；
- 同一进程存在其他 libsmb2 时不会发生 symbol 抢占或重复定义冲突；
- 构建不安装公共 header、archive 或 pkg-config 记录；
- scanner 和 Swift transport 仍与具体 C 实现隔离。

代价：

- Linux 构建需要 CMake、pkg-config、C compiler、GNU nm/objcopy/ranlib；
- 每次升级都要重新验证全量 symbol prefix 和 allowlist；
- 静态分发需要维护源码、对象文件和可执行的 relink kit，许可证交付成本高于共享库方案；
- Apple SMB 发布继续受 LGPL 与代码签名审查阻断。

## 验收

- lock 中 SHA 与 checkout `HEAD` 完全一致；
- 构建目录之外不存在新增的系统级 `libsmb2.pc`、header 或 library；
- 最终 archive 名为 `libstellar_libsmb2_private.a`，全部已定义全局 symbol 以 `stellar_user_media_sdk_libsmb2_` 开头；
- pkg-config flags 包含私有静态 archive，不包含 `-lsmb2` 或 `.so`；
- ABI smoke binary 在强制 `--export-dynamic` 时仍不暴露私有前缀 symbol，能够运行，且 `ldd`/等价检查不包含 libsmb2；
- 最终 SDK/CLI 不导出未前缀的 libsmb2 symbol；
- C/Swift public API 不出现 libsmb2 私有类型；
- 对外发布物带有许可证、对应源码、对象文件和经过验证的 relink instructions。

## 上游证据

- [固定 commit](https://github.com/sahlberg/libsmb2/tree/aedafb2c8742c83188e27841e270fdaad6035d41)
- [CMake static/shared build option](https://github.com/sahlberg/libsmb2/blob/aedafb2c8742c83188e27841e270fdaad6035d41/CMakeLists.txt)
- [高层 C API header](https://github.com/sahlberg/libsmb2/blob/aedafb2c8742c83188e27841e270fdaad6035d41/include/smb2/libsmb2.h)
- [上游许可证说明](https://github.com/sahlberg/libsmb2/blob/aedafb2c8742c83188e27841e270fdaad6035d41/COPYING)
- [GNU objcopy symbol 重命名](https://sourceware.org/binutils/docs/binutils/objcopy.html)
- [GNU ld archive export 隐藏](https://sourceware.org/binutils/docs/ld/Options.html)
- [LGPL-2.1 全文](https://www.gnu.org/licenses/old-licenses/lgpl-2.1.html)
- [GNU FAQ：LGPL 静态链接](https://www.gnu.org/licenses/gpl-faq.html#LGPLStaticVsDynamic)

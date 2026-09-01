# Swift Reference Implementation Plan

最后核对日期：2026-08-18

当前阶段：**S6 — OAuth、来源配置与凭据同步**

目标工具链：Swift 6.3.x、Swift 6 language mode  
最低 Apple 平台：iOS/iPadOS 17、macOS 14、tvOS 17

本文是 `StellarUserMediaSDK` 的 Swift 实施顺序和完成状态入口。产品与跨语言行为以 [`specs/`](../../specs/README.md) 为准；本文只决定 Swift reference implementation 如何实现、验证并交付这些合同。

## 1. 实施策略

采用 **contract-first、Swift-first、fixture-driven**：

1. 先把行为写入语言无关规范、DDL 或 JSON fixture。
2. Swift 作为第一份完整 reference implementation，同时提供 macOS/Linux CLI。
3. 每个里程碑必须产生可供 Kotlin 和 ArkTS 重放的输入、输出和错误样本。
4. Swift 通过 reference v1 验收后，其他语言实现同一合同，而不是逐行翻译 Swift。

Swift 实现不是规范本身。`Codable` 默认行为、Foundation 类型、actor、Keychain、`ASWebAuthenticationSession`、GRDB 和 libsmb2 的私有类型不得进入跨平台 wire format。

### Swift Reference v1 范围

v1 必须包含：

- Core 合同、错误、日志脱敏、取消和公共 fixtures；
- Stellar OAuth session、来源配置同步和明文 `CredentialRecord` 客户端；
- 本地目录、SMB2/3、WebDAV 三种只读文件型来源；
- 可恢复 scanner、SQLite v1、文件名/NFO 解析、媒体物化和 PosterWall 查询；
- macOS/Linux CLI，以及 StellarPlayer iOS 的正式集成。

v1 不包含：

- 解码、转码、播放器 UI 或 SwiftUI PosterWall 组件；
- 远端文件写入/删除；
- Jellyfin、Plex、Google Drive、OneDrive 等后续 provider；
- 在 SDK 仓库内实现 Stellar 云服务本身。SDK 必须提供 transport、fake service 和 staging contract tests，服务端单独交付。

## 2. 已固定的工程决策

| 项目 | 决策 |
| --- | --- |
| Swift | 使用最新稳定 Swift 6.3.x；Package tools version 6.3；Swift 6 严格并发 |
| Apple 兼容基线 | SDK 最低 iOS/iPadOS 17、macOS 14、tvOS 17；当前 StellarPlayer App 最低 iOS 18，可直接消费 SDK |
| Linux 角色 | 正式支持 Core、Storage、SMB connector 和 CLI；Linux 是首个 SMB2 扫库验收环境，不只是偶发开发宿主 |
| Windows 角色 | reference v1 冻结前完成 Core/CLI 编译验证；不阻断首个 Linux SMB 验收 |
| SMB | 使用 libsmb2；首版只读，禁止创建、修改、重命名或删除远端文件 |
| SQLite | 共享 SQLite DDL；Swift 优先沿用 GRDB 7.11.1，必须自行维护 Linux CI 与迁移测试 |
| 凭据 | 第三方媒体源凭据以应用层明文 `CredentialRecord` 存入本地 SQLite 和云端；不增加设备批准、恢复或独立解锁；保留未来加密升级字段 |
| 播放 | SDK 只返回 `PlayableResource`；不依赖 KSPlayer、FFmpegKit、SwiftUI 或播放器 View |
| UI | v1 PosterWall 是数据查询 API，不在本 SDK 中交付 SwiftUI 组件 |
| 依赖版本 | 所有第三方依赖精确固定；升级使用独立变更并重新执行跨平台合同测试 |

## 3. 当前事实

已经完成：

- Swift 6.3 Package，导出 `StellarUserMediaSDK` library 与 `stellar-media` executable；
- `StellarCore`、`StellarRemoteMedia`、`StellarLocalMedia`、`StellarWebDAV` 和 `StellarMediaLibrary` 已拆分为独立 target，并保留 umbrella SDK 兼容入口；
- 可注入 clock、UUID、logger、retry 和 cancellation Core runtime；
- URL、Header、路径、用户名、密码和 token 的统一 redaction API，CLI stderr 已接入；
- `FieldPresence`、epoch 毫秒和 `CursorPage` wire contract 及公共 fixture；
- iOS 17、macOS 14、tvOS 17 最低版本；
- 公共错误模型、`CredentialRecord` wire model；
- 最小电影/剧集文件名 parser；
- repository-wide parser fixture；
- 108 个 Swift Testing 测试，macOS debug/release 构建已通过；
- GitHub Actions 已在 macOS 26 与 Ubuntu 24.04 首次实际通过对等验证，并固定第三方 Action SHA；
- SwiftPM exact/revision 依赖锁定门禁，以及 10 个公开模块、1582 个 symbol 的 API compatibility 基线；
- libsmb2 来源/ABI/私有静态链接 ADR、机器可读 lock、全符号前缀和 C ABI smoke guard；
- 不依赖真实服务器的 `SMB2Transport` / `SMB2Session` seam、只读值模型和 fake transport 合同测试；
- allowlisted C wrapper、Linux `LinuxSMB2Transport`、有界 blocking executor，以及连接、枚举、`stat`、range read 和确定性释放实现；
- Linux CLI 的 `smb check`、`smb list`、`smb scan`，密码只从 stdin 读取；
- 来源无关的 `RemoteLocator`、`RemoteEntry`、connector 能力、路径比较语义和公共枚举 fixture；
- full/scoped incremental/repair scanner 状态机、有界目录队列、原子 page checkpoint 和公共扫描 fixture；
- macOS/Linux 本地目录 connector、SMB transport adapter、WebDAV URLSession/transport seam，以及三者的统一 scanner tests；
- 明文凭据同步规范和 ADR；历史 Credential Vault 方案已被取代。
- 本地元数据摄取合同 v1、sidecar 分类、受限 Kodi NFO 解析，以及可注入的技术探测模型与协议。
- 文件名噪声/provider 证据、本地 JSON 解析，以及 filename/sidecar/NFO/JSON/probe 的 SQLite 原子摄取。
- provider 查询协议、NFO/文件名查询证据合并，以及可由公共 fixture 重放的确定性候选评分与决策。
- 具体 TMDB v3 adapter、details/图片配置模型、运行时 `api_key`/Bearer 鉴权与录制响应清洗流程。
- 原子 search document 重建，以及人工锁、播放状态和未上传 outbox 保全测试。
- `MediaSourceConfig` v1、配置/墓碑原子 outbox，以及受限 `CredentialPayload` v1 和跨语言 fixtures。
- 独立 `StellarAuth` target，包含 Gateway OAuth + PKCE、严格回调校验、session actor、单飞 refresh、多账户、撤销和非交互 Data Protection Keychain。
- 已签名的 `examples/swift/StellarOAuthDemo`，并于 2026-08-18 在真机通过 claimed HTTPS 登录、Keychain 会话恢复、资料/令牌刷新、账户切换和注销验收；全程无生物识别、设备密码或运行时权限弹框。

尚未完成：

- 尚未产生独立 target 的 Sync 与 `StellarApplePlatform`；Apple OAuth presenter 目前以条件编译形式位于 `StellarAuth`；
- Windows compile check；
- SMB3 encryption 的客户端合同与 server-free 测试已经完成；当前没有可用的隔离加密服务，真实服务验收推迟到 release candidate，不阻断 S2；
- 同步 transport、远端 apply/conflict 与服务端验收；
- StellarPlayer iOS 正式集成。

## 4. 目标 Package 架构

targets 在第一次产生真实代码时建立，不创建只有空目录的模块。

```mermaid
flowchart TD
    Core["StellarCore\n模型/错误/JSON/日志/取消"]
    Remote["StellarRemoteMedia\n来源与 connector 合同"] --> Core
    CSMB["CStellarLibsmb2Private\nLinux 私有静态 C module"]
    SMB["StellarSMB2Core\nSMB 公共语义"] --> Remote
    SMBLinux["StellarSMB2Linux\n直接调用 libsmb2"] --> SMB
    SMBLinux --> CSMB
    SMBApple["StellarSMB2Apple\nApple 兼容 backend"] --> SMB
    WebDAV["StellarWebDAV\n只读 WebDAV connector"] --> Remote
    Local["StellarLocalMedia\n本地目录 connector"] --> Remote
    Storage["StellarStorage\nGRDB/SQLite/迁移"] --> Core
    Library["StellarMediaLibrary\n扫描/解析/物化"] --> Remote
    Library --> Storage
    Wall["StellarPosterWall\n查询/分页/搜索"] --> Library
    Auth["StellarAuth\n会话状态机/PKCE 合同"] --> Core
    Sync["StellarSync\n配置/凭据/outbox"] --> Auth
    Sync --> Storage
    Sync --> Remote
    Apple["StellarApplePlatform\nKeychain/ASWebAuthenticationSession"] --> Auth
    Facade["StellarUserMediaSDK\n公共 facade"] --> Wall
    Facade --> Sync
    CLI["stellar-media CLI"] --> Library
    CLI --> SMBLinux
    CLI --> WebDAV
    CLI --> Local
```

约束：

- `StellarCore`、`StellarRemoteMedia`、`StellarStorage`、`StellarMediaLibrary` 和 CLI MUST 在 macOS 与 Linux 构建。
- Apple framework import 只能出现在 `StellarApplePlatform` 或明确的 Apple backend target。
- libsmb2 context、file handle 和 C callback userdata 不得声明为无条件 `Sendable`；由 actor 或单一执行器拥有。
- CLI 只调用 SDK 公共 API，不维护另一份扫描、解析或数据库业务逻辑。
- Linux 的 `CStellarLibsmb2Private` 通过私有 `stellar-libsmb2-private.pc` 解析全符号前缀的静态 archive，并通过条件 target dependency 与 Apple backend 隔离。不得安装或解析公共 `libsmb2.pc`；Apple backend 采用同样的私有静态隔离并由 ADR 固化 LGPL relink kit 边界。

## 5. 依赖基线与待决 ADR

| 依赖 | 初始基线 | 用途 | 合入前要求 |
| --- | --- | --- | --- |
| libsmb2 | 以 StellarPlayer 已验证的 `aedafb2c8742c83188e27841e270fdaad6035d41` 为兼容基准 | SMB2/3 连接、枚举、stat、range read | ADR：源码固定、私有静态 archive、全符号前缀、LGPL relink kit |
| GRDB.swift | 精确版本 7.11.1 | SQLite 连接、迁移、事务和查询 | Linux debug/release、WAL、migration、`foreign_key_check` 全部进入 CI |

必须先完成的 ADR：

1. libsmb2 获取、固定版本、私有静态链接和 Apple/Linux 分发方式；
2. SQLite/GRDB 采用方式、数据库文件布局和 DDL 所有权；
3. 第三方凭据同步、访问控制和未来保护模式迁移边界；
4. StellarPlayer iOS 现有媒体库向 SDK 迁移及旧数据库清理策略。

## 6. 里程碑

### S0 — Package 与合同基线 ✅

目标：让最小 SDK 和 CLI 可构建，并证明公共 JSON 合同可以被 Swift 实现。

完成项：

- [x] 初始化 Swift 6.3 Package；
- [x] 建立 library、CLI 和 Swift Testing target；
- [x] 实现错误模型、文件名 parser 和版本化凭据记录 model；
- [x] 建立第一个公共 fixture；
- [x] macOS debug tests 和 release build 通过。

完成定义：当前已有的 8 个测试通过，`stellar-media parse` 输出规范化 JSON。

### S1 — 模块边界与跨平台构建 ✅

目标：在加入 C、数据库和 Apple framework 前固定依赖方向，让 Linux 不被后续 Apple 代码破坏。

工作：

- [x] 按第 4 节拆分现有 target，保留 umbrella product；
- [x] 为时钟、UUID、日志、重试和取消建立可注入接口；
- [x] 建立统一 redaction API，覆盖 URL userinfo、Header、路径、用户名、密码和 token；
- [x] 明确未知枚举、缺失与 `null`、epoch 毫秒、游标分页的 Swift 编码策略；
- [x] 建立 macOS 与 Ubuntu 的 Swift 6.3 CI；
- [x] CI 执行 format lint、debug tests、release build、fixture tests 和 secret scan；
- [x] 建立依赖解析记录门禁，禁止浮动 branch/range；S1 完成时没有外部依赖，S4 引入 GRDB 后提交精确解析记录；
- [x] 为 public API 加入最小顶层 DocC 注释与 API compatibility 基线。

完成定义：同一 commit 在 macOS 和 Linux 上执行 Core/CLI tests；代码中没有未经条件隔离的 Apple import；fixture 输出语义一致。

完成证据：初始 commit `d1b8b2e` 已在 GitHub-hosted macOS 26、Ubuntu 24.04 和 repository guards 全部通过；后续 S3 run `31907420283` 继续证明两端 symbol graph 一致。CI 拒绝 SwiftPM branch/range；新增外部依赖要求 exact version 或 immutable revision 并提交 `Package.resolved`。`API/PublicAPI.json` 当前固定 10 个公开模块、1582 个 symbol，API 有意变化必须显式更新并审阅 baseline diff。

### S2 — Linux libsmb2 只读纵向切片 ✅

目标：在 Linux 上用真实 SMB2/3 来源完成连接、递归枚举和验收报告，这是首个生产数据路径。

范围：首版只支持用户提供 server、share、root、domain、username/password 的 NTLMSSP 连接。Kerberos、DFS、写操作和 share discovery 不阻断本里程碑。

工作：

- [x] 完成 libsmb2 ADR，固定 C ABI 基线与许可证交付方式；
- [x] 建立 `CStellarLibsmb2Private` module map、私有 shim、固定静态构建、全符号前缀和 C ABI smoke 检查；
- [x] 建立 `SMB2Transport` seam，使单元测试不需要真实服务器；
- [x] 建立项目自有 allowlisted C wrapper，公开 header 不暴露任何 libsmb2 类型；
- [x] 封装 context、directory/file handle 的唯一所有权和确定性释放；
- [x] 实现连接、NTLMSSP 认证、目录枚举、`stat` 和分块 range read；
- [x] 映射取消、超时、认证、权限、网络、远端不可用和协议错误；
- [x] 支持 SMB 2.1、3.0、3.1.1 协商信息记录，以及可配置 signing/encryption 要求；
- [x] 所有 transport 方法保持 `async throws`，同步 C API 只在最多 4 个 worker 的专用 blocking executor 运行，并在调用前后检查取消；
- [x] 通过 libsmb2 fd callback 跟踪活动 socket，Swift task 取消时主动 `shutdown()` 中止 in-flight C 调用；loopback 黑洞 peer 验证连接在 2 秒内返回 `ECANCELED` 并确定性释放；
- [x] CLI 新增以下命令：

```text
stellar-media smb check
stellar-media smb list
stellar-media smb scan
```

- [x] 当前 CLI 密码只允许从 stdin 输入；明确拒绝 `--password <value>` 和带密码的 SMB URL，账户同步/进程外 secret provider 留待 Sync 集成；
- [x] `smb scan` 输出不带路径的 JSONL 条目与单独 summary，包含 schema、source、范围、开始/结束时间、结果、错误分类和 libsmb2 版本，不包含完整主机、用户名、密码或敏感路径；
- [x] 真实 NAS 使用明确批准的隔离资源完成手动验收；鉴于真实环境验收已经通过，CI 不再重复启动临时 Samba 执行 SMB 冒烟；
- [x] 构建生成 LGPL 许可证、固定 commit 完整对应源码和 symbol map；release kit 加入 SwiftPM object code、集成源码、重建/重链接脚本和 SHA-256 manifest，并从交付源码实际重建替换 archive 后重链接验证。

验收矩阵：

- 空目录、单文件、深层目录、大目录；
- 空格、emoji、CJK、组合 Unicode、点文件和无扩展名文件；
- 正确凭据、错误密码、无权限目录、来源离线、扫描中断和超时；
- SMB 2.1/3.x、要求 signing；要求 SMB3 encryption 的客户端配置、错误和 fake transport 合同测试必须通过，真实加密服务验收推迟到 release candidate；
- 重复扫描结果稳定；扫描过程不执行任何远端写操作；
- 密码不会出现在 argv、stdout/stderr、JSONL、日志、core dump 测试字符串或 CI artifact。

完成定义：Ubuntu release binary 能针对至少一个获准的真实 SMB2/3 来源完成只读扫描；取消/失败不会生成“完整成功”标记；报告可用于后续 scanner fixture。当前无可用的 SMB3 encryption 隔离服务，因此真实加密服务不属于本阶段完成门禁。

完成证据：macOS 已通过 26 个 Swift 测试和 API/依赖/secret/import guards。Ubuntu 26.04 已从固定 libsmb2 6.1.0 commit 重建全符号前缀静态 archive，通过 C ABI/主动取消 smoke、28 个 Swift 测试、公共 API guard 和无额外参数的 release CLI 构建；Swift `Task.cancel()` 黑洞连接测试在 2 秒门限内返回 `.cancelled`，实际为毫秒级。最终 ELF 内含私有 archive，相关 symbol 为 local，动态导出和 `DT_NEEDED` 均不含 libsmb2。LGPL kit 已从包内完整源码重建替换 archive，并用 15 个交付 object 重链接、运行及复核静态隔离。隔离真实 NAS 已使用 kit 重链接 binary 通过 SMB 2.1、3.0、3.0.2、3.1.1、required signing、递归重复扫描、`stat`、range read、离线失败和错误凭据分类验收。该 NAS 不支持 SMB3 encryption，已用 Samba 客户端对照确认；客户端的 required-encryption 配置和失败语义由 server-free 合同测试覆盖，真实加密服务验收明确推迟到 release candidate。

### S3 — Scanner 状态机与公共扫描 fixture ✅

目标：把“列目录”提升为可恢复、可判断覆盖范围的媒体扫描，不依赖具体来源实现。

工作：

- [x] 定义 `RemoteLocator`、`RemoteEntry`、能力、稳定 ID、路径大小写和 Unicode 语义；
- [x] 实现 full、scoped incremental、repair 三种 scan mode；
- [x] 实现有界并发目录队列、背压、取消、checkpoint 和进度事件；
- [x] 只有完整覆盖且成功结束的扫描才有资格协调 missing；
- [x] 来源不可达、认证失败、分页中断、取消或超时时禁止把未看到的文件标记为删除；
- [x] 建立本地 fake connector，覆盖分页、重复条目、顺序变化、移动、删除、循环/异常路径和断线恢复；
- [x] 实现 macOS/Linux 本地目录只读 connector；Apple security-scoped bookmark 适配留到 S7；
- [x] 实现 WebDAV 只读 connector，覆盖验证、PROPFIND 分页/目录、`stat`、Range read、鉴权失效和 TLS 错误；
- [x] 本地目录、SMB 和 WebDAV 通过同一套 connector/scanner contract tests；
- [x] 扩展文件名 parser fixture，覆盖电影、剧集、季、集、多版本、样片和无法识别文件；
- [x] CLI 支持扫描 manifest 的重放与规范化 snapshot 比较。

完成证据：来源枚举合同 v1、scanner 状态机、Swift 公共模型、`remote-enumeration-v1.json` 与 `scanner-state-v1.json` 已建立。Scanner 对根执行 `stat` 预检，以最多 32、默认 4 个并发目录请求分页遍历；每页 entries 与 checkpoint 经 `MediaScanSink` 原子提交，只有 batch 成功后内存状态才前移，pending queue 保留其他 in-flight 请求以支持安全重放；最终 completion 是唯一 missing 授权边界。fake connector 已覆盖分页重复、顺序变化、persistent-ID 移动、删除、重复 cursor、异常路径、断线续扫、取消、存储提交失败和并发上限。本地 connector 使用目录清单指纹令分页期间的变化失败关闭，并阻止 symlink 越出配置根；SMB adapter 和 WebDAV connector 复用同一 scanner，WebDAV 另覆盖跨 origin href、鉴权和 TLS 分类。parser fixture 已扩展到 series/season、多集、edition 和 sample；release CLI 可重放 `scanner-state-v1.json` 并比较规范化 snapshot。GitHub Actions run `31907420283` 已在 macOS 26 与 Ubuntu 24.04 通过 Swift 6.3.3 API baseline、47 个测试、debug/release build、公共 fixtures、依赖/format/secret/import/libsmb2 guards；Ubuntu 另通过私有静态 libsmb2、主动取消和 LGPL relink kit 验证。

完成定义：同一 fixture 重复扫描幂等；中断后续扫不会丢失已提交工作；不完整枚举不能产生删除；本地目录、SMB、WebDAV 和 fake connector 通过同一 scanner contract tests。

### S4 — SQLite v1 与扫描入库 ✅

目标：让 macOS/Linux 使用同一 DDL 把扫描结果安全物化为可查询媒体库。

工作：

- [x] 从现有 27 表设计提取版本化 `library.sqlite` DDL；
- [x] 定义 `account.sqlite` 的来源、明文 `CredentialRecord`、outbox 与 cursor 表；
- [x] 定义可删除的 `metadata_cache.sqlite`；
- [x] 完成 GRDB/SQLite ADR，并精确固定 GRDB 7.11.1；
- [x] 每条连接启用 foreign keys、WAL、busy timeout；写入由单一 writer actor 协调；
- [x] 实现空库创建、逐版本 migration、checksum、`foreign_key_check` 和失败保留原库；
- [x] 扫描批次使用短事务；正式快照、完成标志与 missing diff 位于同一原子边界；
- [x] 实现 transactional outbox，业务行清理不能级联删除未上传事件；
- [x] CLI 新增 `db migrate`、`db verify`、`library scan`、`library inspect`；
- [x] 测试空库、中断扫描、未知枚举、大型 fixture、数据库损坏和取消；v1 是首个正式版本，没有上一版迁移样本。

完成证据：`specs/storage/sql/` 是三端 SQL 唯一合同入口，manifest 固定 `library` 27 表、`account` 6 表与 `metadata_cache` 3 表的 application ID、版本、表数和 SHA-256。Swift 精确固定 GRDB 7.11.1，并交付 `StellarStorage`、事务迁移、只读 verify、`LibraryStore`、`AccountStore` 与 `SQLiteMediaScanSink`。`CredentialRecord` 与 outbox 在同一事务提交，operation UID 幂等且业务行清理不会级联丢失 outbox。公共 scanner fixture 产生规范化数据库 snapshot；重复 full scan 幂等，真正的 persistent stable ID 移动复用原文件事实，本地 `device:inode` 只声明为 scan scope 以避免 Linux inode 复用误判移动，scoped incremental 只协调范围内 missing，分页中断或任务取消会保留 checkpoint 且不误标现有文件。GitHub Actions run `31909219766` 已在 macOS 26 通过 57 个测试，在 Ubuntu 24.04 通过 59 个测试；双端 release build、API/依赖/格式/CLI 门禁以及三库 DDL/checksum/foreign key 检查均通过，Ubuntu 另通过私有静态 libsmb2 隔离和包含 SQLite 链接的 LGPL relink kit 验证。

完成定义：macOS/Linux 使用同一 DDL checksum；同一 scanner fixture 产生一致的规范化数据库 snapshot；迁移失败不覆盖旧库；`foreign_key_check` 为零。

### S5 — 媒体物化、元数据与 PosterWall ✅

目标：从文件事实生成电影/剧集实体，并提供播放器需要的媒体库查询。

工作：

- [x] 完善文件名 parser、NFO、sidecar 和基础技术信息接口；
  - [x] 固定 metadata intake v1 合同与公共 fixture，实现同目录 NFO/JSON/字幕/图片/章节分类；
  - [x] 实现 2 MiB 上限、拒绝 DTD/entity 的 Kodi NFO parser，规范化标题、季集、外部 ID 与 artwork；
  - [x] 实现来源无关的技术摘要、轨道结果与可注入 range-read probe 协议；
  - [x] 扩展文件名候选/噪声证据，实现本地 JSON，并把 sidecar/NFO/probe 结果原子写入 SQLite；
- [x] provider 查询通过协议注入，单元测试使用录制/合成响应，不要求真实 TMDB key；
  - [x] 固定 `MediaMetadataProviding` 搜索协议与合成 provider 测试，不持有或要求真实 TMDB key；
  - [x] 实现具体 provider adapter、details/图片响应模型和录制响应脱敏流程；
- [x] 实现候选生成、评分、低置信度队列、人工锁定和多版本绑定；
  - [x] 固定 local metadata/文件名查询优先级、外部 ID 直达、类型/标题/年份/剧集存在性评分与三档决策；
  - [x] 持久化低置信度队列，保护人工锁定，并实现同实体多版本绑定；
- [x] 物化 movie、series、season、episode、extra 与 external IDs；
- [x] 实现最近添加、继续观看、电影、剧集、类型、片单、搜索和稳定游标分页；
- [x] 建立 poster/backdrop 选择、缓存索引和预取接口；
- [x] provider 失败不能删除本地文件事实，也不能覆盖人工匹配；
- [x] CLI 新增 `library list/search/show`，输出与 PosterWall fixture 对齐。

完成证据：`metadata-intake-v1.json` 已固定文件名噪声/provider 证据、6 个 sidecar 关联样本、2 个 NFO、1 个本地 JSON 规范化样本和 1 组多轨技术结果；`metadata-matching-v1.json` 固定电影、alias、剧集存在性、缺集拒绝和外部 ID 直达结果；`metadata-match-persistence-v1.json` 固定 review → 人工锁定、锁定保护、同实体 primary/version 绑定、series → season → episode 物化，以及 extra 幂等继承。`SQLiteMediaMetadataStore` 原子写入 parse、完整 sidecar 集与成功 probe，任一行失败时整体回滚且无新成功 probe 时保留上次结果。`SQLiteMediaMatcher` 把 review 候选写入可删除缓存，把自动/人工决定写入核心库；事务内再次保护人工锁，provider 失败不改变已有绑定。`TMDBMetadataProvider` 使用可注入 transport，支持运行时 v3 `api_key` query 与兼容 Bearer header，覆盖 movie/TV 搜索、外部 ID、episode 存在性、details 和图片配置；`tmdb-provider-v1.json` 只包含经脚本去除 Authorization、Cookie、`api_key` 和 token 字段的响应。`StellarPosterWall` 已成为独立 target；`poster-wall-v1.json` 固定 title pagination、最近添加、继续观看、搜索、类型、片单、选图、剧集详情和轨道投影。cursor 绑定规范化查询与内容 revision，库变化后失败关闭；电影/剧集聚合多版本可用性，详情返回 playable files 与 season/episode 层级。`LibraryStore.rebuildSearchDocuments()` 在单一事务重建派生搜索索引，成功与注入失败测试均证明人工锁、播放状态和待上传 change log 不变。离线纵向测试已贯通 fake SMB connector → scanner → SQLite → 电影物化 → PosterWall JSON。CLI 复用同一 API 提供 `library list/search/show`。S5 完成时 macOS 共 107 个测试；debug tests、release build、format、1582-symbol API baseline、依赖、schema、secret、portable import、libsmb2 provenance 和 fixture 清洗幂等门禁均通过。

完成定义：从 SMB fixture 扫描到数据库，再到海报墙 JSON 查询形成完整离线纵向路径；重建派生索引不会丢失人工状态、播放状态或 outbox。

### S6 — OAuth、来源配置与凭据同步 ⬜

目标：实现账户会话和无需额外批准、恢复或独立解锁的跨平台来源同步。

工作：

- [x] 实现 Authorization Code + PKCE、`state` 校验、session actor、单飞 refresh、退出/撤销和 reauthentication；只有服务升级为 OIDC 并返回 ID token 时才增加 `nonce`、issuer 和 audience 校验；
- [x] Stellar OAuth token 每设备独立，不进入来源凭据同步：access token 优先只驻留内存，refresh token 进入平台安全存储；Apple backend 全程使用 Data Protection Keychain、默认私有 access group、`ThisDeviceOnly`、非交互 `LAContext`，禁止 `kSecAttrAccessControl`/LocalAuthentication evaluate/共享 entitlement 依赖，确保零 Face ID/Touch ID/设备密码弹框和零运行时权限请求；
- [x] 实现 `MediaSourceConfig` v1、revision、tombstone、SQLite repository 和 config outbox；
- [ ] 实现远端配置 apply、冲突保存/解决和配置变更触发 scanner；
- [x] 采用 ADR-0005，固定 v1 `CredentialRecord` 为应用层明文，并保留 `protection_mode`、稳定 UID、revision、tombstone 和可选受保护字段作为未来迁移边界；
- [x] 实现受限 `payload_json` schema、record repository、字段大小限制和 redaction；当前客户端只创建/使用 `plaintext`，遇到未来未知或受保护模式失败关闭且不产生 outbox；
- [ ] 新设备完成 Stellar OAuth 后直接拉取来源配置和凭据，不需要旧设备批准、恢复口令、Vault key 或生物识别；
- [ ] 实现可替换 sync transport 与 deterministic fake server；staging 服务可用后执行真实 pull/push/revoke 验收；
- [ ] 建立跨语言 fixtures，覆盖创建、更新、冲突、删除、未知 schema/protection mode 和幂等重放；
- [ ] 验证本地 SQLite、同步请求和服务端受限存储可以正确读取测试 payload；同时验证普通日志、崩溃报告、分析事件、URL 和非受限诊断导出不出现凭据。

阶段性证据：`source-config-sync-v1.json` 固定 SMB 来源配置、未知 capability 保留、规范排序和删除墓碑；`AccountStore.saveMediaSourceConfig` 在单一事务写配置与完整 outbox payload，重复 operation 幂等，跨 entity operation UID、配置改绑账户和 payload 冲突均回滚。`credential-payload-v1.json` 固定 username/password、OAuth token、API token、cookie 和 key pair 五种 allowlisted shape，以及未知字段/auth/schema、混合字段、重复 cookie scope 和缺失必填值的拒绝行为。repository 在写 SQLite 前复核 payload、record kind、64 KiB 上限与 plaintext-only 边界，公开 description 不返回 payload、endpoint 或路径。`StellarAuth` 已按真实开发 Gateway Metadata 实现 PKCE S256、严格 callback、Token/Profile/Revocation transport、session actor、20 路单飞 refresh、多账户存储和非交互 Data Protection Keychain；`gateway-oauth-v1.json` 固定公开协议响应。Gateway 已发布 `stellarplayer-ios-demo` 移动端 Public Client Policy 和精确 claimed HTTPS 回调；2026-08-18 已使用已签名的 `examples/swift/StellarOAuthDemo` 在真机完成登录、Keychain 冷启动恢复、资料/令牌刷新、账户切换和注销验收，全程无生物识别、设备密码或运行时权限弹框。当前 macOS 108 个 Swift Testing 测试通过。远端配置 transport、cursor apply 和冲突记录仍未完成，S6 继续保持未完成。

完成定义：用户在第二台隔离设备完成 Stellar OAuth 后，无额外操作即可同步并使用 SMB 凭据；服务端按账户授权隔离且可以读取 v1 明文；Apple 首次保存、冷启动恢复、前后台刷新、登出和遗留受保护 item 均不弹认证 UI、不申请运行时权限；密码更新、冲突、删除、登出和未知保护模式均通过。

### S7 — StellarPlayer iOS 集成与数据迁移 ⬜

目标：让 `StellarPlayer_iOS` 使用本 SDK 的正式数据路径，并退役重复实现。

现有资产：App 已有 `Modules/StellarMediaLibrary`、GRDB 7.11.1、`MediaLibraryStore`、SMB/WebDAV provider boundary、来源浏览和 Direct Play。它们作为行为基线和迁移来源，不与 SDK 长期双轨演进。

工作：

- [ ] 建立现有 App 模型/API 到 SDK 模型/API 的映射表；
- [ ] 把可复用领域行为和 GRDB migration 迁入 SDK，保留语言无关合同；
- [ ] 为 App 提供薄 adapter，保持 `PlaybackStore` 和 `KSPlaybackEngine` 不依赖 SDK 内部实现；
- [x] Apple SMB backend 复用只读 libsmb2 transport，提供固定 commit、全符号前缀的 macOS/iOS device/simulator XCFramework，并通过与 Linux 相同的 connector contract、主动取消、C ABI 和双 iOS destination 编译门禁；Apple 对外发布仍受 S8 LGPL application relink/code-signing 审查约束；
- [ ] Apple WebDAV backend 与 SDK WebDAV connector 做行为对等，最终只保留一个正式实现或一个明确的薄适配层；
- [ ] SDK `PlayableResource` 适配为 App 的运行期播放候选；凭据不得进入持久化队列或普通日志；
- [ ] 用真实扫描 repository 替换 `DemoMediaCatalogProvider`；
- [ ] 迁移来源、选择范围、目录快照和凭据引用；所有 migration 可重试并保留回滚副本；
- [ ] 当前 App SQLite 中的媒体源凭据迁移为 `CredentialRecord(protection_mode=plaintext)`，保持稳定引用并清理重复旧字段；回滚副本、WAL 和迁移日志必须按凭据数据限制访问；
- [ ] 行为对等并经过至少一个版本验证后，删除或明确冻结 App 内重复的媒体库实现；
- [ ] 更新 App 产品规范、媒体库架构和 PLAN 状态；
- [ ] 执行 App Package tests、Debug/Release simulator build、静态分析和 SMB 真机回归。

完成定义：StellarPlayer 媒体库不依赖演示 provider；来源管理、扫描、查询和 Direct Play 经过 SDK；App 中不存在第二份继续演进的 scanner/DDL/sync 规则。

### S8 — 稳定化与 Swift Reference v1 冻结 ⬜

目标：形成可供 Kotlin 和 ArkTS 实现的稳定 reference package。

工作：

- [ ] 大型媒体库性能、内存、数据库大小、冷启动和取消测试；
- [ ] 网络抖动、来源离线、数据库忙/满/损坏、进程终止和恢复 fault injection；
- [ ] API compatibility、migration rollback、隐私、安全和 secret scanning；
- [ ] 完成 libsmb2、GRDB 及传递依赖许可证与 notices；若未来加密升级引入密码学依赖，再独立补充其许可证和验证；
- [ ] Windows Core/CLI compile check，修正路径、stderr 和进程退出差异；
- [ ] 发布 DocC、CLI reference、数据库 schema、迁移说明和故障排查；
- [ ] 冻结 reference v1 的 JSON Schema、fixtures、DDL/checksum、错误表和行为矩阵；
- [ ] 输出 Kotlin/ArkTS porting kit，不包含 Swift 私有类型或 Apple framework 假设。

完成定义：所有 required CI、隔离集成测试和 Apple 验收通过；没有未决安全/数据丢失/许可证阻断；其他语言仅凭 specs、fixtures、DDL 和行为矩阵即可实现兼容版本。

## 7. CI 与测试门禁

### 每次变更

- `swift format lint`；
- macOS Core/CLI unit tests；
- Linux Core/CLI unit tests；
- debug 与 release build；
- 公共 JSON fixtures；
- `git diff --check`；
- secret scan。

### 触及数据库

- 全部 migration 样本；
- DDL checksum；
- `PRAGMA foreign_key_check`；
- 中断、磁盘满和损坏注入；
- 规范化 snapshot 比较。

### 触及 SMB

- fake transport contract tests；
- 不依赖服务器的 C ABI、主动取消和确定性释放测试；
- signing/encryption、认证失败、断线、取消的合同测试；
- argv/log/artifact 凭据泄漏检查；
- release candidate 或 SMB 行为实质变化时，人工执行隔离真实来源只读验收；CI 不启动临时 Samba。

### 触及来源凭据同步

- 明文 `CredentialRecord` 跨语言 fixture、revision、tombstone 和幂等重放；
- 账户级授权隔离、撤销/登出、密码更新和冲突；
- 未知 schema 或 protection mode 失败关闭且不覆盖远端数据；
- SQLite、同步请求和受限服务端存储存在预期测试 payload；日志、URL、崩溃报告、分析事件和非受限诊断导出不得包含凭据。

## 8. 每个里程碑的交付物

每个里程碑必须同时交付：

1. 对应规范或 ADR；
2. Swift production code；
3. 单元测试和失败测试；
4. 至少一组语言无关 fixture；
5. CLI 或集成测试可观察入口；
6. 验证命令和结果记录；
7. 文档与里程碑状态更新。

只有代码编译、只有协议、只有 mock 或只有 UI 均不能标为完成。

## 9. Portability review

每个里程碑结束时检查：

- wire format 是否依赖 Swift 属性名、`Date`、`URL`、`Error.localizedDescription` 或字典顺序；
- 状态机能否映射到 Kotlin coroutine/Flow 与 ArkTS Promise/事件流；
- SQLite 是否使用目标平台缺失的扩展、collation 或触发器；
- connector 是否泄漏 libsmb2/AMSMB2 类型；
- fixture 是否能由非 Swift runner 独立加载；
- Apple 平台限制是否被误写成产品合同；
- 取消、重试、错误和冲突是否有可观察结果，而不是依赖实现细节。

## 10. 当前关键路径

```text
S1 模块/CI
  → S2 Linux libsmb2 扫描
  → S3 Scanner 状态机
  → S4 SQLite 入库
  → S5 媒体物化与 PosterWall
  → S6 OAuth/Config/Credentials（OAuth 真机验收已通过，Sync 待完成）
  → S7 StellarPlayer 集成
  → S8 Reference v1
```

当前执行目标是完成 S6 同步纵向切片：

```text
StellarSync target + deterministic fake server
  → account outbox 幂等 push 与服务端确认
  → cursor pull 与配置/凭据原子 apply
  → 冲突保留、删除墓碑和重复重放
  → 新设备登录后直接恢复来源凭据
```

## 11. 计划维护规则

1. 新任务必须归入一个 Swift 里程碑；改变跨平台语义时先更新 `specs/`。
2. 当前阶段未达到完成定义前，不同时铺开无关的大型 provider。
3. 依赖真实后端、真机、真实 NAS 或法律确认的工作不能只凭 mock 标为完成。
4. 完成项在同一个变更中更新代码、测试、规范和本计划状态。
5. 不为赶进度降低凭据安全、missing 保护、迁移保全或只读限制。
6. Swift reference v1 冻结后，破坏性合同变化必须提升 schema/API 版本并提供迁移。

# Swift SDK

面向 iOS、iPadOS、macOS 和 tvOS 的原生 Swift 实现。

完整实施顺序与完成定义见 [Swift Reference Implementation Plan](../../docs/plans/swift-reference-implementation.md)。S2 已完成 Linux/libsmb2 只读纵向切片；当前阶段是建立来源无关、可恢复且具备 missing 安全边界的 Scanner 合同与实现。

## 工具链与兼容基线

- Swift tools version：6.3；使用 Swift 6 语言模式；
- 最低 iOS/iPadOS：17；
- 最低 macOS：14；
- 最低 tvOS：17；
- 开发与 CI 使用最新稳定 Swift 6.3.x patch 版本，升级 minor/major 前先运行公共 JSON fixture 和 API compatibility 测试。

Swift 的 `Codable` 实现必须通过共享 fixture 验证 wire format。公共模型显式声明 `CodingKeys`，不依赖属性名推导、系统默认日期格式或未指定的字典顺序；时间统一使用 Unix epoch 毫秒。

## 目录

```text
Sources/StellarCore/
Sources/StellarRemoteMedia/
Sources/StellarLocalMedia/          # macOS/Linux read-only local directory connector
Sources/StellarWebDAV/              # read-only PROPFIND/stat/Range connector
Sources/StellarMediaLibrary/
Sources/StellarSMB2Core/            # libsmb2-independent seam and values
Sources/CStellarSMB2Wrapper/        # 不暴露上游类型的 allowlisted C API
Sources/StellarSMB2Linux/           # Linux 真正的只读 libsmb2 transport
Sources/StellarUserMediaSDK/       # umbrella facade
Sources/StellarMediaCLI/
Tests/StellarUserMediaSDKTests/
```

当前切片提供公共错误模型、可注入 runtime services、统一日志脱敏、基础 wire contracts、加密凭据 envelope、来源无关的 locator/entry/connector 合同、可恢复且有界并发的 scanner、扩展文件名 parser，以及调用 umbrella SDK 的 `stellar-media` CLI。Scanner 在每个成功目录页把 entries 与 checkpoint 作为同一批次提交，只有最终 completion 才携带 missing 协调资格。Core、RemoteMedia、LocalMedia、WebDAV、MediaLibrary 和 SMB2Core 已是独立 target；其余 target 在第一次产生真实代码时加入。

`StellarSMB2Core` 提供不泄漏 C pointer 的 `SMB2Transport` / `SMB2Session` seam、连接策略和只读值模型。`CStellarLibsmb2Private` 只在 Linux Package graph 中存在，解析项目私有静态 archive；archive 中所有已定义全局 symbol 均添加项目唯一的 `stellar_user_media_sdk_libsmb2_` 前缀并从动态导出表隐藏。`CStellarSMB2Wrapper` 是唯一可调用该私有 module 的 target，对 Swift 只暴露项目自有 opaque client 和值记录；`StellarSMB2Linux` 在有界 blocking executor 上实现连接、枚举、`stat` 和 range read。

`StellarCore` 当前公开：

- `SDKRuntimeDependencies`：注入 clock、UUID、logger 和 cancellation checker；
- `RetryExecutor`：使用注入时钟执行确定性指数退避，并且不重试取消；
- `SensitiveDataRedactor` / `RedactingSDKLogger`：在数据进入应用日志 sink 前统一脱敏；
- `FieldPresence` / `CursorPage` / `EpochMilliseconds`：实现 [`JSON Wire Format v1`](../../specs/core/wire-format.md)。

## 构建与运行

```bash
cd platforms/swift
swift test
swift build -c release
swift run stellar-media version
swift run stellar-media parse "The.Matrix.1999.2160p.mkv"
swift run stellar-media manifest replay ../../specs/fixtures/media-library/scanner-state-v1.json
python3 ../../tools/ci/check_swift_dependencies.py --package-root .
python3 ../../tools/ci/check_swift_api.py --package-root . --baseline API/PublicAPI.json
```

Linux 构建完成后可用只读 SMB 命令。密码只能通过 stdin 提供，不支持密码参数或带 userinfo 的 SMB URL：

```bash
your-secret-provider read stellar/smb/alice | \
  swift run stellar-media smb check \
  --server nas.example.test --share Media --username alice --password-stdin
```

`your-secret-provider` 代表不会把秘密放进 argv 的进程外凭据工具；不要把真实密码写入脚本、环境变量、shell history 或仓库。

GitHub Actions 在 `macos-26` 和 `ubuntu-24.04` 上执行相同的 Swift 6.3 format lint、依赖锁定检查、公共 API compatibility 检查、debug/fixture tests、release build 和 CLI smoke tests；仓库守卫同时执行高置信度 secret scan 与 portable target Apple-import 检查。

当前 Package 没有外部依赖，因此 SwiftPM 不生成 `Package.resolved`。新增依赖时必须使用 exact version 或 immutable revision 并提交解析记录；branch 与 version range 会被 CI 拒绝。公共 API 有意变更后，使用以下命令重新生成基线并审阅 diff：

```bash
python3 ../../tools/ci/check_swift_api.py \
  --package-root . \
  --baseline API/PublicAPI.json \
  --update
```

## 实现约定

- 对外 API 采用 `async throws`；持续状态采用 `AsyncSequence`，按需提供 Combine 适配。
- 会话、数据库写入和扫描协调器分别由 actor 串行化。
- OAuth 使用 `ASWebAuthenticationSession`，令牌存入 Keychain。
- 第三方连接凭据只以 E2EE envelope 进入 `account.sqlite`；Vault key 解锁材料存入 Keychain。
- SQLite 封装必须支持 WAL、外键、迁移事务和取消；具体库在 ADR 中决定。
- 远程媒体读取抽象为可取消、支持 range 的字节流，不让播放器依赖具体连接器。
- 图片缓存与系统缓存目录集成；不把可再下载图片放入备份。

## 首批公共入口

- `StellarUserMediaClient`
- `SessionManager`
- `MediaSourceRepository`
- `MediaSourceConnector`
- `MediaScanner`
- `LibraryRepository`
- `PosterWallRepository`

`Package.swift` 同时导出 `StellarUserMediaSDK` library 和 `stellar-media` executable。CLI 是 SDK 的测试宿主，不建立另一份业务实现。

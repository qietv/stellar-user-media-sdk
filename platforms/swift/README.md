# Swift SDK

面向 iOS、iPadOS、macOS 和 tvOS 的原生 Swift 实现。

完整实施顺序与完成定义见 [Swift Reference Implementation Plan](../../docs/plans/swift-reference-implementation.md)。S5 已完成本地元数据/NFO/JSON/probe 原子入库、TMDB adapter 与清洗 fixture、候选评分、review 缓存、人工锁保护、多版本/extra 物化、派生搜索索引安全重建，以及 PosterWall 查询、详情、稳定分页、选图和缓存接口。当前阶段为 S6 OAuth、来源配置与凭据同步；现已实现 `MediaSourceConfig`、配置/墓碑原子 outbox、受限 `CredentialPayload` v1，以及对接真实 StellarPlayer Gateway 合同的 OAuth PKCE/session/refresh/Keychain 首个切片。

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
Sources/StellarAuth/                 # OAuth 2.1、session actor 与 Apple Keychain 边界
Sources/StellarRemoteMedia/
Sources/StellarLocalMedia/          # macOS/Linux read-only local directory connector
Sources/StellarWebDAV/              # read-only PROPFIND/stat/Range connector
Sources/StellarStorage/             # GRDB migrations, verification, repositories
Sources/StellarMediaLibrary/
Sources/StellarPosterWall/          # stable pagination, search, sections, and details
Sources/StellarSMB2Core/            # libsmb2-independent seam and values
Sources/CStellarSMB2Wrapper/        # 不暴露上游类型的 allowlisted C API
Sources/StellarSMB2Linux/           # Linux 真正的只读 libsmb2 transport
Sources/StellarUserMediaSDK/       # umbrella facade
Sources/StellarMediaCLI/
Tests/StellarUserMediaSDKTests/
```

当前切片提供公共错误模型、可注入 runtime services、统一日志脱敏、基础 wire contracts、版本化明文 `CredentialRecord`、严格受限的五种 `CredentialPayload`、版本化 `MediaSourceConfig` 与账户级原子 outbox、来源无关的 locator/entry/connector 合同、可恢复且有界并发的 scanner、SQLite v1 迁移/校验/扫描入库、扩展文件名 parser，以及调用 umbrella SDK 的 `stellar-media` CLI。`StellarAuth` 读取并严格校验 Gateway Metadata，生成 PKCE S256 与 `state`，通过 actor 串行化登录、恢复、20 路 single-flight refresh、多账户切换、资料刷新和本地优先登出；access token 只驻留内存，refresh token 使用非交互 Data Protection Keychain。Scanner 在每个成功目录页把 entries 与 checkpoint 作为同一批次提交，只有最终 completion 才携带 missing 协调资格。

`StellarSMB2Core` 提供不泄漏 C pointer 的 `SMB2Transport` / `SMB2Session` seam、连接策略和只读值模型。`CStellarLibsmb2Private` 只在 Linux Package graph 中存在，解析项目私有静态 archive；archive 中所有已定义全局 symbol 均添加项目唯一的 `stellar_user_media_sdk_libsmb2_` 前缀并从动态导出表隐藏。`CStellarSMB2Wrapper` 是唯一可调用该私有 module 的 target，对 Swift 只暴露项目自有 opaque client 和值记录；`StellarSMB2Linux` 在有界 blocking executor 上实现连接、枚举、`stat` 和 range read。

`StellarCore` 当前公开：

- `SDKRuntimeDependencies`：注入 clock、UUID、logger 和 cancellation checker；
- `RetryExecutor`：使用注入时钟执行确定性指数退避，并且不重试取消；
- `SensitiveDataRedactor` / `RedactingSDKLogger`：在数据进入应用日志 sink 前统一脱敏；
- `FieldPresence` / `CursorPage` / `EpochMilliseconds`：实现 [`JSON Wire Format v1`](../../specs/core/wire-format.md)。

`StellarAuth` 当前内置 `https://dev-gateway.2dland.cn/` 的 desktop profile，并使用 [`gateway-oauth-v1.json`](../../specs/fixtures/auth/gateway-oauth-v1.json) 固定 Metadata、Token 与 `/api/v1/me` 字段。Gateway 目前只注册了 desktop 动态 HTTP loopback callback；`AppleWebAuthenticationSessionPresenter` 只接受 Apple API 原生支持的 custom scheme 或 HTTPS callback，因此 iOS/macOS App 正式接入前还需 Gateway 发布对应移动端 Client Policy。desktop loopback 可先通过 `ClosureOAuthAuthorizationPresenter` 注入严格的本地监听器。

## 构建与运行

```bash
cd platforms/swift
swift test
swift build -c release
swift run stellar-media version
swift run stellar-media parse "The.Matrix.1999.2160p.mkv"
swift run stellar-media manifest replay ../../specs/fixtures/media-library/scanner-state-v1.json
swift run stellar-media db migrate library /path/to/library.sqlite
swift run stellar-media db verify library /path/to/library.sqlite
swift run stellar-media library scan /path/to/library.sqlite /path/to/media source-uid
swift run stellar-media library inspect /path/to/library.sqlite
swift run stellar-media library list /path/to/library.sqlite --section recently-added
swift run stellar-media library search /path/to/library.sqlite "space opera"
swift run stellar-media library show /path/to/library.sqlite <media-uid> --profile <profile-uid>
python3 ../../tools/ci/check_swift_dependencies.py --package-root .
python3 ../../tools/ci/check_swift_api.py --package-root . --baseline API/PublicAPI.json
python3 ../../tools/metadata/sanitize_tmdb_fixture.py raw-tmdb.json sanitized-tmdb.json
```

Linux 构建完成后可用只读 SMB 命令。密码只能通过 stdin 提供，不支持密码参数或带 userinfo 的 SMB URL：

```bash
your-secret-provider read stellar/smb/alice | \
  swift run stellar-media smb check \
  --server nas.example.test --share Media --username alice --password-stdin
```

`your-secret-provider` 代表不会把秘密放进 argv 的进程外凭据工具；不要把真实密码写入脚本、环境变量、shell history 或仓库。

GitHub Actions 在 `macos-26` 和 `ubuntu-24.04` 上执行相同的 Swift 6.3 format lint、依赖锁定检查、公共 API compatibility 检查、debug/fixture tests、release build 和 CLI smoke tests；仓库守卫同时执行高置信度 secret scan 与 portable target Apple-import 检查。

当前 Package 精确固定 GRDB.swift 7.11.1 并提交 `Package.resolved`。新增依赖时必须使用 exact version 或 immutable revision 并更新解析记录；branch 与 version range 会被 CI 拒绝。公共 API 有意变更后，使用以下命令重新生成基线并审阅 diff：

```bash
python3 ../../tools/ci/check_swift_api.py \
  --package-root . \
  --baseline API/PublicAPI.json \
  --update
```

## 实现约定

- 对外 API 采用 `async throws`；持续状态采用 `AsyncSequence`，按需提供 Combine 适配。
- 会话、数据库写入和扫描协调器分别由 actor 串行化。
- OAuth 使用 `ASWebAuthenticationSession`。access token 优先只驻留内存，refresh token 使用 Data Protection Keychain 的 `ThisDeviceOnly` 可访问级别；所有操作显式启用 `kSecUseDataProtectionKeychain`，默认私有 access group 且不同步 iCloud。不得写入 `kSecAttrAccessControl` 或调用 LocalAuthentication evaluate；读取使用禁止交互的 context，因此 Keychain 不弹 Face ID/Touch ID/设备密码，也不要求 Keychain Sharing 或运行时权限。
- 第三方连接凭据以应用层明文 `CredentialRecord` 进入 `account.sqlite` 并参与账户同步；系统 data protection 属于透明外围保护，不等于 E2EE。当前只写入 `plaintext`，同时保留未来受保护模式的版本化字段。写入前必须通过 `CredentialPayload` v1 的字段 allowlist、大小、auth type 与 record kind 一致性校验。
- SQLite 使用精确固定的 GRDB 7.11.1，支持 WAL、外键、迁移事务和取消；跨平台 DDL 所有权仍位于 `specs/storage/sql/`。
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

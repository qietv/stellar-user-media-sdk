# Android SDK

面向 Android 手机、平板与电视端的 Kotlin 实现。最终 `minSdk`、命名空间和发布坐标应与恒星播放器主工程统一，当前不做假设。

## 目录

```text
stellar-user-media-sdk/src/
├── main/kotlin/com/qietv/stellar/usermedia/
│   ├── core/
│   ├── auth/
│   ├── remotemedia/
│   ├── sync/
│   ├── storage/
│   ├── library/
│   └── posterwall/
└── test/kotlin/com/qietv/stellar/usermedia/
```

## 实现约定

- 对外异步 API 使用 `suspend`；持续状态使用冷 `Flow` 或只读 `StateFlow`。
- OAuth 优先使用系统 Custom Tabs/AppAuth；access token 优先只驻留内存，refresh token 通过 Android Keystore 支持的应用私有存储透明保护。默认不要求每次读取都进行指纹/人脸认证，以支持会话恢复和后台刷新。
- 第三方连接凭据按公共合同以应用层明文 `CredentialRecord` 存入账户数据库并同步；当前只创建 `plaintext`，不把 Keystore 或文件系统加密宣传为 E2EE。
- 扫描和网络 I/O 使用受控 dispatcher；任务应响应 coroutine cancellation。
- SQLite 可以由 Room 管理，但 schema、索引、迁移和删除规则必须遵循公共规范。
- 周期任务可由 WorkManager 触发，SDK 核心不得依赖任务一定准时运行。
- 网络层对日志统一脱敏，不记录 Authorization、Cookie、SMB 用户名或带签名 URL。

## 首批公共入口

- `StellarUserMediaClient`
- `SessionManager`
- `MediaSourceRepository`
- `MediaSourceConnector`
- `LibraryScanner`
- `LibraryRepository`
- `PosterWallRepository`

Gradle 构建文件将在主工程的 Android Gradle Plugin、Kotlin 和发布坐标确认后加入。

# OpenHarmony SDK

面向 OpenHarmony/HarmonyOS 应用的 ArkTS 实现。最终 API level、bundle/module 命名和 HAR 发布方式应与恒星播放器工程统一。

## 目录

```text
stellar_user_media_sdk/src/
├── main/ets/
│   ├── core/
│   ├── auth/
│   ├── remotemedia/
│   ├── sync/
│   ├── storage/
│   ├── library/
│   └── posterwall/
└── test/
```

## 实现约定

- 对外异步 API 使用 Promise；长任务通过 TaskPool 或平台后台任务能力协调并支持取消。
- OAuth 使用系统浏览器/授权 UI 能力，回调 URI 必须校验 state；令牌使用 HUKS 支持的加密存储。
- RDB/SQLite schema 与公共规范保持一致，启用事务和外键，并测试应用升级迁移。
- 状态变化通过轻量可订阅事件接口发布，避免把 UI 框架类型放入 SDK 核心。
- 连接器负责平台网络和文件 API 的差异，但输出统一 locator 与能力声明。
- 图片缓存使用应用缓存目录，不把可再生成图片当用户文件备份。

## 首批公共入口

- `StellarUserMediaClient`
- `SessionManager`
- `MediaSourceRepository`
- `MediaSourceConnector`
- `LibraryScanner`
- `LibraryRepository`
- `PosterWallRepository`

`oh-package.json5`、`build-profile.json5` 与 HAR 配置将在 API level 和模块标识确认后加入。


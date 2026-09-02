# Apple 平台实现

本项目只维护 Apple 平台的原生 Swift 实现；业务契约和 SQLite 逻辑 schema 位于 `specs/`。

| 平台 | 目录 | 语言 | 异步模型 |
| --- | --- | --- | --- |
| iOS/iPadOS、macOS、tvOS | [swift](swift/README.md) | Swift | async/await、actor、AsyncSequence |

每端均按以下模块拆分：

- `Core`：统一模型、错误、时钟、日志脱敏和依赖注入。
- `Auth`：OAuth、会话状态和安全令牌存储。
- `RemoteMedia`：NAS、网盘、媒体服务器连接器。
- `Sync`：用户配置拉取、离线 outbox 和冲突处理。
- `Storage`：SQLite schema、迁移和事务协调器。
- `MediaLibrary`：扫描、文件解析、匹配与媒体关系。
- `PosterWall`：分页查询、增量事件、图片选择和缓存。

设备族之间的行为差异必须先修改规范或记录 ADR，再实现。

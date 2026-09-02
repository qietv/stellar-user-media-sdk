# Apple SDK 开发路线图

本项目只支持 iOS/iPadOS 17、macOS 14 与 tvOS 17。平台范围见
[ADR-0007](decisions/0007-apple-only-platform-scope.md)。旧 Linux backend、非 Apple
Swift 兼容层、Ubuntu 构建门禁以及 Android/OHOS 占位工程均不再维护。

## M0：Apple 包边界与基础合同

- 固定 Swift 6.3、Swift 6 language mode 与 Apple 最低系统版本；
- 固化错误码、JSON 命名、时间/ID 规则与 SQLite migration；
- macOS CI 执行格式、依赖锁定、公共 API、单元测试、release build 和 secret scan；
- iOS device/simulator 编译验证主 SDK、Apple SMB 与截图产品。

## M1：OAuth 与账户

- Authorization Code + PKCE 登录和 claimed HTTPS callback；
- Data Protection Keychain 中的设备绑定、非交互 Token 存储；
- 单飞刷新、恢复、退出、撤销、需要重新认证和多账户隔离；
- iOS 真机继续覆盖登录、恢复、刷新、切换与注销。

当前 Swift 实现已完成开发 Gateway profile、PKCE/回调校验、session actor、单飞
refresh、资料读取、撤销和非交互 Keychain。同步 transport 与生产 Gateway 配置仍需推进。

## M2：远程媒体与凭据同步

- `MediaSourceConfig`、Favorite、扫描策略和墓碑；
- 配置 pull/push、revision、冲突和原子 outbox；
- 版本化 `CredentialRecord` 与受限 `CredentialPayload`；
- AMSMB2 与 WebDAV connector；
- 来源变化触发连通性检查与扫描。

## M3：媒体库与截图 MVP

- SQLite migration、repository 和可恢复 scanner；
- Apple 本地目录、SMB 与 WebDAV 枚举；
- 文件名解析、NFO/JSON、技术探测和 TMDB matching；
- missing 宽限、来源离线保护和崩溃恢复；
- FFmpegKit/libav 本地与远端帧截图。

## M4：海报墙

- 电影、剧集、继续观看和最近添加查询；
- 稳定分页、排序、筛选与搜索；
- 图片选择、缓存、预取和多版本绑定；
- Apple 示例应用覆盖核心用户路径。

## M5：更多来源与同步

- 云盘 delta adapter；
- Plex/Emby/Jellyfin Library Mode；
- Direct Mode 按需缓存；
- 播放状态、片单、provider 限流与后台恢复。

## M6：稳定发布

- metadata、derived index 和 full index 重建；
- 数据库损坏恢复与用户域导入；
- 大型媒体库性能测试；
- API compatibility、migration rollback、隐私清单和许可证审查；
- iOS/iPadOS、macOS 与 tvOS 发布构建验收。

## 尚未决定

- Stellar account/config API 的最终 URL 与认证 scope；
- 第三方凭据未来保护模式及迁移时机；
- PosterWall UI 组件是否作为独立包发布；
- TMDB 正式产品采用宿主凭据直连还是后端代理；
- 远端截图从整文件暂存升级为自定义 libav I/O 的优先级。

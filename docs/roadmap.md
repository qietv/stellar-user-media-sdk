# 开发路线图

本文描述三平台共同的产品阶段。Swift 的实际开发顺序、Linux/libsmb2 首个验收里程碑及完成定义见 [Swift Reference Implementation Plan](plans/swift-reference-implementation.md)。

## M0：仓库与合同

- 确认三平台最低系统版本、包名和发布渠道；
- 固化公共错误码、JSON 命名和时间/ID 规则；
- 固化明文 `CredentialRecord`、同步冲突、删除和未来 `protection_mode` 升级合同；
- 从 27 表设计提取可执行 DDL 与迁移测试；
- 建立 CI、格式化、单元测试和 secret scanning。

## M1：OAuth 与账户

- PKCE 登录、回调和会话状态机；
- Token 安全存储和单飞刷新；
- 退出、撤销、需要重新认证；
- 多账户数据目录；
- 每设备独立且默认无需生物识别读取的 Stellar OAuth token；
- 三端相同的会话测试向量。

## M2：远程媒体配置同步

Swift reference 当前已完成 `MediaSourceConfig` v1、配置/墓碑 SQLite 原子 outbox，以及五种受限明文 `CredentialPayload` 的跨语言 fixture；pull/push、冲突应用、OAuth 和来源变更触发仍在推进。

- `MediaSourceConfig`、Favorite 和扫描策略模型；
- 配置 pull/push、版本和 tombstone；
- 第三方用户名、密码和 Token 的明文 `CredentialRecord` 本地持久化与跨平台同步；
- 新设备完成 Stellar OAuth 后直接恢复来源凭据，不增加 Vault 授权步骤；
- SMB/WebDAV 一个基础 adapter；
- 配置变化触发本地 scanner。

## M3：媒体库 MVP

- SQLite v1、迁移和 repository；
- 本地目录 + SMB 枚举；
- full/scoped incremental scan；
- 文件名 parser、NFO 和 TMDB match；
- missing 宽限、来源离线保护和崩溃恢复。

## M4：海报墙

- 电影/剧集/继续观看/最近添加查询；
- 分页、稳定排序、筛选和搜索；
- 图片配置、缓存和预取；
- 多版本绑定；
- 三端示例应用。

## M5：更多来源与同步

- 云盘 delta adapter；
- Plex/Emby/Jellyfin Library Mode；
- Direct Mode 按需缓存；
- 用户播放状态和片单同步；
- provider 限流、离线和后台调度。

## M6：重建与稳定发布

- metadata、derived index、full index 重建；
- 数据库损坏恢复和用户域导入；
- 大型媒体库性能测试；
- API compatibility、迁移回滚和发布文档；
- 安全审计和隐私检查。

## 尚未决定

- Android/OHOS 最低系统版本；Swift 已确定最低 iOS/iPadOS 17、macOS 14、tvOS 17；
- Stellar account/config API 的最终 URL 与认证 scope；
- 第三方凭据未来升级为服务端托管加密或 E2EE 的真实需求与迁移时机；
- PosterWall UI 组件是否作为独立包发布；
- Swift reference v1 的 TMDB 直连 adapter 使用宿主应用运行时提供的 v3 API key 或 API Read Access Token；正式产品是否改由 Stellar 后端代理仍待决定。

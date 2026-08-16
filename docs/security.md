# 安全基线

## 1. OAuth

- 公共客户端使用 Authorization Code + PKCE；
- 每次授权生成高熵 `state`、verifier 和 challenge；
- 支持 OIDC 时校验 `nonce`、issuer、audience 和 token 时间；
- 不在移动 SDK 中嵌入 client secret；
- access token 只驻留内存或平台安全存储，refresh token 只进入平台安全存储；
- 平台安全存储默认不要求每次读取时进行生物识别或用户在场验证；高安全模式必须由用户显式开启，并提示后台刷新限制；
- Apple token 使用 Data Protection Keychain 和 `ThisDeviceOnly` 可访问性，不经 iCloud Keychain 同步；需要锁屏后台刷新时使用 `AfterFirstUnlockThisDeviceOnly`，否则使用 `WhenUnlockedThisDeviceOnly`；
- Apple 默认禁止 `kSecAttrAccessControl`、user-presence/biometry/passcode flags 和 LocalAuthentication evaluate 调用；所有查询使用非交互 context，遇到需要认证的遗留 item 直接失败并重新登录，不允许弹框；
- Apple 默认使用应用私有 access group，不要求 Keychain Sharing、App Groups、Face ID usage description 或任何运行时权限申请；
- 同一账户只允许一个刷新操作，其余请求等待结果，避免 refresh token 轮换竞争；
- 日志、崩溃报告和分析事件不得包含 token、授权码或完整回调 URL。

## 2. NAS、云盘和媒体服务器凭据

- v1 用户名、密码和第三方 Token 以 `protection_mode=plaintext` 的 `CredentialRecord` 同步；`account.sqlite`、同步请求和服务端数据库都可以读取 payload；
- 服务端必须执行账户归属、Scope、revision、大小和 schema 校验，拒绝跨账户读取、覆盖或引用；
- SMB/WebDAV 密码、云盘 refresh token、Plex/Emby/Jellyfin token 按账户和来源隔离；
- 新设备完成 Stellar OAuth 后直接取得同步凭据，不要求旧设备批准、恢复口令、Vault 解锁或生物识别；
- 删除来源后，仅在没有其他来源引用同一凭据时同步删除凭据 tombstone；
- 数据库、WAL、备份、服务端快照和有读取权限的运维主体都处于凭据明文威胁面；隐私政策和事件响应必须如实覆盖；
- 详细记录、冲突和未来加密升级规则见 [`specs/security/credential-storage.md`](../specs/security/credential-storage.md)。

## 3. 网络

- 账户和云服务 API 默认只允许 HTTPS；
- 用户主动配置的局域网 HTTP 服务必须显式标记为不安全连接；
- 重定向后重新校验 scheme、host 和凭据发送范围；
- 禁止把某来源的 Authorization header 转发到另一个 host；
- 对 SSRF 风险进行地址校验，远程配置服务不能替客户端无条件探测任意内网地址。

## 4. 本地数据

- 每账户独立数据库和图片缓存目录；
- `account.sqlite` 中的第三方凭据在 v1 是应用层明文；数据库文件保护、应用沙箱和设备加密是透明外围保护，不能宣传为 E2EE；
- 每条 SQLite 连接启用外键；
- 数据库和缓存使用平台 data-protection/应用沙箱能力；
- 导出诊断数据前移除路径、用户名、主机、查询参数和 provider token；
- 自动扫描永远无权删除真实媒体文件；文件管理能力必须是独立、明确授权的接口。

## 5. 同步

- 同步记录必须包含 account、record UID、版本和幂等 event UID；
- 凭据同步服务可以读取 v1 payload，但只能在连接配置同步所需的最小权限边界内使用；
- 删除使用 tombstone，并保留到所有活跃设备有机会消费；
- 服务端拒绝跨账户 UID 注入；
- 客户端校验 payload schema 和大小，不反序列化任意类型；
- 未上传 `change_log` 不因本地业务行回收而丢失。

## 6. 发布前检查

- 仓库 secret scanning 为零告警；
- OAuth 回调、刷新竞争、退出和撤销均有测试；
- Apple Keychain 首次写入、恢复、刷新、后台读取、登出和遗留受保护 item 的 UI 自动化/真机测试确认零认证弹框、零运行时权限请求；
- 数据库迁移执行 `foreign_key_check`；
- 日志脱敏测试覆盖 URL、header、路径和错误对象；
- 明文 CredentialRecord 跨平台 fixture、账户隔离、冲突、删除和未支持保护模式失败关闭测试全部通过；
- 备份、WAL、同步请求和服务端存储的凭据明文清单已经进入访问控制、保留和删除验收；
- 来源删除、账户删除和清空全部数据的 UI 文案与实际影响一致；
- 第三方 API key 通过调用方配置或构建时注入，不提交到仓库。

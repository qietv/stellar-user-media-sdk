# 安全基线

## 1. OAuth

- 公共客户端使用 Authorization Code + PKCE；
- 每次授权生成高熵 `state`、verifier 和 challenge；
- 支持 OIDC 时校验 `nonce`、issuer、audience 和 token 时间；
- 不在移动 SDK 中嵌入 client secret；
- access/refresh token 只进入平台安全存储；
- 同一账户只允许一个刷新操作，其余请求等待结果，避免 refresh token 轮换竞争；
- 日志、崩溃报告和分析事件不得包含 token、授权码或完整回调 URL。

## 2. NAS、云盘和媒体服务器凭据

- 用户名、密码和第三方 Token 必须先在客户端使用 Credential Vault 端到端加密；
- `account.sqlite` 与云端都只保存加密 envelope，不保存明文密码或 Token；
- envelope 使用认证加密并绑定 account、source、credential、类型和 key 版本，防止跨域替换；
- SMB/WebDAV 密码、云盘 refresh token、Plex/Emby/Jellyfin token 按账户和来源隔离；
- Vault key 的设备解锁材料进入 Keychain、Keystore 或 HUKS，服务端不得获得解密能力；
- 新设备必须经现有设备批准或用户恢复材料授权，不能仅凭云端登录直接解密；
- 删除来源后，仅在没有其他来源引用同一凭据时同步删除凭据 tombstone；
- 详细 envelope、密钥授权、冲突与验收规则见 [`specs/security/credential-vault.md`](../specs/security/credential-vault.md)。

## 3. 网络

- 账户和云服务 API 默认只允许 HTTPS；
- 用户主动配置的局域网 HTTP 服务必须显式标记为不安全连接；
- 重定向后重新校验 scheme、host 和凭据发送范围；
- 禁止把某来源的 Authorization header 转发到另一个 host；
- 对 SSRF 风险进行地址校验，远程配置服务不能替客户端无条件探测任意内网地址。

## 4. 本地数据

- 每账户独立数据库和图片缓存目录；
- `account.sqlite` 中的第三方凭据必须保持字段级 AEAD 密文；数据库文件保护不能替代凭据加密；
- 每条 SQLite 连接启用外键；
- 数据库和缓存使用平台 data-protection/应用沙箱能力；
- 导出诊断数据前移除路径、用户名、主机、查询参数和 provider token；
- 自动扫描永远无权删除真实媒体文件；文件管理能力必须是独立、明确授权的接口。

## 5. 同步

- 同步 envelope 必须包含 account、record UID、版本、设备和幂等 event UID；
- 凭据同步服务只能校验 envelope 元数据和密文大小，不能要求明文或可由服务端解开的 key；
- 删除使用 tombstone，并保留到所有活跃设备有机会消费；
- 服务端拒绝跨账户 UID 注入；
- 客户端校验 payload schema 和大小，不反序列化任意类型；
- 未上传 `change_log` 不因本地业务行回收而丢失。

## 6. 发布前检查

- 仓库 secret scanning 为零告警；
- OAuth 回调、刷新竞争、退出和撤销均有测试；
- 数据库迁移执行 `foreign_key_check`；
- 日志脱敏测试覆盖 URL、header、路径和错误对象；
- Credential Vault 跨平台已知答案、AAD 篡改、新设备授权、撤销和 key 轮换测试全部通过；
- 来源删除、账户删除和清空全部数据的 UI 文案与实际影响一致；
- 第三方 API key 通过调用方配置或构建时注入，不提交到仓库。

# Credential Vault 规范（已停用）

状态：已由 [`credential-storage.md`](credential-storage.md) 取代。

项目不再在 v1 实现 Credential Vault、设备批准、恢复材料、Vault key 或 E2EE。当前第三方媒体源凭据使用可同步的明文 `CredentialRecord`；稳定 ID、revision、tombstone、`protection_mode` 与可选受保护字段保留未来升级空间。

历史决策见已被取代的 [ADR-0002](../../docs/decisions/0002-e2ee-credential-vault.md)，当前决策见 [ADR-0005](../../docs/decisions/0005-synced-credential-storage.md)。

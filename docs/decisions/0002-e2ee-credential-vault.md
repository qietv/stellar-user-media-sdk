# ADR-0002：第三方媒体源凭据使用端到端加密 Vault 同步

状态：已被 ADR-0005 取代
日期：2026-08-14

> 2026-08-16 决定优先保证新设备登录后无需旧设备批准、恢复口令或独立 Vault 解锁。当前有效设计见 [ADR-0005](0005-synced-credential-storage.md) 和 [`specs/security/credential-storage.md`](../../specs/security/credential-storage.md)。本文件仅保留历史决策背景。

## 背景

用户明确需要在 Swift、Android 和 OpenHarmony 设备间同步网盘、NAS 和媒体服务器的连接信息、用户名与密码。只在每台设备保存凭据会迫使用户重复配置，也无法满足产品要求；把明文或服务端可解密的凭据上传则会扩大泄露面。

## 决策

- 第三方媒体源凭据在客户端加密成可供本地与云端共同保存的版本化 envelope。
- `account.sqlite` 和云端都可保存 envelope，但不得保存明文凭据。
- Vault key 只发给用户批准的设备；服务端仅保存包装后的 key 和设备授权元数据。
- Stellar 账户自身 OAuth token 仍按设备登录并只存平台安全存储。
- 详细 wire format、安全边界和验收条件由 [`specs/security/credential-vault.md`](../../specs/security/credential-vault.md) 约束。

## 后果

新设备可以在授权后复用媒体源连接，不必重新输入第三方密码。代价是首版必须实现设备批准或恢复、key 轮换、撤销、冲突和跨平台密码学测试，不能把凭据同步视为普通配置字段复制。

## 未解决项

设备 key wrapping 算法套件、恢复材料形式和批准交互必须在 Credential Vault 投产前通过后续版本化 ADR 固化。

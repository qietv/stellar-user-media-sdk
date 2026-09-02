# ADR-0005：第三方凭据以可同步明文记录起步

状态：已接受
日期：2026-08-16
取代：[ADR-0002](0002-e2ee-credential-vault.md)

## 背景

StellarPlayer 需要在用户的 Apple 设备间同步 NAS、WebDAV、网盘及媒体服务器凭据。此前方案使用 E2EE Vault，要求设备密钥、已有设备批准或恢复材料、密钥轮换和完整密码学生命周期。

产品当前优先级是：用户在新设备完成 Stellar OAuth 后即可恢复来源并连接，不增加旧设备批准、恢复口令、独立 Vault 解锁或生物识别步骤。实现和维护完整 E2EE 生命周期不属于 v1 的投入范围。

## 决策

- 第三方媒体源凭据使用版本化 `CredentialRecord` 随来源配置同步。
- v1 唯一可创建的 `protection_mode` 是 `plaintext`；客户端、同步服务和服务端数据库都能读取 payload。
- `account.sqlite` 也保存应用层明文 payload。应用沙箱、平台 data-protection、TLS、服务端磁盘或备份加密属于透明的外围保护，不得宣传为 E2EE。
- 新设备完成 Stellar OAuth 后直接取得凭据，不需要设备批准、恢复材料、Vault key 或单独的解锁 UI。
- Stellar OAuth access/refresh token 不随 `CredentialRecord` 同步，仍按设备进入平台安全存储；默认不要求每次读取时提供生物识别或用户在场证明。
- URL、日志、崩溃报告、分析事件、命令行和诊断导出继续禁止包含凭据。
- `CredentialRecord` 保留稳定 UID、revision、tombstone、`protection_mode` 和可选加密元数据，供未来原子升级为服务端托管加密或 E2EE。

## 后果

用户体验更直接，四个平台不需要先交付密钥批准和恢复系统。代价是服务端、数据库读取权限持有者、备份读取者和取得本地 `account.sqlite` 明文的攻击者可以恢复第三方凭据。发布文档、隐私政策、数据保留、备份权限和事件响应必须按这一事实设计，不能声称零知识或端到端加密。

## 升级约束

未来加密升级必须使用新的版本化 ADR，完成客户端能力协商、最低版本门槛、历史 SQLite/WAL/备份/outbox 明文迁移、失败回滚和禁止降级。预留字段不代表当前已经实现任何加密。

详细合同见 [`specs/security/credential-storage.md`](../../specs/security/credential-storage.md)。

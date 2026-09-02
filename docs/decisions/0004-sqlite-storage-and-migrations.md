# ADR-0004：SQLite 数据库分域、GRDB 与迁移所有权

状态：已接受  
日期：2026-08-16

2026-09-02 修订：`library.sqlite` 通过 checksum 固定的 v2/v3/v4/v5 migration 增加
`scan_frontier`、`scan_seen`、`scan_discovery`、revision-safe worker lease 与 claim 顺序索引，并强制单来源只有一个 active scan run；
当前为 30 张表，v1 的 27 表 DDL 继续作为迁移基线保留。

## 背景

Swift SDK 已完成来源无关 scanner。S4 需要把 checkpoint、文件事实和完成边界持久化，并在 Apple 设备族间提供完全相同的 DDL、约束、迁移编号和 checksum。活动 SQLite 文件不会跨设备共享，共享的是 SQL 合同和规范化 snapshot。

## 决策

- `specs/storage/sql/` 是 SQL 的唯一合同入口，分别版本化 `library.sqlite`、`account.sqlite` 与 `metadata_cache.sqlite`。
- Swift 精确固定 GRDB.swift 7.11.1，使用 Apple 系统 SQLite；不使用 GRDB 私有 schema 作为产品事实。
- `library.sqlite` 和 `account.sqlite` 使用 `DatabasePool`，每个数据库再由一个 writer actor 协调业务写入；读取可并发。
- 每条连接启用 foreign keys、5000 ms busy timeout 与 `synchronous=NORMAL`；可写数据库使用 WAL。
- 迁移 SQL、版本和 SHA-256 checksum 由仓库 guard 校验。迁移在事务内完成，只有 DDL、`schema_migration` 记录、`application_id` 与 `user_version` 全部成功才提交。
- `library.sqlite` 当前保存 30 张核心业务表；`metadata_cache.sqlite` 只保存 3 张可删除缓存表；`account.sqlite` 保存来源配置、v1 明文 `CredentialRecord`、冲突候选、transactional outbox 与同步 cursor。凭据保护决策以后续 [ADR-0005](0005-synced-credential-storage.md) 为准。
- 数据库之间不建立外键。跨库关联只使用稳定 UID，并由应用层检查。
- scanner 每页 entries 只写 per-run discovery staging，并与 durable frontier/seen transition、compact checkpoint 和 scan counters 在一个短事务中提交。最终 completion 在单事务中发布正式文件快照、changed work 与 scoped missing；失败或取消保留 staging 供恢复，不能修改已发布快照。
- metadata work 通过带 claim token、heartbeat 和 expiry 的 lease 独占处理；队列保存创建时的 file material revision，所有结果写回以 lease 与 revision compare-and-set，过期或陈旧 worker 不得修改正式 metadata。
- `change_log`/`account_change_log` 故意不引用业务表；业务行删除不能级联丢失尚未上传的 upsert 或 tombstone。

## 数据库身份

| 文件 | `application_id` | v1 角色 |
| --- | ---: | --- |
| `library.sqlite` | `0x4D4C4942` (`MLIB`) | 扫描、文件、媒体实体、用户状态、媒体库 outbox |
| `account.sqlite` | `0x41434354` (`ACCT`) | 来源配置、加密 envelope、账号域 outbox |
| `metadata_cache.sqlite` | `0x4D434143` (`MCAC`) | 可删除 provider/match/artwork 缓存 |

打开已有文件时，非零且不匹配的 `application_id` 必须失败，不能把其他 SQLite 文件迁移成 Stellar 数据库。版本高于当前客户端时也必须失败关闭。

## 失败与恢复

- 已有数据库迁移失败后保留原文件与原 `user_version`，向调用方返回脱敏错误。
- 新库创建失败可以删除本次创建的空/不完整文件；不得用空库覆盖已有路径。
- `foreign_key_check` 与 `quick_check` 属于发布和 CLI verify 门禁。
- 真正需要重建核心库时，先复制用户状态、人工锁定与未上传 outbox 到新库，验证后原子切换；这不是普通 migration 的回退路径。

## 后果

Apple 设备族必须执行同一 SQL、保存同一 migration checksum，并通过相同 normalized snapshot。GRDB 只负责 Swift 的连接、事务和查询调度，不成为 wire format 或 schema 的所有者。

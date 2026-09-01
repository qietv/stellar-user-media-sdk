# SQLite、本地状态与同步规范

## 结论

Swift、Android 与 OpenHarmony 均采用 SQLite 作为本地事实库，使用相同的逻辑 schema 和迁移编号。三端可选择不同封装层，但落盘字段、唯一约束、外键和事务边界必须兼容。

基础 v1 合同由 [`schema-manifest-v1.json`](schema-manifest-v1.json) 固定 checksum，并分别位于：

- [`library-v1.sql`](sql/library-v1.sql)：27 张核心业务表；
- [`account-v1.sql`](sql/account-v1.sql)：来源配置、凭据记录、冲突、outbox 与 cursor；
- [`metadata-cache-v1.sql`](sql/metadata-cache-v1.sql)：3 张可删除缓存表。

当前 `library.sqlite` 版本为 v2；[`schema-migrations.json`](schema-migrations.json) 固定
[`library-v2.sql`](sql/library-v2.sql) 的 checksum。该迁移在 v1 的 27 张表上增加
`scan_frontier` 与 `scan_seen`，现行媒体库共 29 张业务表。account 与 metadata cache 仍为 v1。

研究文档中的 SQL 只保留设计推导与数据字典；若与上述可执行合同冲突，以 `specs/storage/sql/` 为准。数据库身份、GRDB 采用方式、连接参数和迁移失败策略见 [ADR-0004](../../docs/decisions/0004-sqlite-storage-and-migrations.md)。

持久化分为三个逻辑域，其中媒体库域拆成核心库与缓存库：

- 平台安全存储：每台设备独立的 Stellar OAuth token；不是 SQLite。默认访问策略不要求每次读取时进行生物识别或用户在场验证。
- `account.sqlite`：账号资料、可同步媒体源配置、应用层明文第三方凭据记录，以及各自的同步 outbox。v1 DDL 不保存 Stellar OAuth token，也不计入媒体库业务表；应用沙箱和平台 data-protection 不改变 payload 可被应用读取的事实。
- `library.sqlite`：29 张媒体库核心表，包括扫描 frontier/seen、文件、影视实体、用户状态和媒体库同步状态。
- `metadata_cache.sqlite`：3 张可删除、可重建的供应商响应、匹配候选和图片文件缓存表。

数据库之间不建立外键；使用跨库 UID 和应用层约束。这样可以清空缓存或重建媒体索引，而不损坏登录、远程配置和安全凭据。

## 逻辑表组

媒体库设计当前包含 29 张 `library.sqlite` 业务表和 3 张 `metadata_cache.sqlite` 可删除缓存表。下面的表名与可执行 DDL/migration 对齐；详细字段、索引、外键和关系见[跨平台媒体库设计](../../docs/research/infuse/cross_platform_media_library_design.md)。

| 分组 | 表 | 生命周期 |
| --- | --- | --- |
| 数据库管理 | `schema_migration` | 随数据库长期保留 |
| 来源与扫描 | `library_source`、`scan_run`、`scan_frontier`、`scan_seen`、`scan_queue` | 来源软删除；frontier/seen 在 run 完成后清理，扫描记录和任务按保留期压缩 |
| 文件事实 | `media_file`、`sidecar`、`parse_result`、`technical_summary`、`media_stream` | 文件先软缺失；其解析与探测数据可重建 |
| 影视实体与绑定 | `media_entity`、`file_binding`、`external_id` | 实体可被用户状态保留；绑定记录区分自动与人工锁定 |
| 本地化元数据 | `localized_metadata`、`genre`、`genre_name`、`entity_genre`、`person`、`credit` | 在线部分可刷新；人工锁定字段受保护 |
| 图片 | `artwork` | 保存图片候选和已选项；二进制缓存另库存放 |
| 用户状态 | `playback_profile`、`playback_state`、`playback_marker` | 进度和人工 marker 不因文件消失而删除 |
| 片单 | `media_collection`、`collection_item` | 手工片单为用户数据，显式删除才清理 |
| 搜索 | `search_document` | 完全可重建 |
| 媒体库同步 | `change_log`、`sync_cursor` | outbox 事件须上传确认；删除业务行不能级联清空事件 |
| 可删除缓存库 | `provider_response_cache`、`match_candidate_cache`、`artwork_cache_file` | 容量、过期或重建时可全部清空 |

若实现阶段调整表数，必须通过 ADR 和 schema migration 说明，而不是由某个平台单独增删语义。

## 数据归属与删除

| 数据 | 删除触发 | 规则 |
| --- | --- | --- |
| Stellar OAuth token | 登出、撤销或失效 | 位于平台安全存储，不进入 SQLite，也不跨设备同步 |
| 第三方媒体源凭据 | 来源删除、解绑、失效或用户清除 | v1 以明文 `CredentialRecord` 进入 `account.sqlite` 和云同步；使用 tombstone 删除 |
| 媒体源配置 | 用户删除或服务端墓碑 | 先停止任务并软删除，再清理派生索引 |
| 文件与流信息 | 完整扫描确认缺失且超过宽限期 | 允许物理删除本地行，不删除远端文件 |
| 逻辑媒体和元数据 | 无文件、无用户状态、无有效引用 | 延迟垃圾回收 |
| 观看进度、片单、手工匹配 | 用户显式清除账号数据 | 文件删除不应级联删除 |
| 图片缓存 | 容量或 LRU 策略 | 只清理可重新下载的内容 |
| 扫描运行和队列 | 超过诊断保留期 | 分批压缩；清理 `scan_run` 时将文件 last-seen 引用置空 |

外键默认启用。对于派生数据可以 `ON DELETE CASCADE`；对于用户状态和手工覆盖应使用逻辑引用或 `RESTRICT/SET NULL`，避免误级联。

## 事务与并发

- MUST 启用 WAL、foreign keys 和合理的 busy timeout。
- 每个数据库只有一个逻辑写入协调器；读取可并发。
- 扫描以小批事务提交，避免持有覆盖整个远程遍历的长事务。
- 扫描运行完成标志、正式快照替换和缺失差分必须处于同一原子提交边界。
- 元数据下载和图片下载不得占用数据库事务。
- 所有写操作必须可取消，但已经提交的事务不做半成品回滚补偿。

## 迁移

数据库使用整数 `user_version`，每个版本只向前迁移。发布前必须用以下样本验证：空库、上一个正式版本、包含中断扫描的库、包含未知枚举值的库和大规模媒体库。

迁移失败时保留原数据库及错误记录，不应创建一个空库覆盖旧库。重建 `library.sqlite` 前也必须先保全用户状态，或从独立备份恢复后再重建。

## 同步边界

- 账号资料和远程媒体配置可以服务端同步。
- 第三方媒体源凭据按 [`../security/credential-storage.md`](../security/credential-storage.md) 使用 `CredentialRecord` 跨平台同步；v1 服务端具备读取明文 payload 的能力。
- 观看状态、片单和手工匹配是否云同步由产品策略控制；启用后必须通过 `change_log` 幂等上传。
- 文件清单和大体积技术信息默认只存在本地；除非用户启用且服务端协议明确需要。
- `change_log` 是媒体库同步的 transactional outbox，同时可驱动应用层增量；不要把已上传记录无限保留。

## 备份与重建

“重建媒体库”只重建可派生内容。流程必须先暂停扫描，保存账号/配置/用户状态/手工覆盖，原子切换到新库，最后在后台清理旧库。认证失败或媒体源离线不是重建理由。

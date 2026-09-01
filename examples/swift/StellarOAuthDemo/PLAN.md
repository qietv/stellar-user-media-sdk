# Infuse 刮削/扫描方案分析与 StellarOAuthDemo 改进计划

> 状态：调研完成，实施中（Demo 元数据流水线、目录单次枚举、持久 frontier/compact checkpoint 和批量落库已落地）
>
> 日期：2026-09-01
>
> 分析对象：Infuse 8.5.1（iOS IPA）/ 8.5.3（本机 macOS 安装版）与 StellarOAuthDemo 当前实现
>
> 重点：扫描正确性、可恢复性、增量处理、刮削流水线和性能

## 已实施进展（2026-09-01）

- Demo 元数据处理由全量/N+1 预检改为直接消费 durable `scan_queue` 的变更项，
  已匹配统计使用一次集合查询；待处理任务现由 SDK 以 200 条 keyset page 直接 JOIN
  `media_file` 和 binding 状态，Demo 不再加载全量 library snapshot 或构造全库路径集合；
- 文件级 worker 使用 4 路有界并发，provider 请求使用 single-flight、10 QPS 节流、
  `Retry-After`、指数退避、抖动和 401/403 run suspension；
- `provider_response_cache` 已通过 SDK 公共 API 接入，支持 TTL、ETag、
  Last-Modified、条件请求和 404 negative cache；
- 同一剧集并发 episode 请求会按 entity/artwork 请求键合并，不再逐集重复相同 GET；
- localized metadata、所选 poster 和 queue acknowledgement 在 `library.sqlite`
  同一事务提交；Demo 已停止逐项重写 `poster_metadata.json`；
- 对应根实体的 `search_document` 现在随 remote metadata 在同一事务增量 upsert，
  Demo 扫描完成后不再执行全表 `DELETE + INSERT` rebuild；完整 rebuild 仅保留给 repair/migration；
- PosterWall 列表直接读取结构化 SQLite，详情 metadata 改为用户打开时按需读取；
- 已增加 provider cache 指纹隔离和 remote metadata 原子提交回归测试。
- SDK 新增共享目录快照分页器；Local、SMB、WebDAV 在一个连接内每个目录只做一次
  完整枚举，后续 cursor 仅切片缓存快照，断连恢复时重读一次并校验指纹；
- source capability 新增目录请求建议并发，Scanner 取调用方配置与来源上限的较小值；
  单 libsmb2 context 当前明确报告 1，而不是制造无效的 4 路排队；
- Scanner 的 seen/completed 去重集合改为单次运行内增量维护，不再每页重新从数组构造
  全量集合并排序；checkpoint 的全量数组本身尚未移除；
- `LibraryStore` 的多文件页面改为临时批次表上的集合化 merge，unchanged 文件只推进
  `last_seen_run_id`，不刷新 material timestamp，也不重复 enqueue metadata work；
- missing reconciliation 已由 Swift 拉取候选并逐行 UPDATE 改为 scope-aware 单条集合 SQL，
  覆盖 root 中 `%`、`_` 等字面路径字符的回归测试。
- checkpoint schema 已升级为 v2，不再编码 `pendingPages`、`completedPages` 和全量 seen identity；
  `scan_frontier` / `scan_seen` 通过 library schema v2 持久化，每页条目、frontier transition、
  seen 去重和 checkpoint 在同一 SQLite 事务提交；Scanner 使用增量 FIFO frontier，不再每页全量
  排序/复制前沿。中断恢复测试确认只重放未完成页，完成后 per-run frontier/seen 自动清理；
- `library.sqlite` 已支持经过 checksum 验证的 v1 → v2 原地迁移，保留已有业务数据；旧版 v1
  checkpoint payload 若被显式加载会返回 conflict 并要求新建 run，避免静默错误恢复。

这一阶段没有宣称完成下文全部计划。扫描 staging、真实目录游标、完整 worker
lease/revision、后台 scheduler 和本地 metadata intake 仍按后续 Phase 推进。当前目录缓存是
伪分页的 P0 止血方案，不等同于 libsmb2 `open/read-batch/close` 真流式句柄；事务内临时批次表
也不等同于失败 run 不影响正式快照的 per-run discovery staging。

## 1. 结论摘要

当前实现已经具备一个可靠扫描器应有的若干关键基础：来源无关的扫描抽象、分页任务、检查点、稳定 ID、原子提交“页面数据 + 检查点”、完成后才允许 missing reconciliation、SQLite 幂等写入，以及 full/incremental/repair 三种模式的模型。这些设计应保留。

与 Infuse 的实现思路相比，最大的差距不在“是否能扫到文件”，而在下面四个方面：

1. **传输层分页实际重复读取整个目录。** SMB、WebDAV 和本地适配器的逻辑分页都没有形成真正的流式目录游标。以 SMB 为例，每取一页都会重新列举、映射、排序并指纹化完整目录；大目录因而接近二次复杂度，并重复发起网络 I/O。
2. **检查点随扫描规模和页面数持续膨胀。** 每一页都把全部已见文件、已见目录、完成页面重新构造成集合、排序、JSON 编码并写入数据库。扁平目录和大量小目录都会产生明显 CPU 与写放大。
3. **发现结果直接逐文件写入正式表。** 扫描未成功结束前，新路径和移动信息已对外可见；数据库提交以逐行查询/更新为主，missing reconciliation 也先拉到 Swift 再逐行修改。Infuse 更接近“临时索引/快照 → 成功后集合合并”的模型。
4. **元数据阶段串行、N+1、缺少共享缓存和限流。** Demo 会全量加载媒体库、逐文件查 binding、逐文件调用网络服务，并在每个成功项后重写完整 `poster_metadata.json`。同一剧集的 series/artwork 信息被重复请求，重扫不能有效复用，网络失败又会阻塞完成语义。

本机合成基准已经清晰暴露复杂度问题：扁平文件从 1,000 增至 8,000 时，耗时从 0.48 秒增至 26.93 秒；文件数每翻倍，耗时约增长 4 倍。4,000 个完全未变化文件的重扫仍需 6.69 秒，几乎等于首次扫描的 6.66 秒。1,000 个单文件目录产生了 1,002 个页面，耗时 11.70 秒，最终检查点达到 157,858 字节。

建议按以下顺序实施，避免同时重写全部系统：

1. 建立可重复基准和埋点；
2. 修复传输层伪分页；
3. 将检查点改为常量级/前沿级状态；
4. 引入扫描 staging 和集合化 SQL；
5. 重构刮削为分阶段、可缓存、有限流的实体流水线；
6. 增加调度、增量扫描和进程恢复；
7. 补齐文件名解析、本地元数据、过滤规则及服务器来源模式。

其中前四项是扫描性能和正确性的 P0；元数据流水线是用户感知性能的 P0/P1。

---

## 2. 调研范围、样本和限制

### 2.1 Infuse 样本

- iOS IPA：`/Users/zzzhr/Downloads/com.firecore.infuse_8.5.1_und3fined.ipa`
  - 版本：8.5.1
  - Build：5726
  - 架构：ARM64
  - Mach-O `cryptid=0`，可进行静态字符串、符号、选择器和 SQL 分析
  - IPA SHA-256：`964c1df87cc55b0c5c5b350c281ce6242a8c3ee3688a89c8f986ac4529f7eda1`
  - iOS 主二进制 SHA-256：`1ba8ad02d9a9252511e3c92f8e83e33cb357ea59914dfb30b909e32b89098bf2`
- 本机安装版：`/Applications/Infuse.app`
  - 版本：8.5.3
  - Build：5741
  - 架构：x86_64 / arm64 Universal
  - 8.5.1 中观察到的核心类、选择器和 SQL 架构在该版本仍然存在

### 2.2 我方样本

- Demo：当前目录 `StellarOAuthDemo`
- 扫描核心：`StellarMediaLibrary`
- SMB 连接器：`StellarSMB2Core` / `StellarSMB2Libsmb2`
- 持久化：`StellarStorage`
- 数据库 schema：`specs/storage/sql/library-v1.sql`

### 2.3 使用的方法

- 对 Infuse 主二进制进行类名、Objective-C selector、字符串、内嵌 SQL 和配置键的交叉分析；
- 对本机安装版复核关键架构是否继续存在；
- 对 Firecore 官方文档中的公开行为进行对照；
- 沿我方 `MediaLibraryModel → MediaScanner → MediaSource → MediaScanSink → LibraryStore` 调用链审阅实现；
- 使用 Release 构建的实际 `MediaScanner + LocalMediaSource + SQLiteMediaScanSink` 做合成目录基准；
- 运行扫描器/SQLite 相关测试，并完成 iOS Simulator 构建验证。

### 2.4 结论置信度和边界

- **高置信度：** Infuse 存在独立索引器、网络索引状态、爬取状态、临时 `FileIndex`、成功后集合合并、分阶段元数据和缩略图处理、QPS/429 控制、延迟元数据清理。
- **中置信度：** 各阶段之间的总体先后关系、失败时不发布权威删除、普通共享与 Plex/Emby/Jellyfin 走不同路径。
- **未完全确认：** Infuse 每个版本的精确并发数、每类源的具体默认批量大小、所有阶段的运行时调度细节。静态分析能证明能力和架构，但不能把所有常量当作稳定公开契约。
- 本报告的本机耗时是**我方实现的复杂度基准**，不是 Infuse 与我方的同机跑分。对 Infuse 的比较主要是行为、数据流和持久化架构对比。
- 本报告只描述可观察行为和清洁室实现方向，不复制 Infuse 的专有实现代码、私有服务凭据或受保护资源。

---

## 3. Infuse 的扫描与刮削方案

## 3.1 入口和扫描范围

Infuse 的 Library 并不是无条件遍历所有可访问路径。其范围大致由以下信息共同确定：

```text
Share / VFS
    └── Favorite / Library inclusion
          ├── include roots
          ├── excluded favorites
          ├── excluded files/folders
          └── .nomedia / visibility rules
                └── Library indexing scope
```

这意味着“可以浏览”与“需要加入资料库并持续索引”是两种不同语义。普通目录浏览可以使用轻量目录 crawler；加入 Library 后才进入完整、持久、可恢复的索引流程。这个区分对大型 NAS 很重要：用户只访问一次的目录不应自动承担整库刮削成本。

官方公开行为还表明：

- 应用打开时可自动扫描；空闲时可周期扫描；
- 预缓存详情和 artwork 是可配置行为，并会影响扫描时间；
- Favorite 可以从 Library 排除；
- `.nomedia` 可抑制目录内容进入索引；
- 本地/嵌入元数据可以优先于在线匹配。

## 3.2 持久扫描状态

二进制中可见的状态和配置表明 Infuse 不把扫描仅看成一次内存递归：

- `VFSIndex(Id, VFS_Key, IndexingState, IndexDate, Enabled)`
- `ShareIndexing.plist`
- `ShareIndexingCrashes.plist`
- 爬取栈、子树深度、offset、total 等断点信息
- `FCShareIndexingState`
- `saveCrawlingStateForSection:depth:offset:total:`

这套状态用于：

- 在应用重启或网络中断后恢复；
- 区分正在扫描、已完成、失败和禁用的来源；
- 只在权威扫描成功后推进索引日期/版本；
- 对崩溃或异常目录采取保护措施。

## 3.3 普通文件来源的主数据流

从类、selector 和 SQL 可以重建出如下主流程：

```text
确定索引范围
    ↓
Tree crawler / network indexer
    ↓
分页或分批枚举目录
    ↓
写入临时 FileIndex
    ↓
完整快照成功？ ── 否 ──→ 保存状态，不发布权威删除
    │
    是
    ↓
临时 FileIndex 与持久 FileIndex 做集合合并
    ↓
主元数据解析/匹配
    ↓
缩略图和 artwork
    ↓
次级元数据、搜索、Spotlight、Up Next
```

可见的关键组件包括：

- `FCMIndexer`
- `FCNetworkIndexer`
- `FCShareIndexingState`
- `TreeCrawlingService`
- `FCBatchLoadingEnumerator`
- `FCQPSOperationQueue`

关键 selector 包括：

- `addIndexCrawlerForVFS:`
- `addMetadataFetcherForVFS:primary:`
- `addThumbnailsFetcherForVFS:`
- `addItemsToTemporaryIndex:`
- `moveIndexToPersistentStore:status:includeFileIndexParents:excludeFileIndexParents:`
- `saveCrawlingStateForSection:depth:offset:total:`

这里最值得借鉴的不是名称，而是两个边界：

1. **目录发现与元数据刮削分离。** 文件事实先形成可靠索引，慢速网络元数据随后处理。
2. **临时索引与正式索引分离。** 只有完整成功的扫描快照才有资格证明“旧文件已经不存在”。

## 3.4 临时索引与集合合并

Infuse 二进制中存在与下面形式一致的 SQL：

```sql
DELETE FROM FileIndex
WHERE ...
  AND ItemID IN (
      SELECT ItemID FROM FileIndex
      EXCEPT
      SELECT ItemID FROM temp.FileIndex
  );

INSERT OR IGNORE INTO FileIndex
SELECT * FROM temp.FileIndex;
```

另有批量更新 ModificationDate 和索引状态的 SQL。其意义是：

- 枚举阶段主要写 staging/temp；
- 网络失败、取消、鉴权失败和根目录不可信时，正式索引仍保留上一次成功快照；
- 成功后通过数据库集合运算处理新增、更新和消失项，而不是把大量候选拉进应用层逐行判断；
- 删除/缺失判断只针对此次扫描的权威范围。

这比“边扫边覆盖正式路径，结束时再补 missing”更容易证明正确性。

## 3.5 元数据优先级和阶段

普通文件来源大致采用多级元数据链：

1. 容器/媒体流信息，例如基于 ffmpeg 的探测；
2. 特定格式处理，例如 EyeTV；
3. 用户覆盖、本地元数据、NFO、同目录图片和内嵌标签；
4. 在线提供商匹配，例如 TMDB；
5. 缩略图、海报、背景图及派生展示数据；
6. 搜索、Spotlight、Up Next 等二级索引。

在线阶段可见直接 TMDB 路径和 Infuse 代理/回退路径，也可见：

- 有界的元数据/缩略图并发；
- QPS operation queue；
- HTTP 429 处理；
- 将主元数据与缩略图/次级元数据分开调度。

因此 artwork 获取失败不必让文件发现失败；提供商暂时不可用也不应使整个 Library 不可浏览。

## 3.6 缺失项和元数据清理

Infuse 的行为证据支持两种不同生命周期：

- **文件索引缺失：** 只有一次权威、完整、成功的来源快照才能确认。失败、取消、离线和范围不完整不能证明删除。
- **孤立元数据清理：** 采用先标记、后延迟删除的两阶段方式。可见的延迟值为 604,800 秒，即 7 天；只有没有任何启用文件引用时才进入清理。

用户状态（播放进度、收藏、手工匹配等）与文件存在性分开保存，这可以避免文件短暂离线后丢失用户数据。

## 3.7 Plex、Emby、Jellyfin 等服务器来源

这类来源不应被建模成普通 SMB 文件树：

- 媒体实体、海报、集/季关系和播放状态优先来自服务器 API；
- Library Mode 会同步服务器资料库到 Infuse 的 Library；
- Direct Mode 更偏向按需浏览，不要求建立完整本地镜像；
- 官方文档描述的典型同步节奏包括应用打开时、前台约每 15 分钟，以及 Apple TV 后台约每小时；这些是产品行为参考，不应硬编码为跨平台真理。

长期看，我方需要让“文件系统来源”和“媒体服务器来源”实现不同的 source adapter，而不是让后者伪装成目录和文件。

---

## 4. 我方当前实现

## 4.1 当前数据流

```text
MediaLibraryModel.startScan
    ↓
MediaScanner.scan
    ├── root preflight / stat
    ├── pending page task group
    ├── MediaSourceSession.listPage
    ├── classify entries / stable identity
    └── sink.commit(entries + checkpoint)
          ↓
SQLiteMediaScanSink / LibraryStore
    ├── media_file upsert
    ├── scan queue enqueue
    ├── scan_run checkpoint
    └── successful completion → reconcile missing

MediaLibraryModel.enrichLibrary
    ↓
load full snapshot → per-file binding/network resolve/artwork
    ↓
poster_metadata.json + queue completion
```

## 4.2 已有优势，后续必须保留

### 扫描正确性基础

- 扫描器不依赖具体来源，`MediaSource`/`MediaSourceSession` 抽象可承载 SMB、本地和 WebDAV；
- 支持 full、incremental、repair 模式的数据模型；
- 根目录预检和身份校验可阻止错误根路径参与 missing 判断；
- 明确建模 path semantics 和 stable identity；
- 默认 page size 为 500，并使用有界 task group；
- 页面条目和更新后的 checkpoint 在同一数据库事务提交；
- 失败/取消会保存 checkpoint，不会调用成功完成逻辑；
- missing reconciliation 仅由完成路径授权；
- SQLite upsert 幂等，稳定 ID 可保留移动/重命名时的实体身份；
- missing reconciliation 已有 source/scope 约束的设计意识。

### UI 和元数据基础

- UI 进度有约 250 ms 节流，避免每个文件都触发界面刷新；
- 匹配层已有手工锁定、打分和实体概念；
- schema 已包含 scan run、scan queue、metadata、artwork、search 等可扩展结构；
- `scan_queue` 已预留部分 lease 字段，为后续可靠 worker 提供了起点。

### 已执行验证

- 13 个相关扫描器/SQLite 测试通过；
- iOS Simulator 构建成功；
- SQLite 隔离“大文件批次”测试中，2,000 条记录、两次提交和 snapshot 约 0.191 秒，说明 SQLite 本身不是当前 2k/4k/8k 非线性增长的主要原因。

---

## 5. 性能基准

## 5.1 基准条件

- Release 构建；
- Apple Silicon 本机；
- 本地 SSD；
- 使用真实的 `MediaScanner + LocalMediaSource + SQLiteMediaScanSink`；
- 合成的空 `.mkv` 文件，排除真实媒体解码和在线刮削影响；
- CLI 输出重定向，尽量降低终端渲染噪声；
- 结果用于识别我方复杂度，不作为与 Infuse 的直接跑分。

## 5.2 结果

| 场景 | 被扫描条目 | 页面数 | 最终 checkpoint | 耗时 |
|---|---:|---:|---:|---:|
| 扁平目录 1,000 文件 | 1,000 | 2 | 27,831 B | 0.48 s |
| 扁平目录 2,000 文件 | 2,000 | 4 | 55,037 B | 1.81 s |
| 扁平目录 4,000 文件 | 4,000 | 8 | 109,449 B | 6.66 s |
| 扁平目录 8,000 文件 | 8,000 | 16 | 218,274 B | 26.93 s |
| 4,000 文件无变化重扫 | 4,000 | 8 | 109,449 B | 6.69 s |
| 200 目录 × 10 文件 | 2,200 | 201 | 79,330 B | 0.82 s |
| 1,000 目录 × 1 文件 | 2,000 | 1,002 | 157,858 B | 11.70 s |

## 5.3 解读

### 扁平大目录接近二次复杂度

文件数翻倍时：

- 1k → 2k：耗时约 3.8 倍；
- 2k → 4k：耗时约 3.7 倍；
- 4k → 8k：耗时约 4.0 倍。

这与“每一页重新获取和处理完整目录”的复杂度吻合。设目录条目数为 `D`，逻辑页大小为 `P`，若每页都重新完整 list/sort，则成本近似：

```text
ceil(D / P) × O(D log D + network_list(D))
```

忽略排序对数项时，主体约为 `O(D² / P)`。在 SMB 上还会把 CPU 重复放大转换成真实网络往返、解码和服务器负载。

### 未变化重扫没有形成快速路径

4,000 文件完全未变时，6.69 秒与首次的 6.66 秒几乎一致。当前实现仍然：

- 重复列举和排序目录；
- 重建完整 seen/checkpoint；
- 对文件执行 SELECT 后 UPDATE/INSERT；
- 更新 `last_seen`/时间字段；
- 结束后全量重建部分派生数据。

增量扫描当前主要保证语义，并没有兑现性能收益。

### 大量小目录导致 checkpoint 写放大

1,000 个单文件目录需要 1,002 页。最终 checkpoint 为 157,858 字节，但它不是只写一次，而是每页都重写不断增长的 JSON。若按近似线性增长估算，单次扫描累计仅 checkpoint 编码/写入就约为：

```text
157,858 × 1,002 / 2 ≈ 79 MB
```

10,000 个单文件目录可能上升到 GB 级累计写放大。实际值取决于 identity 长度和数据库日志行为，但复杂度风险明确存在。

## 5.4 本轮优化后复测（2026-09-01）

复测仍使用 Release 构建、真实 `MediaScanner + LocalMediaSource + SQLiteMediaScanSink`，
命令行 JSON 输出重定向。结果会受本机负载影响，但复杂度和调用次数改善稳定可复现：

| 场景 | 优化前 | 优化后 | 说明 |
|---|---:|---:|---|
| flat 8,000 首扫 | 26.93 s | 2.64 s | 每目录完整读取从 16 次降为 1 次 |
| flat 8,000 unchanged 重扫 | 未单列 | 1.93 s | 不再重写 material timestamp/重复 enqueue |
| 2,000 文件两次原子提交 + snapshot 测试 | 约 0.191 s | 约 0.10–0.15 s | 多文件页使用临时批次表集合 merge |
| 1,000 目录 × 1 文件 | 11.70 s | 1.35 s | 1,002 页；最终 checkpoint 660 B，frontier 增量落库 |

8k 已接近但尚未稳定满足 2.5 秒初始预算。compact checkpoint 和持久 frontier 已消除大量
小目录场景的主要非线性开销；下一优先级转为 Phase 3 的 per-run discovery staging 和成功后
集合发布，不能把当前直接更新正式 `media_file` 的批次事务误认为 staging 已完成。

---

## 6. 与 Infuse 的逐项差距

| 主题 | Infuse 观察 | 我方当前实现 | 影响 | 优先级 |
|---|---|---|---|---|
| 目录分页 | 批量 enumerator/crawler，保存 section/depth/offset | 每个逻辑页可能重新完整 list/sort | 大目录近二次复杂度，SMB 重复网络 I/O | P0 |
| SMB 并发 | 有界队列，按来源能力调度 | Scanner 默认 4；单 libsmb2 context 实际串行 | 表面并发与真实吞吐不一致 | P0 |
| 扫描状态 | 持久爬取状态和 crash 状态 | checkpoint 完整保存 seen/completed 数组 | 每页 O(N) 编码、排序和写入 | P0 |
| 正式索引 | temp FileIndex，成功后集合合并 | 扫描中逐文件写正式 `media_file` | 中途失败仍暴露部分路径变化 | P0 |
| 差异合并 | SQL EXCEPT/批量更新 | Swift 拉候选，再逐 ID 更新 | 内存、事务和语句数量放大 | P0 |
| 元数据阶段 | 主元数据、缩略图、次级索引分离 | `.parse` 混合在线匹配/artwork | 慢服务阻塞整体完成 | P0/P1 |
| 提供商控制 | QPS queue、429 处理、回退 | 无统一 QPS、Retry-After 和退避 | 易触发限流，失败风暴 | P0/P1 |
| 共享实体复用 | 以媒体实体/剧集层组织 | 同剧集逐 episode 重取 series/artwork | N+1 网络请求 | P0/P1 |
| 元数据持久化 | 结构化数据库和缓存 | 每成功一项重写整个 JSON | O(N²) 文件 I/O，崩溃一致性差 | P0 |
| 搜索索引 | 二级阶段、按变更维护 | 每次全量 DELETE + INSERT | 未变化重扫仍昂贵 | P1 |
| 自动/增量触发 | 打开、空闲、服务器周期同步 | Demo 总是 full，缺少持久 scheduler | 重扫成本高，重启后选择丢失 | P1 |
| 范围过滤 | Favorite/exclusion/`.nomedia` | 主要在 sink 过滤，仍遍历所有内容 | 浪费网络、checkpoint、CPU | P1 |
| 本地元数据 | embedded/local/NFO/override 优先 | 已有部分库能力，但 Demo 未接入 | 不必要在线请求，匹配质量下降 | P1 |
| 格式覆盖 | 广泛视频/光盘/流媒体格式 | Demo 仅 14 个扩展名 | 漏扫常见库内容 | P1 |
| 服务器来源 | Plex/Emby/Jellyfin 专用 API，Direct/Library | 只有文件来源主路径 | 无法高效利用服务器现有索引 | P2 |
| 孤立元数据 | 先标记、7 天后清理 | 文件首次缺失即 unavailable，缺少 GC worker | 短暂离线体验差、孤立数据积累 | P1/P2 |

---

## 7. 关键问题详解

## 7.1 P0：SMB 伪分页

当前 `SMB2MediaSourceSession.listDirectory` 对每个 cursor page 都调用底层 `session.listDirectory(at:)`，然后对整个目录：

1. 映射协议条目；
2. 排序；
3. 计算目录 fingerprint；
4. 按 offset 截取当前页。

如果目录有 8,000 项、page size 500，就会完整读取并排序 16 次。第一页之后的 15 次并没有获得新的服务器快照，只是在重复构造同一结果。

本地和 WebDAV 适配器也存在类似问题：

- 本地来源在每个逻辑页重建目录快照；
- WebDAV 的 `Depth: 1 PROPFIND` 通常不提供标准服务器分页，逻辑分页会重复整个 PROPFIND 响应。

### 修复方向

长期方案是让传输层暴露真正的目录句柄：

```swift
protocol DirectoryCursorSession {
    func openDirectory(at path: String) async throws -> DirectoryHandle
    func readDirectoryBatch(
        _ handle: DirectoryHandle,
        limit: Int
    ) async throws -> DirectoryBatch
    func closeDirectory(_ handle: DirectoryHandle) async
}
```

对 libsmb2，应在 wrapper 中保留 `smb2dir`，分批调用 readdir，而不是在 connector 层反复打开目录。

短期兼容方案：

- 一个逻辑目录扫描期间只获取一次完整快照；
- cursor 仅在内存快照上切片；
- 最后一页、取消、断连和 source close 时释放；
- crash resume 时允许重新读取一次，并验证 root/directory fingerprint；
- WebDAV 若无法服务器分页，就将一次 `PROPFIND` 视为单页，或缓存本次响应，绝不重复请求同一目录。

短期缓存会增加峰值内存，但相对当前重复网络调用是明确的正收益；随后再切换真正流式句柄。

## 7.2 P0：生产 SMB 并发实际上被串行化

`Libsmb2SMB2SessionState.withClient` 明确限制每个 libsmb2 context 同时只有一个 active operation。Scanner 默认允许 4 个目录任务，但如果它们共用一个 session/context，最后仍在同一锁/队列后串行执行。

现有 fake source 的 bounded concurrency 测试只能证明 Scanner 不超过上限，不能证明真实 SMB 能并发 4 路。

### 修复方向

- 让 source/session 暴露 `preferredConcurrency` 或 capability；
- 单 libsmb2 context 默认设为 1，避免制造无效任务和排队内存；
- 若确有必要，可建立 2 个独立登录 session 的只读目录连接池；
- 连接池必须通过真实 NAS 基准决定，不能默认放大，因为多连接可能恶化低端 NAS、鉴权和限流；
- 文件读取、目录读取和元数据探测可以使用不同的 workload budget，避免大文件 I/O 饿死目录发现。

## 7.3 P0：checkpoint 结构造成非线性开销

当前 checkpoint 包含：

- `pendingPages`
- `completedPages`
- `seenEntryIdentityKeys`
- `seenDirectoryIdentityKeys`

每处理一页会把数组转为 `Set`、追加新元素、再把所有内容排序回数组；随后 `SQLiteMediaScanSink` 对整个 checkpoint 编码并更新 `scan_run`。

因此页面处理不是只处理当前页，而是反复处理“从开始到当前的所有状态”。

### 修复方向

checkpoint JSON 只保存恢复必需的小状态：

```text
schemaVersion
request / normalized scope
phase
source capabilities
root identity / root revision
frontier version or current cursor
counters / timestamps
```

去重和已见集合应交给数据库唯一键或本次运行的 staging 表；进程内只保留 mutable `Set`，不要每页全量排序。

推荐增加内部表（命名可调整）：

```sql
scan_frontier(run_id, directory_key, cursor, depth, state, ...)
scan_seen(run_id, source_id, stable_key, normalized_path, kind, ...)
```

如果暂时不希望把它们放入长期 schema，也可以使用每次 run 的临时 SQLite/staging database；关键是恢复状态必须有持久边界，且不能随 page × entries 二次增长。

## 7.4 P0：逐文件正式表写入与非原子发布

`LibraryStore.commit` 当前对每个文件执行查询后 UPDATE/INSERT。即使文件内容没有变化，也会更新 last_seen/updated_at。与此同时，扫描尚未完成时新路径和移动结果已经进入正式 `media_file`。

正确性风险示例：

```text
上次成功索引：/Movies/A.mkv
本次扫描第 1 页观察到：/Archive/A.mkv
第 2 页网络失败

当前行为：正式表可能已经显示 A 移动到 /Archive
理想行为：旧快照继续有效；失败 run 的发现结果保留在 staging，等待恢复/重跑
```

missing 已经受到完成边界保护，但 path/new-file/move 还没有同等强度的发布边界。

### 修复方向

- 每页批量写 `scan_seen`/staging；
- 完成后用一笔或少量集合化事务合并至 `media_file`；
- 使用 SQL UPSERT 的条件更新，仅在内容、路径或 material revision 变化时修改主记录；
- `last_seen_run_id` 可在集合语句中批量推进；
- missing 用一次带 scope 的 set-based UPDATE 完成，不把所有候选读进 Swift；
- scoped scan 先建立权威 candidate scope，避免 source-wide 读取后在内存过滤。

若产品要求“新发现文件尽快可见”，可以单独允许安全的 progressive insert，但必须把它与权威 path/missing 合并语义明确分开，并记录 `provisional_run_id`。默认更推荐完整快照发布。

## 7.5 P0：元数据流水线的 N+1 和 O(N²) I/O

Demo 的 `enrichLibrary` 当前有以下性能问题：

- 先加载完整 library snapshot，再在内存过滤；
- 每个文件单独查询 binding；
- 所有文件串行处理；
- 单文件可能执行：resolve POST、episode 的 series entity GET、series artwork page GET、artwork variants GET；
- 同一剧集的每集会重复获取 series 和 artwork；
- 使用 ephemeral URLSession，并设置 `.reloadIgnoringLocalCacheData`；
- 没有实体级 single-flight、持久 provider cache 或 negative cache；
- 每成功一个文件，将所有 poster metadata values 排序、编码并原子重写完整 `poster_metadata.json`；
- JSON 与 SQLite queue completion 分开提交，崩溃时可能一边成功、一边失败；
- `.parse` 阶段实际混合了本地解析、在线 resolve、match 和 artwork；
- `completeScanWork` / `retryScanWork` 基本按文件独立事务；
- 没有统一 QPS、`Retry-After`、指数退避、抖动和最大尝试次数；
- 永久 no-match 也可能被重复尝试；
- 每次扫描全量 `DELETE + INSERT` 重建 `search_doc`。

### 修复方向

将工作拆分为独立阶段：

```text
discover
  → filename_parse
  → local_metadata
  → online_match
  → entity_materialize
  → artwork
  → media_probe
  → search_index
```

建议完成语义：

- `filename_parse`、本地元数据读取是快速 required stage；
- `online_match` 失败可以生成 unmatched placeholder，不阻塞资料库可浏览；
- artwork 和深度 probe 默认 optional，可稍后补齐；
- 网络提供商 outage 不得让一次成功的文件发现退回失败。

实体和缓存策略：

- single-flight key：`provider + entityType + providerID + locale`；
- 同一剧集的 episodes 先分组，series details/artwork 只取一次；
- 将 provider response/cache key、ETag、TTL、negative result 写入 `metadata_cache`；
- 如果后端支持，增加 `resolveBatch(paths:)`；否则使用有界 task group；
- 对每个 host 设置并发和 QPS，解析 `Retry-After`，使用指数退避 + jitter；
- 401/403 等鉴权错误应暂停该 provider 队列，不能对所有文件持续重试；
- permanent no-match 进入 terminal 状态，只有输入 revision 或匹配规则版本变化时再试。

持久化策略：

- 移除每项重写的 `poster_metadata.json`；
- 使用现有 localized metadata/artwork/entity 表，必要时扩展 schema；
- 每 100–500 项或按时间窗口批量事务；
- queue 结果和 metadata/artwork 事实同事务提交；
- 查询待处理工作时直接 JOIN file/binding/metadata 并分页，不加载完整 snapshot；
- `search_doc` 只增量 upsert/delete 受影响 entity，完整重建仅用于 repair/migration。

## 7.6 P1：调度、恢复和增量语义未落地到 Demo

Demo 目前总是发起 `.full`；`activeRequest` 仅存于内存。即使 scan run/checkpoint 已持久化，应用重启后也无法可靠恢复“哪一个请求、哪一个 scope、哪一个运行应继续”。

另外，schema/代码没有强制同一 source 只能有一个 active run。并行 run 可能竞争 `last_seen_run_id` 和 missing reconciliation。`retryScanWork` 通过“该 source 最新 run”附着任务，在并发 run 下可能关联错误。

### 修复方向

- scheduler 以 `(source_id, normalized_scope)` 为 key；
- 合并重复触发，优先级建议：manual/repair > full > incremental > scheduled enrichment；
- app launch 时恢复未完成 run；凭据只保存安全引用，不写进 checkpoint；
- UI 提供 full、incremental、repair 的明确入口和状态；
- watcher 事件只作为 hint：例如 debounce 2 秒、max wait 10 秒；overflow 时升级 full；
- SMB 等没有可靠 watcher 的来源使用合理周期扫描；
- 手工 scan 可抢占 optional artwork/probe，但不破坏已提交的发现事实；
- 数据库强制一来源只有一个 active run，例如：

```sql
CREATE UNIQUE INDEX uq_scan_run_one_active_source
ON scan_run(source_id)
WHERE state IN ('preparing', 'running', 'reconciling');
```

实际 state 名称应与当前 enum 对齐。

## 7.7 P1：过滤发生得太晚

Demo 的可索引扩展名只有：

```text
3gp avi flv m2ts m4v mkv mov mp4 mpeg mpg mts ts webm wmv
```

Infuse 支持范围还包括 ASF、ISO/IMG、BDMV/DVD/VIDEO_TS、DVR-MS、MXF、OGM/OGV、STRM 等类型或媒体结构。是否全部支持播放应由播放器能力决定，但扫描器至少需要统一 capability/config，而不是在 Demo 硬编码小集合。

当前过滤主要在 sink/条目处理阶段发生，目录已经被遍历，文件已经进入 checkpoint 成本。还缺少：

- `.nomedia`；
- include/exclude root；
- Favorite/Library scope；
- 隐藏目录和系统目录策略；
- recycle/trash/package 规则；
- BDMV、DVD 等目录作为一个媒体项的早期识别。

过滤应尽可能前推到目录入队之前，这对网络来源是直接性能收益。

## 7.8 P1：stable ID 能力不能被强制假设

Demo 对 SMB inode 使用 `.persistent` 语义，但不同 SMB 服务端的 file ID/inode 行为并不一致：

- 某些服务器跨 reconnect 稳定；
- 某些仅在 session 或 share 内稳定；
- 某些会复用或返回无意义值。

应让 connector 通过 capability 或配置报告：

- persistent stable ID；
- session-stable ID；
- path-derived identity；
- 是否可安全检测 move。

在不可靠服务器上，移动识别需要 path + size + mtime + content hint 的保守策略，并避免错误合并两个不同文件。

## 7.9 P1：文件名解析和本地元数据没有接入主流程

SDK parser 已能识别常见 `SxxExx` 和 `x` 形式，但当前观察到的不足包括：

- `Inception.mkv` 在没有年份时可能成为 unknown；
- `SE2EP3` 未识别；
- `02-003` 未识别；
- 电影无年份且文件名含 release noise 时，noise 未充分清理；
- 缺少本地化季/集标记；
- 缺少“父目录提供 season、文件名只提供 episode”的组合；
- specials、按日期播出、绝对集数、多候选结果不足；
- 父目录、文件名、NFO、显式 provider ID 的候选优先级尚未形成统一 matcher input。

更重要的是，Demo 并未把已有的 `MediaFilenameParser`、`SQLiteMediaMetadataStore`、NFO/sidecar 能力接入实际扫描/刮削链，而是把大部分工作委托给开发服务。这样既损失离线能力，也增加网络请求和服务耦合。

建议候选优先级：

1. 用户手工锁定/覆盖；
2. NFO 或文件名中的显式 TMDB/IMDb ID；
3. 本地结构化元数据；
4. 父目录 + 文件名联合解析；
5. 单文件名解析；
6. 在线模糊搜索；
7. unmatched placeholder。

## 7.10 P1：队列并发、租约和陈旧结果保护不足

虽然 `scan_queue` 有 lease 相关字段，但 Demo 没有形成完整的 claim/heartbeat/lease-expiry worker 流程。还缺少：

- `observed_revision` / `input_revision`；
- worker 写回时比较 revision；
- 任务 required/optional 标记；
- provider/request key；
- terminal failure 与 retryable failure 区分；
- 最大尝试次数和 dead-letter/人工修复入口。

风险是：文件在刮削期间被替换或重新匹配，旧 worker 结果仍可能覆盖新状态。

## 7.11 P1/P2：缺失保护和垃圾回收

当前首次权威扫描确认缺失后就会把记录置 unavailable；schema 虽有部分 missing count/time 线索，但缺少完整策略和 cleanup worker。

建议区分：

- `available`：当前成功快照可见；
- `suspected_missing`：一次或短时间缺失，可配置；
- `unavailable`：达到来源特定阈值；
- `purge_eligible_at`：进入延迟清理窗口；
- 用户状态和手工匹配永不随一次文件删除直接清除。

对于本地磁盘，一次权威成功扫描通常足够；对于经常休眠、断线或返回异常空目录的 NAS，可使用“空根异常保护”、数量骤降阈值和短 grace period。

---

## 8. 目标架构

```text
Scan Scheduler
  ├── trigger merge / priority / debounce
  ├── one active run per source
  └── launch recovery
          ↓
Source Adapter + Capabilities
  ├── real streaming directory cursor
  ├── preferred concurrency
  ├── stable-ID guarantees
  └── early include/exclude rules
          ↓
Discovery Engine
  ├── bounded frontier
  ├── compact checkpoint
  └── page data + frontier atomically committed
          ↓
Per-run Staging Index
  ├── unique stable/path keys
  ├── replay-safe page inserts
  └── no authoritative deletion before success
          ↓
Set-based Publish / Reconcile
  ├── added / changed / moved / unchanged
  ├── scoped missing
  └── enqueue only changed material revisions
          ↓
Metadata Work Pipeline
  ├── filename + local metadata
  ├── provider match with cache/QPS/backoff
  ├── entity-level single-flight
  ├── artwork/probe optional work
  └── incremental search index
          ↓
Library Views / UI
```

### 必须保持的系统不变量

1. 非权威扫描不能确认 missing；
2. 失败/取消/离线不能破坏上一次成功快照；
3. page data 与恢复进度不能出现“进度已前进、数据未落库”的组合；
4. page replay 必须幂等；
5. worker 只能写回与自己 input revision 相同的结果；
6. 用户状态与文件可用性分离；
7. 网络元数据失败不能否定文件发现成功；
8. 所有并发上限必须来自真实 source/provider capability，而不是固定常量；
9. scoped scan 只能对其权威范围做 missing reconciliation；
10. 根目录身份异常、空根异常或范围变化时必须停止删除发布。

---

## 9. 分阶段实施计划

## Phase 0：基准、埋点和回归护栏（P0，预计 1–2 天）

### 工作项

- 新增可独立运行的 scanner benchmark target 或 XCTest performance suite；
- 固定以下 fixtures：
  - flat 1k / 2k / 4k / 8k；
  - 200×10 和 1,000×1；
  - unchanged rescan；
  - 第 N 页失败后恢复；
  - 根目录身份变化；
  - scoped scan；
  - 大目录协议调用计数 fake；
- 增加以下指标：
  - 每目录 list/open/read/close 次数；
  - entries/request、pages/directory；
  - source latency、queue wait；
  - checkpoint encode time/bytes/write bytes；
  - DB transaction latency、statements/page；
  - added/changed/moved/unchanged/missing 数；
  - provider request/cache hit/429/retry/QPS；
  - time-to-first-item、time-to-first-poster；
  - peak RSS；
  - 各 scan phase 用时。
- 性能日志按 run ID/source ID 关联，路径仅记录哈希或相对脱敏信息。

### 初始验收预算

这些是工程目标，不是对 Infuse 的宣称；Phase 0 采集稳定样本后可调整：

- 扁平目录文件数翻倍时，耗时倍率不超过 2.4；
- 本地 8k 空文件发现目标 ≤ 2.5 秒；
- 4k unchanged rescan ≤ 首扫 60%；
- 1,000×1 场景 ≤ flat 2k 的 3 倍；
- 一次逻辑扫描中，每个目录只产生一次协议级完整 list/open；
- checkpoint 最终值 < 64 KB，且不随全部 seen entries 线性增长；
- 主线程不出现 >16 ms 的同步 metadata 文件写入。

## Phase 1：修复目录伪分页（P0，预计 3–5 天）

### 工作项

- 为 SMB transport 增加 open/read-batch/close directory API；
- libsmb2 wrapper 保持真实目录句柄并处理取消/断连清理；
- connector cursor 绑定目录句柄和快照 revision；
- 先实现完整目录单次缓存作为兼容路径，再落地流式 batch；
- Local source 一次枚举后消费，或直接按单页返回；
- WebDAV 对一次 `Depth: 1` 响应只处理一次；
- source 暴露 `preferredConcurrency`，单 SMB context 默认 1；
- 增加目录在分页过程中改变时的 cursor conflict/restart 策略。

### 验收

- 8,000 项目录不论 page size 都只发生一次完整 list/open；
- cursor page 无重复和跳项；
- 取消会关闭句柄并释放 snapshot；
- crash resume 最多重列一次当前目录，并能检测不一致；
- 真实 NAS 上比较 1、2 独立 session 的吞吐和服务器负载后再决定是否启用池。

## Phase 2：压缩 checkpoint 与持久 frontier（P0，预计 4–7 天）

> 进度：核心数据路径已完成；更大规模故障注入和累计写入埋点继续纳入回归护栏。

### 工作项

- 将 `seenEntryIdentityKeys`、`seenDirectoryIdentityKeys`、全量 `completedPages` 移出 JSON；
- 新增 `scan_frontier` 和 `scan_seen`，或等价的内部 staging store；
- DB 唯一键负责 page replay 去重；
- Scanner 进程内使用 mutable set/queue，不在每页全量排序；
- checkpoint 仅保存版本、请求、阶段、根身份、frontier revision 和计数器；
- page entries 与 frontier transition 同事务；
- 允许按条目数/时间批量 checkpoint，但任何未提交 page 都必须可安全重放；
- 增加旧 checkpoint schema 的迁移或明确重新开始策略。

### 验收

- 1k、10k、100k 条目下 checkpoint 大小保持常量级或只与活跃 frontier/depth 相关；
- 10k 单文件目录场景累计 checkpoint 写入目标 <10 MB；
- 在 commit 前、commit 中、commit 后强制终止都不会跳页或误 missing；
- 恢复后的最终索引与一次完成扫描完全一致。

## Phase 3：staging 索引和集合化发布（P0，预计 1–2 周）

### 工作项

- schema 增加 per-run discovery staging；
- 同一 source active run 唯一约束；
- 页面使用 prepared statement/bulk insert 写 staging；
- 成功后执行 set-based added/changed/moved/unchanged diff；
- 使用条件 UPSERT，避免无变化文件 material update；
- missing reconciliation 改为 scope-aware 单条/少量 SQL；
- enqueue 只针对 material/input revision 变化的文件；
- 增加 `observed_revision`、`input_revision`、trigger/request key、heartbeat；
- worker 写回校验 run、lease 和 revision；
- 明确 provisional visibility 策略；默认失败 run 不改变已发布路径快照。

### 验收

- 第 2 页失败时，上一次正式快照完全不变；
- 同一 source 无法创建两个 active run；
- scoped scan 不触碰范围外记录；
- move 保留 file/entity/user-state identity；
- unchanged rescan 不产生不必要 metadata work；
- 100k diff 的内存不随所有 candidate Swift 对象线性膨胀；
- missing 发布与 scan success 在同一可证明事务边界内。

## Phase 4：重构元数据/刮削流水线（P0/P1，预计 2–3 周）

### 工作项

- 将 `.parse` 拆成 filename/local/match/materialize/artwork/probe/search；
- 定义 required/optional 和 terminal/retryable 状态；
- 待处理工作改为 SQL JOIN 分页；
- 引入 worker claim、lease、heartbeat、lease expiry；
- 任务带 `input_revision`，写回采用 compare-and-set；
- 实现 per-provider 并发、QPS、429/Retry-After、退避和 jitter；
- provider cache 支持 ETag/TTL/negative result；
- entity single-flight；
- episode 按 series 分组复用详情和 artwork；
- 后端若可改，提供 batch resolve；
- poster/localized metadata/artwork 全部进入 SQLite，并与 queue 状态同事务；
- 移除逐文件全量重写 `poster_metadata.json`；
- 搜索索引改为按 entity 增量维护。

### 验收

- 100 集同一剧集：最多约 100 次 resolve（或更少的 batch）+ 1 次 series details + 1 组 artwork 请求，不再每集重复 series/artwork；
- 有效缓存下 unchanged rescan 不产生 provider 请求；
- provider 429 严格遵守 `Retry-After`；
- provider 故障时文件和本地标题仍可浏览，run 不因 optional artwork 卡死；
- 第一张海报可在全部 artwork 完成前显示；
- crash 后不会出现 metadata 已写但 queue 未完成，或反向不一致；
- stale worker 不能覆盖新匹配或新文件 revision。

## Phase 5：增量调度、恢复和后台策略（P1，预计 1–2 周）

### 工作项

- 引入 scheduler 和 trigger merge；
- launch 时恢复 unfinished run；
- UI 暴露 full/incremental/repair；
- 文件 watcher 只生成 hint，并做 debounce/max-wait；
- watcher overflow 或 source revision 不可信时升级 full；
- SMB/NAS 使用周期扫描并在前台/电源/网络条件下调度；
- 手工扫描可优先于 scheduled artwork/probe；
- 保存 request scope 和安全 credential reference；
- 增加任务中心：当前 phase、发现/匹配/artwork 进度、暂停原因、重试入口。

### 验收

- 短时间重复触发只形成一个合并 run；
- 在 discovery、publish、match、artwork 各阶段强杀应用后均可恢复；
- source 离线不会形成扫描风暴；
- 手工扫描能及时开始，optional work 可让路；
- active run 和 UI 状态跨进程重启一致。

## Phase 6：匹配质量、过滤和来源能力（P1/P2，预计 2–4 周）

### 工作项

- 接入 `MediaFilenameParser`、本地 metadata store、NFO/JSON/sidecar/artwork/subtitle；
- 支持显式 TMDB/IMDb ID、无年份电影、`SE2EP3`、`02-003`、本地化季集、specials、日期集、绝对集数；
- 结合父目录生成多个候选并保留解释性 score；
- `.nomedia`、include/exclude、隐藏/回收目录在 enqueue 前生效；
- 扩展媒体格式和 BDMV/DVD/ISO 等结构识别；
- source capability 决定 stable ID、pagination 和并发；
- 增加空根和数量骤降保护；
- 实现 missing grace 和 7 天级别的孤立实体 GC，可配置而非写死；
- 后续增加 Plex/Emby/Jellyfin 专用 adapter，并分别支持 Library/Direct 语义。

### 验收

- fixture matrix 覆盖电影、剧集、特殊集、本地化命名、多版本、光盘目录；
- `.nomedia` 子树不发生远端遍历和 metadata enqueue；
- 手工锁定永远优先，普通重扫不能覆盖；
- 无在线服务时仍能完成发现、本地解析和基础展示；
- NAS 返回异常空根时不会把整个 Library 标记 unavailable；
- 媒体服务器来源不会降级为全目录文件扫描。

---

## 10. 建议修改的文件与职责

| 文件/模块 | 建议修改 |
|---|---|
| [`MediaLibraryModel.swift`](StellarOAuthDemo/MediaLibraryModel.swift) | 移除全量 snapshot/N+1 和 poster JSON；接 scheduler/worker；显示分阶段进度；不再固定 full |
| [`MediaScanner.swift`](../../../platforms/swift/Sources/StellarMediaLibrary/MediaScanner.swift) | 使用 source capability；持久 frontier；去除每页全量 set/sort；staging commit；恢复/冲突策略 |
| `SMB2Transport.swift`（SMB2Core） | 增加目录 handle、read batch、close 和 preferred concurrency API |
| [`SMB2MediaSourceConnector.swift`](../../../platforms/swift/Sources/StellarSMB2Core/SMB2MediaSourceConnector.swift) | 将 cursor 映射到真实句柄或一次性 snapshot；不再每页完整 list |
| [`Libsmb2SMB2Transport.swift`](../../../platforms/swift/Sources/StellarSMB2Libsmb2/Libsmb2SMB2Transport.swift) | 保留 smb2dir；可靠关闭；暴露单 context 串行能力；可选多 session 实验 |
| [`SQLiteMediaScanSink.swift`](../../../platforms/swift/Sources/StellarMediaLibrary/SQLiteMediaScanSink.swift) | 小 checkpoint；批量 staging；成功 publish；按 material revision enqueue |
| [`LibraryStore.swift`](../../../platforms/swift/Sources/StellarStorage/LibraryStore.swift) | set-based merge/missing；active-run 约束；queue lease/revision；分页 JOIN work query |
| [`library-v1.sql`](../../../specs/storage/sql/library-v1.sql) 或 v2 migration | staging/frontier/seen、active run unique index、provider cache、revision/required 字段、GC 状态 |
| [`MediaFilenameParser.swift`](../../../platforms/swift/Sources/StellarMediaLibrary/MediaFilenameParser.swift) | 补齐命名模式、多候选、父目录上下文、noise 清理和显式 provider ID |
| [`LibraryDerivedIndex.swift`](../../../platforms/swift/Sources/StellarStorage/LibraryDerivedIndex.swift) | search_doc 增量 upsert/delete；完整 rebuild 仅 repair/migration |
| Scanner/Storage/SMB tests | 增加调用次数、故障注入、恢复、scoped missing、stale worker、真实性能回归 |

实施时先核对模块中的实际文件名和公开 API；上表按当前调研调用链定位职责，不要求一次 PR 完成所有迁移。

---

## 11. 数据库设计草案

以下仅表达字段职责，迁移时应与现有命名、外键和时间格式统一。

```sql
-- 每次 run 的目录前沿；一页完成时与本页 seen 数据同事务推进
CREATE TABLE scan_frontier (
    run_id TEXT NOT NULL,
    directory_key TEXT NOT NULL,
    normalized_path TEXT NOT NULL,
    cursor_blob BLOB,
    depth INTEGER NOT NULL,
    state TEXT NOT NULL,
    directory_revision TEXT,
    updated_at REAL NOT NULL,
    PRIMARY KEY (run_id, directory_key)
);

-- 临时发现事实；唯一键确保页面重放幂等
CREATE TABLE scan_seen (
    run_id TEXT NOT NULL,
    source_id TEXT NOT NULL,
    stable_key TEXT NOT NULL,
    normalized_path TEXT NOT NULL,
    kind TEXT NOT NULL,
    size INTEGER,
    modified_at REAL,
    observed_revision TEXT NOT NULL,
    payload BLOB,
    PRIMARY KEY (run_id, stable_key),
    UNIQUE (run_id, normalized_path)
);

-- state 值需按现有实现调整
CREATE UNIQUE INDEX uq_scan_run_one_active_source
ON scan_run(source_id)
WHERE state IN ('preparing', 'running', 'reconciling');
```

队列建议至少补充：

```text
input_revision
required
provider_key
request_key
claimed_by
lease_expires_at
heartbeat_at
attempt_count
max_attempts
failure_class
next_attempt_at
```

provider cache 建议 key：

```text
provider + endpoint/version + normalized request + locale + auth scope
```

缓存值至少记录 ETag、Last-Modified、expires、negative/positive、response schema version。不要缓存或记录 access token 本身。

---

## 12. 测试与验收矩阵

## 12.1 扫描正确性

- 第二页失败：不发布 missing，不丢第一页，恢复后不重复最终结果；
- 取消：保存可恢复状态，不把 run 标记成功；
- root identity 改变：拒绝 missing merge；
- root 返回异常空目录：触发保护而非全库下线；
- scoped scan：范围外路径完全不变；
- move/rename：可靠 stable ID 下保留 file ID、metadata 和播放状态；
- 不可靠 stable ID：不得误合并相似文件；
- page replay：数据库结果幂等；
- 两个 active run：数据库拒绝或 scheduler 合并；
- scan success 与 missing publish：事务性验证。

## 12.2 传输和性能

- flat 1k/2k/4k/8k 的时间和倍率；
- 1,000×1 的 checkpoint bytes、累计写 bytes、page count；
- page size 100/500/1,000 下，每目录协议 list 次数固定为 1；
- SMB 真实 NAS 上单 session 与双 session；
- WebDAV 每目录 PROPFIND 次数固定为 1；
- 取消时目录句柄数量归零；
- 100k staging merge 的 transaction time 和 peak RSS；
- unchanged rescan 的 SQL statement、metadata enqueue、provider request 均显著下降。

## 12.3 元数据和队列

- 100 集同剧：series/artwork single-flight；
- 相同 entity 并发请求：只有一个真实 provider call；
- 429 + `Retry-After`；
- 5xx 退避和 jitter；
- 401/403 暂停 provider；
- permanent no-match 终止；
- input revision 改变后旧 worker 写回被拒绝；
- lease worker 崩溃后任务可回收；
- required 完成、optional 失败时媒体仍可用；
- cache TTL/ETag/negative cache；
- queue completion 与 metadata 事实原子提交。

## 12.4 进程恢复

在以下边界注入 `SIGKILL` 或测试等价故障：

- 目录页读取前/后；
- staging commit 前/后；
- checkpoint/frontier transition 前/后；
- publish merge 中；
- metadata provider 响应后、DB commit 前；
- metadata commit 后、queue ack 前；
- search index 更新中。

每种故障都应满足：无误删除、无跳项、可重放、最终结果与无故障运行一致。

## 12.5 匹配 fixture

- 电影：有/无年份、版本标签、分辨率/codec/release group noise；
- 剧集：`S02E03`、`2x03`、`SE2EP3`、`02-003`；
- specials：S00、Special、SP；
- 日期集：`2026-09-01`；
- 绝对集数和 anime 常见形式；
- 父目录为 `Season 02`、文件仅 `03`；
- NFO/provider ID 与文件名冲突；
- 用户手工锁定；
- 多语言标题和 Unicode 规范化；
- BDMV/DVD/VIDEO_TS/ISO 目录结构；
- `.nomedia` 和 exclude subtree。

---

## 13. PR 拆分建议

为了降低迁移风险，建议按可独立回滚的 PR 提交：

1. `perf: add scanner benchmarks and metrics`
2. `fix(smb): keep one directory enumeration across cursor pages`
3. `feat(source): expose pagination and concurrency capabilities`
4. `perf(scan): replace growing checkpoint sets with persistent frontier`
5. `feat(storage): add per-run discovery staging`
6. `perf(storage): publish scan diff with set-based SQL`
7. `fix(scan): enforce one active run per source and revision-safe workers`
8. `refactor(metadata): split required and optional work stages`
9. `perf(metadata): add provider cache, single-flight and rate limiting`
10. `refactor(demo): persist poster metadata in SQLite and remove full JSON rewrite`
11. `perf(search): incrementally maintain search documents`
12. `feat(scan): scheduler, incremental triggers and launch recovery`
13. `feat(metadata): integrate local parser/NFO/sidecars`
14. `feat(scan): early exclusions, .nomedia and source format capabilities`
15. `feat(source): server-library adapters and Direct/Library modes`

每个性能 PR 都应附带修改前后 benchmark；每个状态机 PR 都应带故障注入测试。

---

## 14. 风险和取舍

### 完整目录缓存 vs 真流式句柄

- 缓存是最快的 P0 修复，协议调用从 N 页 × 1 次降为每目录 1 次；
- 代价是单个超大目录的内存峰值；
- 真流式句柄长期更优，但 wrapper、恢复和目录变更语义更复杂；
- 建议先缓存止血，同时完成 handle API。

### 多 SMB session

- 可能提高高延迟 NAS 的吞吐；
- 也可能增加服务器压力、连接建立和凭据问题；
- 单 context 内的 4 个 Swift task 不等于 4 路协议并发；
- 必须用真实设备数据决定，默认保持保守。

### staging 的可见性

- 完整成功后发布最容易保证快照一致性；
- progressive insert 能缩短新文件首次出现时间，但增加 provisional 状态；
- 如果采用 progressive，只允许不会否定旧事实的新增，move/missing 仍需成功边界。

### checkpoint 压缩

- 不能为了小而丢失删除安全性；
- 更推荐数据库唯一键 + page replay，而不是依赖巨型 JSON 精确记录每个 seen identity；
- 重放带来少量重复工作，但比持续二次写放大更可控。

### 元数据批量化

- batch resolve 需要后端配合；
- 即使后端暂时不能改，也可先实现有界并发、实体 single-flight、SQLite cache 和 series grouping；
- 缓存必须版本化并允许手工 refresh，避免长期保留错误匹配。

### schema 迁移

- staging/frontier/queue revision 属于存储层结构变化；
- 应提供向前迁移、旧 run 处理策略和 repair path；
- 不建议在同一 PR 同时迁移 schema、重写扫描器和更换 UI。

---

## 15. 立即可执行的前三个任务

### 任务 A：锁定性能回归

- 把本报告的 7 个合成场景纳入自动 benchmark；
- 为 fake SMB/WebDAV source 增加底层 list 调用计数；
- 输出 checkpoint encode/write、DB commit 和 source list 分段耗时。

完成标准：CI 或开发机可以一条命令复现当前近二次曲线，结果存为机器可读 JSON。

### 任务 B：目录只读一次

- 先在 connector session 中缓存当前目录快照；
- cursor 页面复用该 snapshot；
- 最后一页/取消时释放；
- 增加 8k 条目、page size 500 时 list count = 1 的测试。

完成标准：8k 扁平场景从 16 次完整目录读取降为 1 次，耗时曲线接近线性。

### 任务 C：停止每页重写全量 seen 集合

> 状态：已完成核心实现与 SQLite 中断恢复测试。

- 引入最小 `scan_seen`/`scan_frontier` 原型；
- checkpoint JSON 移除 seen arrays；
- 当前页数据和 frontier 更新同事务；
- 做 1,000×1 故障恢复测试。

完成标准：最终 checkpoint 和累计写入不再随 page × entries 增长，且恢复结果不变。

---

## 16. 完成定义

本轮扫描/刮削重构可以在满足以下条件时视为完成：

- 扫描性能随条目数近似线性增长；
- SMB/WebDAV 每目录不因逻辑分页重复完整网络列举；
- checkpoint 不保存全库 seen/completed 列表；
- 失败/取消不会发布部分权威路径变化或 missing；
- diff/missing 使用集合化数据库操作；
- 同一 source 最多一个 active run；
- unchanged 重扫不重复生成全部 DB/metadata/search 工作；
- 元数据具备分阶段、single-flight、缓存、QPS、429 和退避；
- artwork/provider 故障不阻塞基础 Library；
- poster metadata 不再逐项重写全量 JSON；
- app 重启可以恢复 scan 和 metadata work；
- 本地 parser/NFO/sidecar 和 early exclusion 接入实际 Demo；
- 关键故障边界均有自动化测试；
- 真实 NAS 上的吞吐、请求数、内存和服务器负载达到约定预算。

---

## 17. 参考资料与已有调研

仓库内已有分析：

- [Infuse iOS 8.5.1 静态分析](../../../docs/research/infuse/infuse_ios_8.5.1_static_analysis.md)
- [Infuse Library 扫描重建与我方扫描器设计](../../../docs/research/infuse/infuse_library_scan_rebuild_and_our_scanner_design.md)
- [Infuse TMDB matcher parity audit](../../../docs/research/infuse/infuse_tmdb_matcher_parity_audit.md)

Firecore 官方说明：

- [Library Scanning & Indexing](https://support.firecore.com/hc/en-us/articles/27862264977047-Library-Scanning-Indexing)
- [Streaming from Plex, Emby and Jellyfin](https://support.firecore.com/hc/en-us/articles/360006462093-Streaming-from-Plex-Emby-and-Jellyfin)
- [Excluding Files and Folders](https://support.firecore.com/hc/en-us/articles/4405044108183-Excluding-Files-and-Folders)
- [Using Embedded Metadata](https://support.firecore.com/hc/en-us/articles/4405036751767-Using-Embedded-Metadata)
- [What is Infuse?](https://support.firecore.com/hc/en-us/articles/360045051934-What-is-Infuse)
- [Metadata 101](https://support.firecore.com/hc/en-us/articles/215090947-Metadata-101)

建议后续在授权设备和测试 NAS 上补充动态验证：记录 Infuse 的首次/二次扫描阶段时间、真实 SMB 目录调用、失败恢复和提供商请求节奏；这些数据用于校准本计划的性能预算，不改变前述 P0 复杂度结论。

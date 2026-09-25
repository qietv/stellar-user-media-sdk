# SDK 海报墙扫描与 Infuse 研究结论对照

日期：2026-09-25。SDK 对照基线：`932bc66`。研究对象：本机 `debug-infuse` 项目归档的
Infuse iOS/macOS 8.5.1 静态分析，不代表对最新版 Infuse 的动态性能测试。

## 判断

两者采用的核心路线同样合理：来源枚举 → 本地文件索引 → 元数据匹配 → 本地海报墙投影，
文件存在性由成功扫描快照决定，图片和技术探测独立补齐。SDK 已有可靠的主体架构，
不需要改成“逐个文件请求在线服务、全部刮削成功后才算扫描完成”。

Infuse 的完整产品能力更成熟，尤其是多候选解析、不同来源的调度和服务器同步。
SDK 的优势是安全规则显式、可测试：异常数量骤降复核、持久任务租约、文件 revision 校验，
以及人工绑定和用户状态保护。不过静态分析没有证实 Infuse 缺少这些能力，不能据此宣称
SDK 全面更安全或更快；也没有同一 NAS、同一媒体库的耗时/内存/请求数对照数据。

`debug-infuse` 中的 Go/Python matcher 是规则验证工具，没有完整持久扫描事务和任务生命周期，
不宜用它替换 SDK scanner。

## 逐项对照

| 维度 | `debug-infuse` 的证据 | SDK 实现与判断 |
| --- | --- | --- |
| 枚举与匹配解耦 | crawler、primary metadata、thumbnail、secondary metadata 分阶段 | `MediaScanner` 先提交发现结果，`scan_queue` 驱动后续工作；方向一致 |
| 快照与缺失 | 临时 FileIndex，成功后按 VFS/Favorite 范围集合差 | `scan_discovery` 暂存，完成事务发布并按 covered roots 协调；中断不发布部分结果 |
| 大规模扫描成本 | 有并发上限与阶段队列，准确数值需动态验证 | 默认目录并发 4，服从 connector 上限；来源有界分页/磁盘队列，SQLite 窗口索引与单页原子提交 |
| 恢复 | 持久化爬取状态、未完成工作、失败重排 | frontier/seen 与目录页原子提交；持久协议游标续扫，会话游标失效则重建未发布 run |
| 变化与改名 | 修改时间与阶段状态差分；存在 moveData 能力 | persistent ID 保留身份；size/mtime/etag/路径等更新 material revision，旧租约失效；无稳定 ID 的移动仍有限制 |
| 剧集识别 | 文件名、父目录、季目录、多标题 variant；未发现兄弟文件投票证据 | 原先 SxxEyy/2x03 没有父目录回退；本次补全该缺口，仍为单一规范结果，不宣称完整 parser parity |
| 人工数据 | 文件索引、元数据缓存与观看数据生命周期分离 | 自动匹配尊重锁定；missing、可恢复墓碑、两阶段元数据回收分开 |
| 来源离线 | 网络失败记录来源状态，不视为文件删除 | 已有 source-level overlay；本次修复 repair 错误更新在线状态和扫描时间 |
| 异常空库 | 研究强调不完整快照不能协调删除 | SDK 另有异常空结果/数量骤降复核；本次确保中间 repair 不会清掉复核证据 |
| 重资源工作 | 图片与技术详情可关闭预取或按需获取 | probe、artwork、thumbnail 为可选独立任务，不应阻塞文件索引提交 |
| 来源类型 | Plex/Emby/Jellyfin 专用同步与 Direct/Library 模式 | 当前普通文件连接器不能等价替代服务器同步；不套用全库文件差分实现 Direct Mode |

主要源码：

- [扫描器](../../../../platforms/swift/Sources/StellarMediaLibrary/MediaScanner.swift)
- [SQLite scan sink](../../../../platforms/swift/Sources/StellarMediaLibrary/SQLiteMediaScanSink.swift)
- [文件索引与任务](../../../../platforms/swift/Sources/StellarStorage/LibraryStore.swift)
- [缺失与回收](../../../../platforms/swift/Sources/StellarStorage/LibraryMissingLifecycle.swift)
- [文件名解析](../../../../platforms/swift/Sources/StellarMediaLibrary/MediaFilenameParser.swift)
- [调度器](../../../../platforms/swift/Sources/StellarMediaLibrary/MediaScanScheduler.swift)

## 本次落地的改进

1. **可用的恢复路径。** 根/能力不兼容的 failed checkpoint 以及仍持有已失效会话游标的
   未完成 checkpoint，在恢复加载时使用已有 CAS 清理接口移除该 run 的临时状态并返回 nil，
   让宿主建立新 run。网络中断/取消仅在游标仍可跨连接使用时续扫；已发布文件不变。
   旧版 local/webdav/smb offset+fingerprint 游标同样失效，不再重读整个目录来校验 hash。
   不在当前调用内无限重启扫描，避免高频变动目录引发重试风暴。
2. **repair 不冒充来源检查。** repair 请求不能携带发现范围，持久批次不能写文件事实或授权
   missing；成功/失败不改来源 offline、last error 和扫描日期。repair 不删除异常快照，
   后一次发现扫描复核时跳过中间的 repair，继续比较两次发现的身份集合。
3. **提交前响应取消。** finalizing 入口和 completion 提交前都检查取消，覆盖普通扫描、
   finalizing 恢复与不连接来源的 repair。已经提交的原子事务仍然有效，稍后到达的取消不回滚它。
4. **剧集父路径补全。** parser v3 支持 `Wednesday (2022)/Season 2/S02E03.mkv`、
   `Season 2/03 Episode.mkv`、`02-003 Episode.mkv` 和 `Specials/01 Episode.mkv`。
   文件名中的标题/季集优先；父目录年份只给缺失标题或同名剧使用；不会借用进程工作目录、
   通用库根或兄弟文件。更新共享 fixture 和实际扫描流程规范。

5. **去掉整目录排序/指纹，按协议选择批处理方式。** 基线的 Local、AMSMB2 和 WebDAV 都先读完整目录，
   共用 paginator 再排序、FNV hash、切片；原先仅检查 scanner 的并发上限不足以证明内存有界。
   WebDAV 原生 PROPFIND 不分页，单目录内存分批本身不是错误，需和 Local/SMB 的原生迭代区分。本次 Local 改为 `readdir`；SMB 直接使用随 AMSMB2 固定依赖提供的
   libsmb2 原生 CREATE/QUERY_DIRECTORY/CLOSE，每个响应最多 64 KiB，不调用会自行汇总全部
   查询页的 `opendir`；WebDAV 按用户确认改用单目录内存 XML/条目列表，不写临时文件，
   最多保留前 655,360 个直接子项（文件和目录合计，目录自身不计）。确认额外子项后停止解析，
   超出部分不索引、不遍历，截断页/持久化 checkpoint 禁止本轮 missing，但允许发布已发现文件。
   都保留来源顺序，用会话期随机游标接续，不计算整目录指纹。单文件 size/mtime/etag 继续用于
   变化判断，展示排序仍属于 PosterWall 查询。
6. **数据库承担历史集合。** SQLite scanner 按窗口领取 pending frontier，只查询当前页相关的
   seen identity 和页游标；恢复校验流式读 frontier，不构造完整数组。目录继续页优先，避免
   广度遍历积累打开的句柄。新增可选 `MediaScanEnumerationIndex`，Demo sink 装饰器也转发
   `enumerationIndex`；否则包装层会失去内存边界。单页原子提交确保下一页查询看到最新去重结果。
7. **独立结构探测。** 同目录的 scanner 和光盘结构 probe 各自拥有游标，不互相覆盖句柄或
   内存列表/临时队列；SMB 连接池按目录+cursor 保持归属。结构探测完整遍历但只保留控制文件/BDMV 哨兵，
   缓存最多 32 个小型结构投影。WebDAV 未超过条目上限时的截断 XML、单条 response 失败
   都不能伪装成完整目录；可选属性失败仍允许使用该条目的其他成功属性，限额内的末尾
   `.nomedia` 会抑制整个目录，超限标记按用户要求忽略。

数据库 schema 和已有公开方法签名未变；新增带默认 nil 实现的可选索引入口，旧 sink 可继续
工作。API 基线增加可选索引、分页截断标记/构造方法和 checkpoint 截断状态声明。parser version 从 2 升为 3；已完成的历史匹配不会因此全部
自动重刮，失败项目可走现有 repair/retry 流程，避免覆盖用户确认结果。

## 验证与边界

- WebDAV 内存/上限调整后，完整 Swift 测试 203 项、32 个 suite 通过。
- SQLite 测试含 20,000 条 seen、2,001 个 pending 的有界窗口；宽目录树跨页重复条目只计一次，
  sink 包装层不能偷偷调用全量恢复接口，同时活跃扫描目录不超过 4 个。
- WebDAV 内存路径测试含 2,001 条逆序条目、独立同目录游标、末尾 `.nomedia`、截断 XML、
  单条失败，以及实际 655,361 条响应的 655,360 项截断。补充等于/超过上限、忽略尾部、断点恢复
  保留截断状态、SQLite 连续不完整扫描不误标 missing。真实本地目录测试覆盖 BDMV probe 与 scanner 交错读取。
- [`run_smb_paging_fixture.py`](../../../../tools/ci/run_smb_paging_fixture.py) 在 loopback 临时
  Impacket 0.13.1 服务上运行 1,201 条目的真实 SMB 协议测试，包括独立目录句柄、双连接池、
  中文名、stat、range read、取消和过期游标，并验证每个 QUERY_DIRECTORY 的上限为 65,536 字节。
- SQLite schema、生成 SQL 一致性、依赖锁定和本次修改的 Swift 格式检查通过。
- 原生构建生成的目标模块 symbol graph 与 `PublicAPI.json`、`StellarMediaImagingAPI.json`
  与审阅后的增量基线一致。完整 symbol graph 导出仍因 BDMVIOContext/StellarDiscMedia 的 FFmpeg 头文件解析
  报错；上述结论是对成功导出的基线模块使用仓库既有比对函数得到的结果，不代表整条 CI
  API 检查命令通过。
- 本机为 Apple Swift 6.4；默认构建在第三方 KSPlayer 的 Metal 编译步骤失败，测试使用
  `swift test --build-system native` 完成。SMB target 的 arm64 iOS 模拟器编译也通过，但第三方
  AMSMB2 链接仍有 sysroot warning；不代表 iOS/tvOS 真机、真实 NAS 或当前 CI Swift 6.3 已验收。
- 全仓格式检查仍报告未修改文件的既有问题，本次未扩大为全仓格式重写。
- WebDAV 基础 PROPFIND 没有通用网络分页，首个逻辑页仍等待完整响应；按用户要求接受
  单目录 XML 与最多 655,360 条对象驻留内存，最多 4 个并发目录请求，不宣称限制响应字节数
  或减少服务器响应大小。自定义旧 SMB 数组 transport、
  未转发可选索引的自定义 sink，以及显式调用数组返回 API 的上层消费者，仍受其原合同约束。
- 静态证据支持 Infuse 的临时 FileIndex、批处理和范围集合差，但不能据此断言它的所有协议
  实现都流式、完全不排序或不计算任何 hash。本次没有做同 NAS、同库的端到端性能对比。
- 尚未实现完整 Infuse 多标题 variant/语言分支、服务器 delta 同步和宿主后台调度。
  `MediaScanScheduler` 的触发合并保存在内存，scanner 与文件 worker 的进度则持久化；
  不应把前者当成系统后台守护进程。

## 研究依据

本次直接读取 `/Users/zzzhr/vscode/debug-infuse/` 下的建库重建、iOS 静态分析、matcher parity
和 thumbnail 分析文档。仓库内相关归档：

- [建库、扫描、重建与自有扫描器设计](infuse_library_scan_rebuild_and_our_scanner_design.md)，
  特别是 §2 证据边界、§4 阶段与父目录解析、§5 快照差分、§7 恢复、§8 来源差异、§17 并发。
- [iOS 8.5.1 静态分析](infuse_ios_8.5.1_static_analysis.md)，§8 扫描与两阶段删除。
- [matcher 一致性审计](infuse_tmdb_matcher_parity_audit.md)，区分二进制证据与 clean-room 策略。

最近三层父目录、通用目录名过滤和精确回退条件是本 SDK 的兼容策略，不能反向当作
Infuse 私有权重或所有设备上的实际调用顺序。

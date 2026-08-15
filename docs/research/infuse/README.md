# Infuse 研究与讨论总结

本目录归档了项目初始化前针对 Infuse 8.5.1 的 clean-room 调查结果。资料用于理解成熟媒体库的行为边界，不代表 Infuse 源代码，也不能作为复制第三方私有实现的依据。

## 讨论结论

1. InfusePlus 是面向 Infuse 安装包的增强/注入项目，不是 Infuse 的开源源代码。
2. 普通文件来源的媒体索引和海报墙主要在设备本地物化；iCloud 可同步 share、Favorite、人工匹配、片单、观看状态等用户数据，但不是让多设备直接打开同一活动数据库。
3. 普通电影/剧集的主要在线匹配来源是 TMDB；Plex、Emby、Jellyfin 来源使用服务器自己的项目和元数据路径。
4. TMDB 请求可默认直连，并具备 Infuse 代理回退；静态分析没有发现对普通 `/3/search/*` 再加自定义 HMAC 签名。
5. 文件名解析采用结构标记、技术 token 清理、父目录候选和多个解析变体，而不是只做一次宽松正则。
6. 未发现把文件 hash 上传到外部影视库并按 hash 识别标题的主流程；hash 更适合本地移动和重复识别。
7. 8.5.1 中存在 TheIntroDB 与 IntroDB.app 的片头片尾 provider 痕迹，没有发现明显的 PublicMetaDB provider。
8. 文件删除主要由成功扫描快照与旧 FileIndex 的集合差发现；扫描失败、来源离线或范围不完整不能成为批量删除依据。
9. 文件索引、在线元数据缓存和观看状态是不同生命周期；元数据存在 7 天延迟两阶段回收证据。
10. 项目最终采用 27 张核心 SQLite 表 + 3 张缓存表，并在此基础上设计可恢复、按范围、带删除保护的 scanner。

## 归档文件

- [`cross_platform_media_library_design.md`](cross_platform_media_library_design.md)：27 表数据模型、关联、删除策略与跨平台实现。
- [`infuse_ios_8.5.1_static_analysis.md`](infuse_ios_8.5.1_static_analysis.md)：iOS 8.5.1 解析、刮削、请求链和索引静态分析。
- [`infuse_library_scan_rebuild_and_our_scanner_design.md`](infuse_library_scan_rebuild_and_our_scanner_design.md)：建库、扫描触发、重建和自有 scanner 设计。
- [`infuse_tmdb_matcher_parity_audit.md`](infuse_tmdb_matcher_parity_audit.md)：Python 参考实现与 Infuse 行为的一致性边界。
- [`../../../tools/reference/infuse_tmdb_matcher.py`](../../../tools/reference/infuse_tmdb_matcher.py)：文件名解析、TMDB、图片和 marker 的研究脚本。

## 生产使用边界

- 研究脚本不是 SDK 依赖，也不应被应用直接调用；
- 脚本复制到本仓库时已经移除硬编码 TMDB key，使用 `TMDB_API_KEY` 或 `--api-key`；
- provider URL、字段和限流规则需要在生产实现前按官方文档重新确认；
- 静态分析不能替代目标设备上的合法运行时测试；
- 生产代码必须由本仓库规范和测试驱动重新实现。


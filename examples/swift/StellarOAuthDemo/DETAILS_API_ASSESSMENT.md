# 海报墙详情接口评估

日期：2026-09-09。评估先于本次详情实现；结论依据当前源码、OpenAPI 和开发接口抽样，不能把源码支持等同于部署验收。

## 结论

现有接口合同足够实现电影详情 → 演职员 → 人物 → 作品，以及剧集 → 季 → 单集的浏览链路。完整还原 Infuse 仍有服务端和播放器能力缺口。优先接通已有数据，并独立处理各区域的加载、空数据和重试。

Demo 使用 `https://dev-api-st.2dland.cn/v1/media-info/`。指定的 `stellarplayer-gateway` 源码负责账户/OAuth/user API，没有影视资料路由；影视接口实际实现位于相邻的 `stellarplayer-media-service/internal/httpapi/handler.go`，运行合同为该仓库 `docs/api/openapi.json`。本次不改远端配置、数据库或服务代码。

## 能力对照

| Infuse 详情能力 | 现有数据与接口 | 评估 / 客户端处理 |
| --- | --- | --- |
| 电影/剧集标题、原名、简介、日期、时长、类型、状态 | `GET entities/{id}`，movie/series typed document | 满足；未知值为 null，不编造标签 |
| 背景大图、海报、剧照、头像 | `GET entities/{id}/artworks?kind=…` → `artworks/{id}/variants` | 满足；按屏幕区域懒加载，不预取全剧图片 |
| 演员、角色、工作人员、职务 | `GET entities/{id}/credits` | 满足；movie/series/season/episode 均支持，series/season 为 aggregate；完整已接受数组、每类最多 512、超过上限整份失败 |
| 人物简介、生日/逝世日期、出生地、职业 | `GET entities/{person_id}` | 满足；人员与影视共用实体入口 |
| 人物作品 | `GET persons/{id}/filmography` | 部分满足；最多 40 项、没有分页，必须呈现 truncated/source_count，不能声称完整片单 |
| 季、单集目录 | `GET series/{id}/episode-orders` → `…/{order_id}/entries` → season/episode entity | 可实现；没有批量季/集详情接口。目录按 cursor 完整取回，详情只加载已选季和可见集，避免数百次启动请求 |
| 特别篇、替代排序 | aired/absolute/dvd/digital/story_arc/production/tv orders，允许第 0 季/集 | 可实现；以 episode_id 对齐原播映射，再关联本地 S/E。不能把替代排序 S/E 直接套在本地 aired 坐标上 |
| 本地文件、多版本、音轨/字幕、光盘节目 | SDK `PosterWallStore.details` + `DiscMediaLibrary` | 已有本地能力；当前 Demo 丢弃了大部分投影，需在详情页展示 |
| 评分、认证分级、标语、制作公司、国家 | 远端 closed schema 未提供；本地详情可有 contentRating/tagline | 远端不足；显示确有的本地字段，其他待扩展合同 |
| 预告片、花絮视频 | 无 videos/trailers/extras API | 远端不足；本地 extra 文件可展示 |
| 自动电影合集、相似推荐 | 无 collections/recommendations API | 远端不足 |
| 收藏、已观看、续播、Up Next、跨设备同步 | 匿名媒体接口明确不存用户状态；本地有部分模型，Demo 尚无完整播放状态写入与播放流程 | 独立的本地/账户及播放器工作，不把公开元数据写成用户媒体库 |
| 手动搜索/改匹配 | resolve 是文件路径解析，没有用户搜索分页接口 | 后续需要搜索与用户选择落库流程 |

## 开发接口抽样

匿名请求仅使用公开片名 `Inception.2010.mkv`、`Breaking.Bad.S01E01.mkv`，未读取账户令牌、SMB 密码或真实用户媒体文件。

- 两次 resolve：HTTP 200，均约 2.08 秒，返回服务自有 UUID。
- 电影、剧集、单集实体：HTTP 200，约 0.18–0.27 秒。
- 电影 backdrop 列表：HTTP 200，带 next_cursor。
- 初次电影 credits 和剧集 episode-orders：连续三次返回 HTTP 503；现有合同描述冷 public-ready cache 可能返回 503 并后台填充，但本次抽样尚不能证明仅是冷缓存。
- 后续重复检查 credits / episode-orders 仍为 503；用 resolve 已返回的 aired order ID 直接调用 entries 则 HTTP 200，共 71 条，且季/集详情成功。源码 `publicstore.Store.EpisodeOrders` 在任一 alternate group 尚未完成时会让整个列表返回不可用，因此客户端增加缓存中已验证 aired order ID 的回退，不猜测 ID。
- artwork summary/document 没有图片语言、投票或首选标记，无法在图片选择器中按语言与质量筛选；详情页保留本地已选图片优先级。
- 人物和作品真实请求依赖可取得的 person_id；在 credits 未成功前不能声称人物链路已通过远端验收。

因此首屏必须先显示 SQLite 资料，远端正文、图片、人员、季集目录独立加载，失败显示区域内重试；目录暂不可用时仍可浏览已入库季/集与文件。客户端沿用持久缓存、ETag、请求合并、限速和有界重试。

## 参考

- [Infuse 官方功能](https://firecore.com/infuse)：metadata、artwork、cast、ratings、trailers。
- [Infuse 更新记录](https://firecore.com/releases)：详情页人员搜索、季/集选择、多版本行为。
- [Infuse Collections](https://support.firecore.com/hc/en-us/articles/13692816354839-Collections)：自动及自定义合集。

## 本次实施与验证

- 已实现背景图/海报详情、正文展开、日期/时长/类型/状态、文件版本与技术流、光盘标题、季/集目录、特别篇、替代排序菜单、完整演职员筛选、人物简介和作品跳转。
- 作品跳转通过 SDK 的 provider identity 索引查询关联本地媒体，避免为查一个作品扫描全库；目录页验证 metadata_version、cursor 环和总量上限，替代排序通过 aired episode ID 关联文件。
- 各区域独立加载与重试；HTTP 最大四路并发，沿用 10 QPS、持久响应缓存、ETag、404 缓存和有限重试。共享请求不会被一个离开的订阅者取消。resolve 请求体固定排序，并兼容旧缓存的字段顺序。
- iOS 模拟器实测发现并修复 SDK 在缺少 WAL/SHM sidecar 时重开 SQLite 失败：仅 `open` 预检允许连接恢复辅助文件，检查 SQL 强制 `query_only`；`verifyExisting` 继续使用只读连接。未变更 schema。
- UI 验收使用新建的独立 iOS 26.5 模拟器；本地文件与人员为明确标注的测试夹具，电影/剧集/单集正文及图片使用开发接口。已检查电影 → 人物 → 作品 → 本地文件、原播目录回退、全部集数、特别篇菜单、第二季和单集详情。人员夹具的成功不代表远端人员接口已通过。
- 播放、收藏/已看状态写入、评分、预告片和合集仍属于上文所列后续工作；本次没有伪造播放按钮、评分或云同步。

最终检查：iOS 26.5 Simulator Debug 构建通过；Demo 元数据测试 10 项通过；SDK PosterWall/StorageMigration 定向回归 14 项通过；Swift public API 基线检查和 `git diff --check` 通过。未做真机播放或远端人员链路成功验收。

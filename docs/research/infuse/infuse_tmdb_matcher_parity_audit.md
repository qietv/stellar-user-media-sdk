# `infuse_tmdb_matcher.py` 与 Infuse 8.5.1 一致性审查

> 归档说明：本仓库副本已移除脚本中的默认 TMDB API key，运行时需通过 `TMDB_API_KEY` 或 `--api-key` 提供。

版本：2.0  
审查对象：`infuse_tmdb_matcher.py`  
对照对象：Infuse iOS 8.5.1（build 5726，用户提供的 IPA）  
结论日期：2026-08-14

## 1. 结论

旧版脚本与 Infuse **不是完全一致**。它混合了从 Infuse 8.5.1 中能确认的规则和自行扩展的兼容规则，包括中文“第 N 季第 M 集”、更宽的年份范围、通用目录过滤、OpenCC 标题扩展及自定义评分权重。这些功能可能提高某些媒体库的命中率，但不能标作 Infuse 原始行为。

本次修订把两者拆开：

- 默认 `--parser-mode infuse`：使用在 8.5.1 二进制中可验证的剧集格式、本地化 season/episode 词、技术标签截断、显式 ID、年份、edition 和父目录候选路径；
- `--parser-mode extended`：保留旧版脚本的中文格式、宽松格式、OpenCC 变体和额外发布标签；
- TMDB 结果评分仍是 clean-room 启发式算法，不声称等于 Infuse 的私有评分；
- 详情、图片和片段查询是独立的数据获取功能，不改变解析结果。

因此，准确表述是：**默认模式已尽量做到 Infuse 8.5.1 的规则级兼容，但整个程序仍不能宣称逐分支、逐字节完全一致。**

## 2. 已对齐的解析规则

### 2.1 剧集格式

默认模式包含从 `FCSeriesTitleParser` / `TitleParsingRegExp` 可确认的主要路径：

| 类型 | 示例 | 结果 |
|---|---|---|
| 带标题的 season/episode | `Wednesday.S02E03.mkv` | `Wednesday`, S02E03 |
| `SE/EP` 变体 | `Show.SE2EP3.mkv` | `Show`, S02E03 |
| `1x02` | `Show.2x03.mkv` | `Show`, S02E03 |
| iTunes 季集格式 | `02-003 Episode.mkv` | S02E03，标题从父目录补充 |
| iTunes 纯集数格式 | `03 Episode.mkv` + `Season 2` 父目录 | S02E03，标题从更上级目录补充 |
| 特别篇目录 | `Specials` | season 0 |

解析器会保留文件名和父目录产生的多个候选，而不是只生成一个标题。父目录路径对应二进制中的 `sortedItemsForParsingByParentsFromItem:episodeInfo:` 和 `FirstParent_*` 解析分支。

`reSeason`、`reEpisode` 是本地化资源而非固定英文。8.5.1 样本中例如：

| `--parser-language` | season | episode |
|---|---|---|
| `en` | `season` | `episode` |
| `zh-Hans` | `季` | `剧集` |
| `zh-Hant` / `zh-HK` | `季` | `集` |
| `fr` | `saison` | `épisode` |
| `de` | `staffel` | `episode` |
| `ja` | `シーズン` | `エピソード` |

脚本内置了 IPA 中全部 43 个 locale 的本地化词（相同词值会共享映射）。解析语言和 TMDB 元数据语言是两个概念；默认解析语言为英文，可用 `--parser-language zh-Hans` 等参数设置成 Infuse 的界面语言。`第2季第03集` 这种额外中文语序仍属于 `extended` 模式，而 `剧名.季2.剧集3` 是可验证的本地化模板。

### 2.2 电影与通用标题

默认模式对齐了以下可观察形式：

- `{tmdb-27205}`、`{imdb-tt1375666}`；
- 分隔符后四位年份；
- `{edition-...}` 及 Special/Ultimate/Director/Extended/Theatrical/Unrated/IMAX 等 edition；
- 480/720/1080/2160、UHD/FHD、Blu-ray/DVD、x264/x265/HEVC、HDR、DTS/AAC、remastered、proper、3D 等技术 token；
- `Title, The` 的标题形式；
- 文件名候选与第一父目录候选。

### 2.3 示例验证

输入：

```text
Wednesday.S02E03.2022.2160p.NF.WEB-DL.DDP5.1.Atmos.H.265-ColorTV.mkv
```

默认解析结果：

```json
{
  "kind": "tv",
  "title": "Wednesday",
  "season": 2,
  "episode": 3,
  "source": "filename:TitleParser_Title"
}
```

在线验证结果为 TMDB series ID `119051`，S02E03 的 TMDB episode ID 为 `6165594`。文件名中的 `2022` 位于已命中的剧集结构之后，不会作为这个文件名候选的首播年份；父目录若为 `Wednesday (2022)`，可再产生带年份候选。

## 3. 仍不能证明完全一致的部分

| 项目 | 当前脚本 | 一致性判断 |
|---|---|---|
| 正则字面量和主要分支 | 默认模式按静态样本重建 | 高度接近，但 Python 与 Apple 正则实现仍可能有边界差异 |
| season/episode 本地化 | 内置 8.5.1 bundle 的 43 个 locale 值 | 字面值一致；须把 `--parser-language` 设为 Infuse 界面语言 |
| 父目录候选 | 最近三层、season 目录跳过、保留多候选 | 架构一致；Infuse 的完整排序权重未知 |
| TMDB 搜索参数 | `query`、`language`、电影年份/剧集年份 | 与二进制可见字段一致 |
| 搜索结果选择 | 标题相似度、年份、热度、票数、单集存在性 | **自研评分，不是 Infuse 原始权重** |
| 本地元数据合并 | 脚本未读取 NFO、容器标签、用户 override | 不一致；Infuse 有完整 provider chain |
| Plex/Emby/Jellyfin 分流 | 未实现 | 不一致；Infuse 使用服务器专用元数据路径 |
| 缓存和失败恢复 | 单次命令执行 | 不一致；Infuse 有数据库缓存、限流和重试状态 |
| TMDB 代理回退 | 只直连 TMDB | 不一致；Infuse 还内置 `movie-api.infuse.im` 等网络回退 |
| 远程配置/A-B 行为 | 无 | 静态分析无法验证 |

`--parser-mode extended` 明确不是 Infuse 原样行为；它是面向开源播放器的增强兼容层。

## 4. 新增 TMDB 功能

### 4.1 图片服务器与尺寸

脚本调用：

```text
GET https://api.themoviedb.org/3/configuration
```

并读取：

```text
images.base_url
images.secure_base_url
images.backdrop_sizes
images.logo_sizes
images.poster_sizes
images.profile_sizes
images.still_sizes
```

图片 URL 不再硬编码。下载前会检查所选尺寸是否位于对应类型的服务端配置列表中。`original` 也是配置返回的合法尺寸，而不是脚本自行假设。

用法：

```bash
python3 infuse_tmdb_matcher.py --image-config --json
```

### 4.2 电影、剧集、季和单集详情

```bash
# 电影详情
python3 infuse_tmdb_matcher.py --movie-details 27205 --json

# 电视剧详情
python3 infuse_tmdb_matcher.py --tv-details 119051 --json

# 第二季详情及该季全部 episodes
python3 infuse_tmdb_matcher.py --season-details 119051 2 --json

# 单集详情
python3 infuse_tmdb_matcher.py --episode-details 119051 2 3 --json
```

电影详情采用 Infuse 二进制可见的扩展字段：

```text
casts,releases,images,alternative_titles,translations
```

电视剧详情采用：

```text
credits,content_ratings,external_ids,images,translations,alternative_titles
```

季详情响应中的 `episodes` 数组就是该季全部单集记录。

### 4.3 下载原始海报和背景图

```bash
python3 infuse_tmdb_matcher.py \
  --movie-details 27205 \
  --download-artwork ./artwork \
  --image-size original \
  --json
```

电视剧同样支持。单集详情若有 `still_path`，会下载原始剧照。下载先写入同目录临时文件，成功后再原子替换目标文件，避免中断时留下半张图片。

也可以在文件名匹配完成后直接下载：

```bash
python3 infuse_tmdb_matcher.py \
  --filename "Inception.2010.2160p.mkv" \
  --download-artwork ./artwork \
  --json
```

## 5. 片头、回顾、片尾与预告片段

### 5.1 主源：TheIntroDB

当前公开接口：

```text
GET https://api.theintrodb.org/v3/media
```

支持 `tmdb_id` 或 `imdb_id`，电视剧还传 `season`、`episode`。`duration_ms` 可用于匹配不同发行剪辑版本。返回的 `intro`、`recap`、`credits`、`preview` 被统一为：

```json
{
  "type": "intro | recap | outro | preview",
  "start_ms": 169000,
  "end_ms": 234000,
  "provider": "theintrodb.org"
}
```

API key 为可选 Bearer token，可通过 `--marker-api-key` 或 `THEINTRODB_API_KEY` 提供。

### 5.2 备用源：IntroDB.app

当前公开读取接口：

```text
GET https://api.introdb.app/segments
    ?imdb_id=tt...
    &season=1
    &episode=1
```

读取不需要 API key。它能返回 `intro`、`recap`、`outro`。自动模式不是简单地“主源有任意结果就停止”，而是按片段类型补缺：主源已有的类型优先，备用源只填缺少的类型。

### 5.3 用法

```bash
# 独立查询；auto = TheIntroDB -> IntroDB.app 补缺
python3 infuse_tmdb_matcher.py \
  --markers --type tv \
  --tmdb-id 119051 \
  --season 1 --episode 1 \
  --duration-ms 3560000 \
  --marker-provider auto \
  --json

# 从文件名匹配 TMDB ID 后自动查询片段
python3 infuse_tmdb_matcher.py \
  --filename "Wednesday.S02E03.mkv" \
  --markers --json
```

### 5.4 与 Infuse 的关系及 PublicMetaDB

Infuse 8.5.1 二进制可以确认以下类型和标识：

```text
OnlineVideoMarkersProvider.TheIntroDbOrgAPI
OnlineVideoMarkersProvider.IntroDbAppAPI
EpisodeMarkers_TIDBORG
EpisodeMarkers_IDBAPP
api.theintrodb.org
```

没有发现 `publicmetadb` 字符串、域名或 provider 类型；公开检索也没有找到足以实现且可核验的 PublicMetaDB 片段 API。因此本脚本没有虚构第三套协议。当前“备用片段数据库”指 Infuse 样本中同样存在的 IntroDB.app。

片段功能采用两家服务当前公开协议。静态样本能证明 Infuse 含有这两类 provider，但不能只凭字符串证明 8.5.1 的每个 URL path、请求头和当前公开版本逐字节相同。

## 6. 实际测试

本次完成以下联网验证：

| 测试 | 结果 |
|---|---|
| TMDB `/configuration` | 成功，返回图片主机和五类尺寸列表 |
| 电影 `27205` 详情 | 成功，返回电影及追加字段 |
| 剧集 `119051` 详情 | 成功，返回 seasons、external IDs 和追加字段 |
| `119051` 第 1 季 | 成功，返回 8 个 episode 记录 |
| `Wednesday.S02E03...mkv` | 命中 series `119051`、episode `6165594` |
| TheIntroDB `119051` S01E01 | 成功，返回 intro、preview、outro |
| 原始海报下载 | 成功，约 1.0 MB |
| 原始背景图下载 | 成功，约 1.36 MB |

## 7. 参考接口

- TMDB configuration：<https://developer.themoviedb.org/reference/configuration-details>
- TMDB movie details：<https://developer.themoviedb.org/reference/movie-details>
- TMDB TV series details：<https://developer.themoviedb.org/reference/tv-series-details>
- TMDB TV season details：<https://developer.themoviedb.org/reference/tv-season-details>
- TMDB append to response：<https://developer.themoviedb.org/docs/append-to-response>
- TheIntroDB 官方 Jellyfin 插件：<https://github.com/TheIntroDB/jellyfin-plugin>
- IntroDB.app API 文档：<https://introdb.app/docs/api>

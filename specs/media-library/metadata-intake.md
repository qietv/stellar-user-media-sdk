# 本地元数据与技术探测合同 v1

本合同固定文件名解析之后、在线 provider 匹配之前的本地摄取边界。三端可以使用不同的 XML、容器和字幕实现，但必须对公共 fixture 产生相同的规范结果。

## Sidecar 关联

sidecar 只按同目录媒体文件关联，不递归继承。候选路径必须是规范化的来源相对路径，包含 NUL、`.` 或 `..` 路径段的输入必须拒绝。

支持的 v1 分类为：

| 类型 | 文件形式 |
| --- | --- |
| `nfo` | 与媒体同名的 `.nfo`，以及 `movie.nfo`、`tvshow.nfo`、`season.nfo` |
| `metadata_json` | 与媒体同名的 `.json`，以及 `movie.json`、`tvshow.json`、`season.json` |
| `subtitle` | 与媒体同名且扩展名为 `.srt`、`.ass`、`.ssa` 或 `.vtt` |
| `poster` | `poster.*`、`folder.*` 或 `<media>-poster.*` 图片 |
| `backdrop` | `fanart.*`、`backdrop.*` 或 `<media>-fanart/backdrop.*` 图片 |
| `logo` | `logo.*`、`clearlogo.*` 或 `<media>-logo/clearlogo.*` 图片 |
| `chapters` | `chapters.xml/txt` 或 `<media>.chapters.xml/txt` |

字幕名称中的 BCP 47 风格语言标签规范为连字符形式；缺失时为 `und`。`forced`/`foreign` 标记映射为 `forced=true`，`sdh`/`hi`/`cc` 映射为 `hearing_impaired=true`。不满足同目录与同名规则的字幕不得错误关联到相邻媒体。

## NFO 安全与映射

v1 读取 Kodi 风格的 `movie`、`tvshow`、`season` 和 `episodedetails` 根元素。实现 MUST：

- 将单份 NFO 输入限制为最多 2 MiB；
- 禁止 DTD 和 XML entity 声明，不解析外部实体；
- 只读取根元素的直接标量子元素，避免把演员等嵌套节点的标题误当成媒体标题；
- 支持标题、原始标题、排序标题、年份、简介、tagline、分级、发行日期、runtime、剧名与季集号；
- 把 runtime 的分钟值转换为整数毫秒；
- 读取 `uniqueid`、`tmdbid`、`imdbid` 和 `tvdbid`，但只把 NFO 明确标记为默认的 ID 设为 primary；
- 读取 poster/backdrop/logo 等图片位置，但不在解析阶段发起网络请求或打开本地文件。

NFO 是候选证据，不得覆盖用户锁定字段。未知根元素、畸形 XML、DOCTYPE、超限输入或没有可用字段的文档返回 `parse_failure`。

## 技术探测边界

技术探测器通过协议注入，并接收来源无关的 locator 与 `MediaSourceSession` range reader。探测在数据库事务外运行；成功结果包含：

- probe provider 与整数版本；
- 容器、时长、总码率、主视频/音频参数和内嵌封面标记；
- 按稳定 `stream_index` 排列的 video、audio、subtitle 或 attachment 轨道。

数值时长统一使用毫秒，码率使用 bit/s。负数、重复 stream index 和无效尺寸必须拒绝。一次成功结果在短事务中整体替换 `technical_summary` 与 `media_stream`，失败时保留上一份成功结果。

## 公共 fixture

[`metadata-intake-v1.json`](../fixtures/media-library/metadata-intake-v1.json) 固定 sidecar 分类、NFO 规范结果和技术探测结果。未知枚举必须安全降级为 `unknown`；未知字段必须忽略，以便 v1 reader 前向兼容。

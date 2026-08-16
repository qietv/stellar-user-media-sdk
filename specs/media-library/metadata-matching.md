# 元数据候选与匹配合同 v1

本合同固定本地解析证据到在线 provider 结果之间的纯业务边界。provider transport、鉴权、限流和响应解码由各平台 adapter 实现；候选生成、评分与决策必须能使用合成响应离线重放。

## 查询证据优先级

`MediaMatchQuery` 只包含匹配所需的最小信息：媒体类型、标题、年份、季集号和外部 ID。查询生成遵循：

1. NFO/local metadata 中的明确媒体类型、剧名、标题、年份、季集号和外部 ID；
2. 文件名 parser 的类型、标题、年份、季集号；
3. 无法得到 movie 或 episode 类型，或者既没有标题也没有外部 ID 时，返回 `parse_failure`，不调用 provider。

episode 查询优先使用 NFO 的 `series_title` 作为搜索标题。NFO 的单集标题不应误作剧名。

## Provider 注入

provider 通过 `MediaMetadataProviding` 协议注入。一次搜索接收规范化 query，返回零个或多个 `MediaMetadataCandidate`；SDK 核心不得持有 TMDB key，也不得在单元测试中要求真实网络。

provider 失败、限流或返回空结果时只影响本次匹配任务，不得删除 `media_file`、旧的成功元数据或人工锁定绑定。

## v1 确定性评分

类型不兼容的候选直接 `rejected`。movie 只接受 movie；episode 接受 series 或 episode。

评分信号：

| 信号 | 分值/行为 |
| --- | ---: |
| provider + namespace + value 外部 ID 精确一致 | 直接 `1.0` |
| 规范化主标题精确一致 | `+0.70` |
| 原始标题或 alias 精确一致 | `+0.62` |
| 年份一致 | `+0.18` |
| 年份相差 1 | `+0.09` |
| 年份相差大于 1 | `-0.15` |
| episode 候选明确包含指定季集 | `+0.20` |
| provider 已返回 episode 清单但不含指定季集 | 直接 `rejected` |

标题规范化执行 Unicode 宽度/变音符号折叠、大小写折叠，把非字母数字序列压缩为单个空格并去除首尾空格。分值限制在 `0...1` 并四舍五入到 6 位小数。

决策区间：

- `score >= 0.88`：`automatic`；
- `0.72 <= score < 0.88`：`review`；
- `score < 0.72`：`unmatched`；
- 类型错误或已证实缺集：`rejected`。

排序依次使用 score 降序、provider popularity 降序、provider 名和 candidate ID 升序。popularity 只能打破同分，不进入 score。自动流程只能写入未锁定绑定；`file_binding.locked=1` 的人工结果不由 scorer 覆盖。

## 持久化决策

候选计算与持久化分为两个安全边界：

- `automatic` 且已具备物化所需身份时，在 `library.sqlite` 的短事务中解析或创建逻辑实体并写入 `file_binding`；
- `review` 把有用候选按确定性 rank 写入可删除的 `metadata_cache.sqlite.match_candidate_cache`，不提前创建绑定；
- `unmatched`、全部 `rejected`、provider 返回空结果或 provider 失败不得删除旧的成功实体或绑定；
- episode provider 结果只有单集身份、却没有可解析的 series 身份时进入 `details_required`，等待 provider details，而不是创建不稳定的剧集占位身份；
- 用户确认候选后写入 `match_method=manual`、`locked=1`，并清理该文件的候选缓存。后续自动搜索在发起 provider 请求前检查锁，事务内也必须再次检查，以关闭竞态窗口。

provider 身份由小写规范化的 `provider + namespace + value` 解析到 `external_id`。同一批证据把一个 identity 指向多个实体、或试图替换实体已有的同 provider/namespace 值时必须失败关闭。电影直接绑定 movie；剧集文件先解析或创建 series → season → episode 层级，再把文件绑定到 episode。

同一逻辑实体的第一个文件使用 `binding_role=primary`，后续文件使用 `binding_role=version`。不同版本共享 `entity_uid`，因此重新匹配或缺失一个版本不会复制海报墙条目，也不会删除其他版本的播放状态。

sample、花絮和 bonus 文件不进入 movie/episode provider 搜索。它们只能在父 movie/series 已稳定物化后，以 `binding_role=extra` 和独立 extra entity 绑定；自动继承不得覆盖任一 locked binding。相同 file + parent 重放必须复用 extra identity，改绑父实体时旧的未锁定 extra 标为 obsolete。人工 extra 使用 `match_method=manual` 且必须 locked。

`metadata_cache.sqlite` 是可重建缓存，不能成为人工状态的唯一来源。核心绑定、人工锁和实体身份只保存在 `library.sqlite`；缓存清空或 provider 失败不会改变它们。

## 公共 fixture

[`metadata-matching-v1.json`](../fixtures/media-library/metadata-matching-v1.json) 固定电影、alias、剧集存在性、缺集拒绝和外部 ID 直接命中的样本。

[`metadata-match-persistence-v1.json`](../fixtures/media-library/metadata-match-persistence-v1.json) 固定 review → 人工锁定 → 自动保护、同实体 primary/version 绑定，以及 series → season → episode 物化结果。

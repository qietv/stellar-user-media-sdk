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

## 公共 fixture

[`metadata-matching-v1.json`](../fixtures/media-library/metadata-matching-v1.json) 固定电影、alias、剧集存在性、缺集拒绝和外部 ID 直接命中的样本。

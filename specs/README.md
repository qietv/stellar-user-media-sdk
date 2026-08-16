# 跨平台公共契约

本目录定义 Swift、Android 与 OpenHarmony 三端必须保持一致的业务语义。平台实现可以使用各自最合适的语言和系统 API，但不应自行改变字段含义、状态转换、冲突规则或错误分类。

## 规范层级

- `MUST`：三端必须一致，否则会造成数据或协议不兼容。
- `SHOULD`：原则上保持一致，平台限制下可以偏离，但需记录原因。
- `MAY`：平台可自行决定。

## 通用约定

| 项目 | 约定 |
| --- | --- |
| 标识符 | 小写 UUID 字符串；服务端已有稳定 ID 时保留原值并注明命名空间 |
| 时间 | Unix epoch 毫秒，字段后缀 `_at_ms` |
| JSON 字段 | `snake_case` |
| 布尔值 | JSON `true` / `false`，不使用 `0` / `1` |
| 可空值 | 缺失表示“未提供”，`null` 表示“明确清空” |
| 枚举 | 未知值必须可保留或映射为 `unknown`，不得导致整条记录解码失败 |
| 版本 | 可持久化和可同步对象必须携带 `schema_version` |
| 分页 | 游标分页；请求 `cursor`、`limit`，响应 `items`、`next_cursor` |

## 统一错误模型

所有公开异步接口 MUST 返回平台惯用的错误形式，并能映射到以下类别：

| 代码 | 含义 | 默认处理 |
| --- | --- | --- |
| `cancelled` | 调用方主动取消 | 不重试 |
| `unauthorized` | 访问令牌无效且无法刷新 | 转入重新登录 |
| `forbidden` | 已登录但无权限 | 提示用户检查授权 |
| `network_unavailable` | 当前网络不可用 | 等待网络恢复 |
| `rate_limited` | 服务端限流 | 遵循 `retry_after_ms` |
| `remote_unavailable` | NAS、网盘或服务暂不可用 | 指数退避 |
| `credential_required` | 缺少或失效的媒体源凭据 | 请求用户重新连接 |
| `invalid_configuration` | 配置字段无效 | 停止任务并显示具体字段 |
| `storage_failure` | 本地数据库或安全存储失败 | 停止写入并保留诊断信息 |
| `parse_failure` | 文件名或远程数据无法解析 | 进入待人工匹配队列 |
| `metadata_not_found` | 元数据源无匹配结果 | 保留本地媒体记录 |
| `conflict` | 同步冲突无法自动合并 | 进入冲突队列 |
| `unknown` | 未分类错误 | 记录原始原因，有限重试 |

错误对象至少包含 `code`、面向开发者的 `message`、可选 `retry_after_ms`、`cause` 和追踪 ID。SDK 不应把密码、令牌、完整远程 URL 或包含凭据的响应写入日志。

## 规范索引

- [JSON Wire Format v1](core/wire-format.md)
- [OAuth 与会话](auth/oauth-session.md)
- [远程媒体配置同步](remote-media/source-config-sync.md)
- [Credential Vault 与凭据同步](security/credential-vault.md)
- [扫描、解析与海报墙](media-library/scanning-and-poster-wall.md)
- [本地元数据与技术探测 v1](media-library/metadata-intake.md)
- [元数据候选与匹配 v1](media-library/metadata-matching.md)
- [SQLite、本地状态与同步](storage/sqlite-and-sync.md)
- [SQLite v1 schema manifest](storage/schema-manifest-v1.json)

详细的数据表和扫描状态机见 [Infuse 调研及自有扫描器设计](../docs/research/infuse/infuse_library_scan_rebuild_and_our_scanner_design.md)。

## 公共测试向量

`fixtures/` 保存所有平台共同执行的输入与期望输出。当前包括 [`wire-format-v1.json`](fixtures/core/wire-format-v1.json)、[`filename-parser-v1.json`](fixtures/media-library/filename-parser-v1.json)、[`remote-enumeration-v1.json`](fixtures/media-library/remote-enumeration-v1.json)、[`scanner-state-v1.json`](fixtures/media-library/scanner-state-v1.json)、[`metadata-intake-v1.json`](fixtures/media-library/metadata-intake-v1.json)、[`metadata-matching-v1.json`](fixtures/media-library/metadata-matching-v1.json) 和 [`metadata-match-persistence-v1.json`](fixtures/media-library/metadata-match-persistence-v1.json)；fixture 变更即合同变更，必须由对应规范或 ADR 解释。

# JSON Wire Format v1

## 1. 范围

本规范固定 Apple Swift SDK 与 Stellar 服务之间的基础 JSON 语义。业务规范可以增加字段约束，但不得改变这里对时间、缺失值、`null`、枚举和分页的解释。

## 2. 时间

- 跨进程时间 MUST 使用带 `_at_ms` 或 `_ms` 后缀的有符号 64-bit Unix epoch 毫秒整数。
- wire format 不使用 ISO 8601 字符串、秒、小数秒或平台 `Date` 对象。
- 持续时长也使用整数毫秒，但字段名 MUST 表明它是 duration/delay/timeout，不能命名为 `_at_ms`。
- 单调时钟只用于进程内 timeout 和 backoff，不得序列化为 epoch 时间。

## 3. 缺失、`null` 与默认值

- 缺失字段表示发送方没有提供该字段；patch 中表示“不修改”。
- JSON `null` 表示发送方明确清空可空字段；不可空字段收到 `null` MUST 解码失败。
- 具体值表示设置或替换完整字段。
- 解码器不得把缺失字段擅自写成 `null`，也不得用语言默认值掩盖一个必填字段的缺失。
- Swift patch model MUST 使用 `FieldPresence<Value>` 和显式 `decodePresence` / `encodePresence`；普通只读响应中的 `Optional` 只有在业务不区分缺失与 `null` 时才可使用。

## 4. 枚举演进

枚举必须选择以下一种策略并在模型上保持稳定：

1. **封闭分类**：未知 wire value 映射到 `.unknown`；重新编码为字面量 `unknown`，不保证保留原始文本。错误分类和媒体大类采用此策略。
2. **开放标识**：未知 wire value 保存为 `.unknown(rawValue)`，重新编码时原样输出。凭据类型和后续 provider 标识采用此策略。

两种策略都不得因为未来枚举值导致整条记录解码失败。安全相关算法、schema version 和密码学 suite 不属于可宽松降级的业务枚举；不支持时 MUST 明确失败。

## 5. 游标分页

请求字段为可选 `cursor` 和受服务端上限约束的正整数 `limit`。响应固定包含：

| 字段 | 类型 | 语义 |
| --- | --- | --- |
| `items` | array | 本页结果；终页可以为空 |
| `next_cursor` | string 或 `null` | 非空字符串表示下一页；`null` 明确表示终页 |

writer MUST 在终页输出 `"next_cursor": null`。为兼容旧 writer，reader MAY 把缺失 `next_cursor` 当作终页。空字符串不是有效游标。游标是不透明值，客户端不得解析、排序、拼接或持久依赖其内部格式。

## 6. Fixture

[`wire-format-v1.json`](../fixtures/core/wire-format-v1.json) 固定 epoch 毫秒和分页的首组跨语言样本。patch 的三态语义由各语言合同测试构造 `{}`、`{"field":null}` 和 `{"field":"value"}` 验证。

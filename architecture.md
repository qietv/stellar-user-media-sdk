# WebDAV 只读访问架构

本文定义 `StellarWebDAV` 的只读访问、HTTP 重定向和凭据隔离策略。SDK 通过
`MediaSourceConnector` 接入共享扫描器，只负责目录枚举、文件状态和字节范围读取，
不提供 WebDAV 写入或文件管理能力。仓库的整体模块边界见
[`docs/architecture/overview.md`](docs/architecture/overview.md)。

## 请求链路

```text
WebDAVMediaSourceSession
  → 构造 PROPFIND 或 Range GET
  → URLSessionWebDAVTransport 禁止 URLSession 自动跳转
  → 检查 301 / 302 / 307 / 308
  → 应用跳转策略并重新构造请求
  → 最终响应交回 session 校验
```

transport 显式处理重定向，避免系统网络栈在 301/302 后改变 WebDAV 方法，或把来源
凭据带到下载网关。最多跟随五次跳转，并以完整目标 URL 检测循环。

## 重定向策略

| 请求与目标 | 行为 |
|---|---|
| 同源 `PROPFIND` 的 301/302/307/308 | 跟随；保持方法、XML body、`Depth`、Content-Type 和 Authorization |
| 同源 `GET`/`HEAD` | 跟随；保持 `Range` 等读取条件和来源凭据 |
| 跨源 `GET`/`HEAD` 到 HTTPS | 跟随；保留 `Range`，移除来源凭据和 Cookie |
| 跨源 `PROPFIND` | 拒绝，防止元数据根和信任边界被静默替换 |
| HTTPS 跳转到 HTTP | 拒绝 |
| 无效 Location、userinfo、fragment、循环或超过五次 | 拒绝 |
| 300、303、304、305、306 或其他 3xx | 不自动跟随，交由上层状态校验失败 |

初始 HTTP 来源只有在调用方通过 `allowsInsecureHTTP` 明确允许时才能建立；它可以同源
跳转或升级到 HTTPS，但 HTTPS 请求永远不能降级到 HTTP。

## 凭据边界

Basic Authorization 只属于配置来源的 HTTP protection space。跳转的 scheme、host 或
有效端口任一发生变化，即视为跨源，并移除：

- `Authorization`；
- `Proxy-Authorization`；
- `Cookie` 与 `Cookie2`；
- 手工设置的 `Host`。

跨源下载 URL 通常通过查询参数携带短期签名。URL、查询参数、请求头和响应头不得进入
普通日志、错误消息或持久化模型。跨源目标仍必须通过系统 TLS 校验。

## 响应约束

- `PROPFIND` 必须最终返回允许的 2xx；通常为 `207 Multi-Status`，随后解析 DAV XML。
- 同一 `DAV:response` 中的每个 `DAV:propstat` 独立判定；可选属性返回 404 时，不得覆盖
  其他 2xx propstat 中已经取得的资源类型和元数据。
- Range GET 必须最终返回 `206 Partial Content`；服务器忽略 Range 并返回 `200` 时读取失败。
- 401、403、404、429、超时和 5xx 继续映射为稳定的 `SDKErrorCode`。
- 跳转策略拒绝返回 `forbidden`；循环、无效 Location 和次数超限返回
  `remote_unavailable`，扫描器不得据此协调 missing 删除。

## 标准依据

- [RFC 4918 §5.2](https://www.rfc-editor.org/rfc/rfc4918.html#section-5.2)：WebDAV
  客户端需要准备处理集合 URL 重定向。
- [RFC 9110 §15.4](https://www.rfc-editor.org/rfc/rfc9110.html#section-15.4)：301、302、
  307 和 308 的 HTTP 语义。
- [RFC 9110 §11.5](https://www.rfc-editor.org/rfc/rfc9110.html#section-11.5)：认证
  protection space 不应跨服务器扩展。

## 验证要求

合同测试必须覆盖：同源 WebDAV 方法保持、跨源 Range GET、跨源凭据剥离、HTTPS
降级拒绝、跨源 PROPFIND 拒绝、循环检测和混合 2xx/404 propstat。真实服务器验证只能使用只读
`OPTIONS`、`PROPFIND`、`HEAD` 或小范围 GET，测试凭据和签名 URL 不得写入仓库。

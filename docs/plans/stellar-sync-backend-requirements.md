# StellarSync Backend Requirements v1

最后核对日期：2026-08-18

状态：**后端首版实施合同**。本文把现有跨平台规范整理为后端可执行需求；字段语义仍以 `specs/` 下的公共合同为准。

## 1. 目标

后端为同一 Stellar 账户的多台设备同步以下两类数据：

1. `MediaSourceConfig`：媒体源地址、路径、扫描与元数据策略、凭据引用和删除墓碑；
2. `CredentialRecord`：SMB、WebDAV、云盘和媒体服务器等第三方来源的认证材料。

用户在新设备完成 Stellar OAuth 后，必须能够直接拉取配置和第三方凭据，不需要旧设备批准、恢复口令或独立 Vault 解锁。

### 1.1 首版明确不做

- 不同步 `playback_state`、观看进度或播放历史；
- 不同步片单、收藏、人工匹配或媒体库索引；
- 不同步文件清单、技术信息、海报或缓存；
- 不同步 Stellar OAuth access token、refresh token、授权码或 PKCE 材料；
- 不实现服务端托管加密或 E2EE；
- 不连接用户的 NAS、WebDAV 或云盘，不执行扫描，也不删除任何远端媒体文件；
- 不在服务端自动拼接两个并发版本的凭据或连接端点。

后续增加播放进度同步时，必须使用独立 entity 合同和媒体库 outbox，不得在 v1 的两种 entity 中夹带播放状态。

## 2. 上游依赖与鉴权

### 2.1 Gateway 工作

Gateway 需要注册并签发两个 scope：

| Scope | 用途 |
| --- | --- |
| `media_sources.read` | 拉取来源配置和第三方凭据 |
| `media_sources.write` | 上传来源配置、凭据和删除墓碑 |

iOS、desktop 以及后续 Android/OHOS Public Client Policy 需要允许申请相应 scope。客户端正常登录申请 `profile.read media_sources.read media_sources.write`。

### 2.2 Resource Server 鉴权

- 所有接口必须使用 HTTPS 和 `Authorization: Bearer <access_token>`；
- 后端必须通过既有 Gateway middleware、introspection 或受信任 JWT 验证链验证 token，不得信任客户端自行解释的 token 字段；
- 服务端账户边界来自已验证 token 对应的 `subject_id`；首版 `account_uid == subject_id`；
- 请求体中的 `account_uid` 必须与认证主体完全一致，否则返回 `403 forbidden`；
- `device_uid` 只用于同步游标和设备活跃度，不是身份凭证，也不能扩大账户权限；
- read/write scope 分别校验，不能仅因 token 有 `profile.read` 就允许同步；
- 跨账户 UID 探测必须失败且不能泄露目标记录是否存在。

开发环境建议继续由 User Service 承载，基地址为：

```text
https://dev-user-stellarplayer.2dland.cn/api/v1/media-source-sync
```

生产环境 host 由部署配置提供，path 和 wire contract 保持一致。

## 3. API

所有请求和响应使用 UTF-8 JSON、`snake_case` 和 Unix epoch 毫秒。请求必须设置 `Content-Type: application/json`。响应必须带 `trace_id`；普通错误文本不得包含账户资料、host、路径或凭据。

### 3.1 Push：提交一个 outbox operation

```http
POST /api/v1/media-source-sync/operations
```

首版一次请求只提交一个 operation，客户端按本地 outbox `seq` 顺序发送。这样可以清楚地确认每个 operation，避免批量请求中的部分成功语义。

请求：

```json
{
  "account_uid": "00000000-0000-0000-0000-000000000001",
  "device_uid": "00000000-0000-0000-0000-000000000002",
  "client_schema_version": 1,
  "operation_uid": "00000000-0000-0000-0000-000000000003",
  "entity_type": "media_source_config",
  "entity_uid": "00000000-0000-0000-0000-000000000004",
  "base_revision": 0,
  "operation": "upsert",
  "record": {
    "source_uid": "00000000-0000-0000-0000-000000000004",
    "account_uid": "00000000-0000-0000-0000-000000000001",
    "kind": "smb",
    "display_name": "Media NAS",
    "endpoint": {
      "scheme": "smb",
      "host": "nas.example.test",
      "port": 445,
      "uses_tls": false
    },
    "root_path": "Media",
    "included_paths": ["Movies", "TV"],
    "excluded_paths": ["Samples"],
    "scan_policy": {
      "automatic": true,
      "interval_ms": 900000,
      "unmetered_network_only": true,
      "external_power_only": false
    },
    "metadata_policy": {
      "language": "zh-Hans",
      "region": "HK",
      "preferred_providers": ["tmdb"],
      "prefer_local_metadata": true
    },
    "connection_mode": "automatic",
    "credential_mode": "synced",
    "credential_uid": "00000000-0000-0000-0000-000000000005",
    "capabilities": ["list", "range_read", "read", "stable_id"],
    "revision": 1,
    "updated_at_ms": 1700000000000,
    "schema_version": 1
  }
}
```

`entity_type` 首版只允许：

- `media_source_config`，其 `entity_uid` 必须等于 `record.source_uid`；
- `credential_record`，其 `entity_uid` 必须等于 `record.credential_uid`。

`record.account_uid` 必须同时等于请求 `account_uid` 和认证主体。`operation=delete` 仍须上传完整墓碑记录：`deleted_at_ms` 必须存在；CredentialRecord 墓碑的 `payload_json` 必须为 `null`。`operation=upsert` 时 `deleted_at_ms` 必须缺失或为 `null`。

成功响应：

```json
{
  "operation_uid": "00000000-0000-0000-0000-000000000003",
  "entity_type": "media_source_config",
  "entity_uid": "00000000-0000-0000-0000-000000000004",
  "status": "accepted",
  "revision": 1,
  "change_cursor": "opaque-account-scoped-cursor",
  "server_time_ms": 1700000000100,
  "trace_id": "00000000-0000-0000-0000-000000000006"
}
```

### 3.2 Pull：按账户游标拉取变化

```http
POST /api/v1/media-source-sync/changes
```

请求：

```json
{
  "account_uid": "00000000-0000-0000-0000-000000000001",
  "device_uid": "00000000-0000-0000-0000-000000000002",
  "client_schema_version": 1,
  "cursor": null,
  "limit": 100
}
```

- `cursor=null` 表示建立该账户当前状态的一致性 snapshot，用于新设备恢复；
- `limit` 必须为 `1...200`，默认 100；
- cursor 必须完全不透明、不可为空字符串、绑定账户且防篡改；
- 其他账户、无效或被篡改的 cursor 返回 `400 invalid_configuration`，不得回退为全量同步；
- 结果按服务端 change sequence 严格升序。

新设备 snapshot 必须先固定服务端 high-water sequence，并且每个 entity 只返回该
high-water 位置上最新的完整 revision 或墓碑。不能把同一凭据的历史 active revision
逐条重放给新设备，否则已删除的旧秘密可能在后续 tombstone 到达前被短暂恢复。snapshot
分页期间产生的新 change 位于 high-water 之后，在 snapshot 完成后的下一轮增量 pull 返回。

响应：

```json
{
  "items": [
    {
      "operation_uid": "00000000-0000-0000-0000-000000000003",
      "entity_type": "media_source_config",
      "entity_uid": "00000000-0000-0000-0000-000000000004",
      "operation": "upsert",
      "revision": 1,
      "record": {}
    }
  ],
  "checkpoint_cursor": "opaque-cursor-after-this-page",
  "next_cursor": null,
  "server_time_ms": 1700000000100,
  "has_more": false,
  "trace_id": "00000000-0000-0000-0000-000000000006"
}
```

游标规则：

- `checkpoint_cursor` 始终为非空字符串，表示本页最后一个已扫描位置；客户端只有在本页所有 items 原子落库后才能保存它；
- `has_more=true` 时，`next_cursor` 必须等于 `checkpoint_cursor`，客户端立即拉下一页；
- `has_more=false` 时，`next_cursor` 必须为 `null`，客户端保存 `checkpoint_cursor`，供下一轮增量同步使用；
- 空账户或当前没有新变化时也必须返回可保存的 `checkpoint_cursor`；
- 服务端不得要求客户端解析、比较或拼接 cursor。

snapshot 的分页 cursor 必须绑定固定 high-water 和页位置；snapshot 终页返回的
`checkpoint_cursor` 表示该 high-water。后续 pull 从该 checkpoint 进入按 change sequence
递增的 delta 模式。每轮 delta pull 同样先固定本轮 high-water；分页 continuation 只读取
不超过该位置的 change，本轮期间新写入的 change 留到下一轮，避免同步在持续写入时永不结束。

`record` 是对应 revision 的完整 `MediaSourceConfig` 或 `CredentialRecord`，不能是 patch。配置和凭据可以任意顺序到达；服务端不能因为另一种记录暂时不存在而拒绝当前记录。

## 4. Revision、幂等与冲突

### 4.1 Revision

- revision 由服务端最终确认，按单个 entity 单调递增；不同 entity 之间不比较 revision；
- 新建要求 `base_revision=0`、服务端不存在该 entity、`record.revision=1`；
- 更新或删除要求 `base_revision` 等于服务端当前 revision；
- candidate 的 `record.revision` 必须等于 `base_revision + 1`；
- 接受后在同一事务中写入 current record、change event 和 operation outcome；
- `updated_at_ms` 是客户端提供的展示/诊断时间，不能代替 revision，也不能用于覆盖 CAS；服务端另存 `received_at_ms`。

### 4.2 Idempotency

`operation_uid` 是幂等键。服务端必须先检查幂等记录，再检查当前 revision：

1. 首次收到 operation 时，对规范化请求计算 SHA-256；
2. 相同账户、相同 `operation_uid`、相同请求 hash 的重试返回首次终态，不再次增加 revision 或 change event；accepted 必须返回首次 revision/change sequence，conflict 必须始终保持 conflict；
3. 相同 `operation_uid` 携带不同 entity、base revision、operation 或 record 时返回 `409 conflict`，错误原因为 `operation_uid_reused`；
4. 幂等记录至少保留到对应 change event 允许压缩之后。首版不启用压缩，因此不删除幂等记录；
5. request hash 只保存 digest，不能把凭据复制到普通审计表或日志。

请求 hash 基于服务端解码、规范化后的完整 envelope；JSON key 顺序和无意义空白不能改变 hash。
冲突重试可以在保持首次 `conflict` 终态的前提下附带当前最新 `remote_record`，但绝不能因为
服务端 revision 后来发生变化而把同一 operation 改判为 accepted。operation history 不需要保存
candidate 或 remote credential payload。

### 4.3 冲突

首版采用严格 compare-and-swap，不在后端做字段级自动合并：

- `base_revision` 与当前 revision 不一致时返回 `409 conflict`；
- 响应包含 `remote_revision` 和完整 `remote_record`，客户端将本地 candidate 与远端记录写入本地 `sync_conflict`；
- `CredentialRecord` 绝不进行字段级合并或组合两个 payload；
- `MediaSourceConfig.endpoint`、`root_path`、`credential_mode` 和 `credential_uid` 绝不静默覆盖；
- 删除意图由客户端在看到最新 remote revision 后，以新的 `operation_uid` 和新的 `base_revision` 重交，因此最终可以 delete-wins，但后端不能让陈旧删除绕过 CAS；
- 服务端当前是 tombstone 时，普通 upsert 不能自动复活；仍返回 conflict，必须由显式冲突解决操作重交；
- 冲突不会写 current record 或 change event。

冲突响应：

```json
{
  "code": "conflict",
  "reason": "base_revision_mismatch",
  "message": "media source sync revision conflict",
  "operation_uid": "00000000-0000-0000-0000-000000000003",
  "entity_type": "credential_record",
  "entity_uid": "00000000-0000-0000-0000-000000000005",
  "remote_revision": 4,
  "remote_record": {},
  "trace_id": "00000000-0000-0000-0000-000000000006"
}
```

该响应可能包含明文凭据，HTTP/APM/错误收集系统不得记录响应 body。

## 5. 数据校验

后端必须按客户端相同规则重新校验，不能把客户端已校验作为信任边界。

### 5.1 MediaSourceConfig

- `schema_version` 只能为 1；
- `kind` 只允许 `local_folder`、`device_media`、`smb`、`nfs`、`webdav`、`ftp`、`cloud_drive`、`plex`、`emby`、`jellyfin`；
- `connection_mode` 只允许 `direct`、`relay`、`automatic`；
- `credential_mode` 只允许 `synced`、`device_local`、`server_managed`、`none`；
- `credential_mode=synced` 必须携带 `credential_uid`，其他模式不得携带；
- endpoint 不能包含 userinfo、完整 URL、路径、用户名、密码或 token；
- scheme 必须匹配 `[a-z][a-z0-9+.-]{0,31}`，port 为 `1...65535`；
- 所有路径使用 `/`，禁止 `..` segment 和 NUL；
- `included_paths`、`excluded_paths`、`capabilities` 必须去重并按规范顺序保存；
- 未知 capability 原样保留；未知 kind/connection mode/credential mode 失败关闭；
- `automatic=false` 时不得有 `interval_ms`，存在 interval 时必须不少于 60000；
- region 为两个大写 ASCII 字母，provider 名去重并规范化；
- 单个 config HTTP 编码后不得超过 256 KiB。

### 5.2 CredentialRecord

- `schema_version` 只能为 1；
- 首版只接受 `protection_mode=plaintext`；其他模式返回 `422 credential_protection_unsupported`，不得降级为 plaintext；
- plaintext active record 必须只有 `payload_json`，所有加密预留字段必须为 `null`；
- plaintext tombstone 必须令 `payload_json=null`；
- `payload_json` 是 JSON 字符串，不是任意 JSON object，UTF-8 大小不得超过 65536 bytes；
- 后端必须解析并重新验证 `payload_json`，确认 `CredentialRecord.kind` 与 payload `auth_type` 对应；
- 只接受 `username_password`、`oauth_token`、`api_token`、`cookie`、`key_pair` 五种 allowlisted shape；
- 未知字段、混合认证字段、空必填值、NUL、重复 cookie scope 和未来 schema 全部失败关闭；
- 精确长度、cookie 默认值和规范 JSON规则见 `specs/security/credential-storage.md` 与 `credential-payload-v1.json`；
- `credential_uid` 首次绑定的 `account_uid` 与 `source_uid` 不可在后续 revision 中改变；
- 允许配置与凭据任意先后写入，不能要求 source row 已存在；若同账户对应 row 已存在，则 UID 关联必须一致。

## 6. 推荐服务端数据模型

实现可以使用不同表名，但必须具备以下语义：

| 表/集合 | 必要数据 | 说明 |
| --- | --- | --- |
| source current | account、source UID、完整记录、revision、tombstone、last change sequence | `(account_uid, source_uid)` 唯一 |
| credential current | account、credential/source UID、完整记录、revision、tombstone、last change sequence | payload 为应用层明文 |
| sync operation | account、operation UID、request hash、终态/reason、accepted revision/change sequence、时间 | `(account_uid, operation_uid)` 唯一；不保存 record body |
| sync change | account、sequence、operation/entity、revision、operation、完整 record snapshot、时间 | pull 的唯一有序事实源 |
| sync device | account、device UID、last checkpoint、last seen | 未来墓碑压缩使用 |

`sync change` 保存完整 revision snapshot，确保分页、重试和按 high-water 还原当前状态
具有确定性。新设备 snapshot 对每个 entity 只选择 `sequence <= high_water` 的最新一条；
已有设备的 delta pull 才按 sequence 返回 checkpoint 之后的变化。change history 会再次保存
CredentialRecord 明文，因此 current、change、备份、只读副本和数据库快照都必须按凭据
材料保护。

一次 push 的事务顺序：

1. 验证认证主体和 envelope；
2. 查询/锁定 idempotency row；
3. 锁定当前 entity row；
4. 校验 immutable identity、schema 和 base revision；
5. 分配 change sequence；
6. 写 current record；
7. 追加完整 change snapshot；
8. 写 operation outcome；
9. 提交事务。

任一步失败都不能留下新 revision、孤立 change 或“已接受但不可拉取”的 operation。

## 7. Cursor 与保留策略

- cursor 至少绑定 account UID、模式、该轮 high-water、snapshot 页位置或 delta change sequence，并使用服务端签名或等效防篡改编码；
- sequence 仅用于服务端排序，不能直接暴露为客户端可依赖的 cursor 格式；
- 客户端重复使用旧 cursor 必须安全，最多重复收到相同 change；
- 客户端按 `(entity_uid, revision)` 幂等 apply；
- 首版不压缩 change、tombstone 或 idempotency rows，先保证离线设备和新设备恢复正确；
- 可以记录设备 `last_seen_at_ms` 和 checkpoint，但不能据此在首版提前硬删除；
- 后续启用压缩前必须定义活跃设备窗口、cursor expiry、全量 snapshot 恢复和备份删除策略；
- Stellar 账户执行“删除账户数据”时，必须覆盖 current、change history、operation history、device cursor、只读副本和备份生命周期。

## 8. 错误与 HTTP 状态

| HTTP | `code` | 场景 |
| --- | --- | --- |
| 400 | `invalid_configuration` | envelope、cursor、schema 或字段无效 |
| 401 | `unauthorized` | token 缺失、无效或过期 |
| 403 | `forbidden` | scope 不足或 account UID 不匹配 |
| 409 | `conflict` | base revision 冲突、operation UID 被不同请求复用、禁止复活 |
| 413 | `invalid_configuration` | 请求或记录超过大小上限 |
| 422 | `credential_protection_unsupported` | 不支持的保护模式 |
| 429 | `rate_limited` | 限流；必须提供 `retry_after_ms` |
| 500/502/503/504 | `remote_unavailable` | 服务端或依赖暂时不可用 |

公共错误至少包含：

```json
{
  "code": "invalid_configuration",
  "reason": "stable_machine_reason",
  "message": "developer-facing message without secrets",
  "retry_after_ms": null,
  "trace_id": "00000000-0000-0000-0000-000000000006"
}
```

`reason` 用于精确协议诊断，`code` 必须能映射到 SDK 公共错误分类。生产 message 不得回显原始字段值、record、URL、payload 或 token。

## 9. 安全与可观测性

- 禁止记录 Authorization header、Cookie、请求/响应 body、`payload_json`、username、password、token、private key、host、service identifier 和 root path；
- API gateway、反向代理、WAF、APM、错误追踪、慢查询、消息队列和 debug middleware 都必须关闭 body capture；
- 普通审计只记录 trace ID、operation UID、entity type、结果、延迟、HTTP status 和经过最小化/散列的账户标识；
- 数据库运行账号采用最小权限；生产数据、WAL、备份、快照、只读副本和导出均按凭据材料限制访问；
- TLS、基础设施加密或 Base64 不得被描述为 E2EE；
- 不把完整 record 放入 Redis、通用任务队列、DLQ 或普通缓存；确需异步处理时，相同安全边界必须覆盖所有副本；
- credential API 响应设置 `Cache-Control: no-store`；边缘/CDN 不得缓存；
- rate limit 以认证账户和设备为主键，不能依赖可伪造的 account UID；
- secret-redaction 自动测试必须搜索公共 fixture 中的 `fixture-password`、`fixture-refresh-token`、`fixture-api-token`、`fixture-cookie`、`fixture-private-key-material`，确保日志、trace、metric label 和错误事件中不存在这些值。

## 10. 后端验收测试

### 10.1 鉴权

- 无 token、过期 token、错误 issuer/audience 或撤销 token 被拒绝；
- 只有 `profile.read` 的 token 不能读写同步 API；
- read scope 不能 push，write scope 不能代替 read；
- request account UID 与 token subject 不一致时拒绝且不泄露记录；
- 一个账户的 cursor 不能被另一个账户使用。

### 10.2 Push 与幂等

- `base_revision=0` 创建配置，返回 revision 1；
- revision 1 更新为 revision 2；
- 相同 operation 重试 20 次只产生一个 revision 和一个 change；
- 同一 operation UID 换 payload 返回冲突且不修改 current；
- 两个设备基于同一 revision 并发更新，最多一个成功；
- CredentialRecord 冲突不发生字段级合并；
- 陈旧删除不能绕过 CAS，基于最新 revision 重交后形成 tombstone；
- tombstone 后普通 upsert 不自动复活；
- `playback_state` 等未知 entity type 被拒绝。

### 10.3 Pull

- 新设备从 null cursor 分页拉取 high-water 位置上每个 entity 的最新配置、凭据或 tombstone；
- 新设备不能收到同一 entity 已被后续 revision 取代的旧 active credential；
- page 顺序稳定且 cursor 不重不漏；
- 重放旧 cursor 只导致幂等重复，不造成数据损坏；
- 空页返回可保存的 checkpoint；
- 无效、空字符串、跨账户和被篡改 cursor 失败关闭；
- 配置先到、凭据先到以及同页到达都可被客户端安全 apply；
- 服务器在分页期间收到新 push 时，新 change 不丢失，并在当前或下一轮 pull 中出现。

### 10.4 数据与安全

- `source-config-sync-v1.json` 的 active/tombstone 能往返且规范顺序不变；
- `credential-payload-v1.json` 所有 valid shape 成功，所有 invalid shape 被拒绝；
- 不支持的 protection mode 返回稳定错误且不覆盖已有 plaintext 或未来记录；
- 数据库 current 与 change snapshot 可以读取测试 plaintext，证明产品没有虚假 E2EE 声明；
- API、代理、APM、错误追踪和数据库普通审计日志中找不到 fixture secret；
- 删除账户测试覆盖 current、history、operation、cursor 和备份生命周期。

### 10.5 端到端完成定义

```text
设备 A 登录
  -> 离线创建 SMB MediaSourceConfig + CredentialRecord
  -> 两个 outbox operation 幂等 push
  -> 设备 B 使用同一 Stellar 账户登录
  -> 从空库 pull 并原子 apply
  -> 设备 B 直接取得来源配置与第三方凭据
  -> 重复 push/pull 不新增 entity、不增加已确认 revision
  -> 并发修改进入 conflict，不静默覆盖
```

整个流程不得同步播放进度，也不得触碰 NAS 上的媒体文件。

## 11. 后端交付物

- Gateway scope 与 Public Client Policy 更新；
- 数据库 migration 和回滚说明；
- 两个 API endpoint 及 OpenAPI 文档；
- revision/CAS、idempotency、cursor 和账户隔离测试；
- credential fixture 校验器或等价严格校验代码；
- 日志/APM/body capture 配置与 secret-redaction 测试；
- 开发环境 base URL、scope 和部署版本；
- 一组不含真实秘密的集成测试账号与调用样例；
- 后端通过验收后，再由 Swift `StellarSync` target 对接真实 transport。

## 12. 关联合同

- [`specs/remote-media/source-config-sync.md`](../../specs/remote-media/source-config-sync.md)
- [`specs/security/credential-storage.md`](../../specs/security/credential-storage.md)
- [`specs/core/wire-format.md`](../../specs/core/wire-format.md)
- [`specs/auth/oauth-session.md`](../../specs/auth/oauth-session.md)
- [`specs/storage/sql/account-v1.sql`](../../specs/storage/sql/account-v1.sql)
- [`specs/fixtures/remote-media/source-config-sync-v1.json`](../../specs/fixtures/remote-media/source-config-sync-v1.json)
- [`specs/fixtures/security/credential-payload-v1.json`](../../specs/fixtures/security/credential-payload-v1.json)

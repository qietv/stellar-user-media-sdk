# 工具

`reference/` 保存调研阶段形成的可运行参考实现，不属于 Apple SDK 的公共 API。

## Infuse/TMDB 匹配器

[infuse_tmdb_matcher.py](reference/infuse_tmdb_matcher.py) 用于验证文件名解析、电影/剧集候选查询、详情与图片下载等行为。仓库副本不内置 TMDB API key，使用前通过环境变量或命令行传入：

```bash
TMDB_API_KEY="your-key" python3 reference/infuse_tmdb_matcher.py --help
```

它是研究和回归样本，不应直接成为生产 SDK 的网络层；生产实现必须补齐密钥配置、限流、缓存、隐私和服务条款处理。

## CI 守卫

- `ci/check_swift_dependencies.py`：拒绝 SwiftPM branch/range 依赖；存在外部依赖时要求提交 `Package.resolved`。
- `ci/check_swift_api.py`：从 Swift symbol graph 校验顶层 DocC 注释，并对比 `platforms/swift/API/PublicAPI.json`。
- `ci/secret_scan.py`：扫描已跟踪文件中的高置信度 secret，不打印匹配值。

## SMB 本机协议回归

`ci/run_smb_paging_fixture.py` 启动仅监听 loopback 的临时只读 SMB 服务，创建 1,201 个目录条目，
运行 Swift 原生分页、并列目录、中文名称、stat、range read 和过期游标测试，并检查实际
`QUERY_DIRECTORY` 请求缓冲区不超过 64 KiB。需要可选测试依赖，和 SDK 产品依赖分离：

```bash
python3 -m venv /tmp/stellar-smb-fixture-venv
/tmp/stellar-smb-fixture-venv/bin/pip install impacket==0.13.1
/tmp/stellar-smb-fixture-venv/bin/python tools/ci/run_smb_paging_fixture.py
```

脚本不使用真实 NAS、系统文件共享配置或真实凭据，退出后删除临时共享。

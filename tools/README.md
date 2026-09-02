# 工具

`reference/` 保存调研阶段形成的可运行参考实现，不属于三端 SDK 的公共 API。

## Infuse/TMDB 匹配器

[infuse_tmdb_matcher.py](reference/infuse_tmdb_matcher.py) 用于验证文件名解析、电影/剧集候选查询、详情与图片下载等行为。仓库副本不内置 TMDB API key，使用前通过环境变量或命令行传入：

```bash
TMDB_API_KEY="your-key" python3 reference/infuse_tmdb_matcher.py --help
```

它是研究和回归样本，不应直接成为生产 SDK 的网络层；生产实现必须补齐密钥配置、限流、缓存、隐私和服务条款处理。

## CI 守卫

- `ci/check_swift_dependencies.py`：拒绝 SwiftPM branch/range 依赖；存在外部依赖时要求提交 `Package.resolved`。
- `ci/check_swift_api.py`：从 Swift symbol graph 校验顶层 DocC 注释，并对比 `platforms/swift/API/PublicAPI.json`。
- `ci/check_portable_swift_imports.py`：阻止 portable Swift targets 无条件导入 Apple-only framework。
- `ci/secret_scan.py`：扫描已跟踪文件中的高置信度 secret，不打印匹配值。

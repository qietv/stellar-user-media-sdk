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
- `ci/check_libsmb2_binding.py`：校验 libsmb2 lock、私有 C module 和项目 wrapper 边界；确认 Linux 静态 archive 只导出项目私有前缀 symbol、wrapper 不泄漏上游类型或动态依赖，并运行失败连接/释放烟测。
- `ci/build_libsmb2_static_linux.sh`：从固定 commit 构建 NTLMSSP-only 静态 libsmb2，对所有已定义全局 symbol 加私有前缀，并生成私有 pkg-config 记录。
- `ci/check_portable_swift_imports.py`：阻止 portable Swift targets 无条件导入 Apple-only framework。
- `ci/secret_scan.py`：扫描已跟踪文件中的高置信度 secret，不打印匹配值。

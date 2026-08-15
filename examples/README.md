# 示例应用

示例目录用于展示同一条端到端路径在三个平台上的调用方式：

1. 初始化 SDK 并恢复登录状态。
2. 通过 OAuth 登录或切换账号。
3. 添加一个远程媒体源，并把连接配置与 E2EE 凭据 envelope 同步到账号。
4. 解锁 Credential Vault、验证连接并启动扫描。
5. 订阅扫描进度和媒体库增量。
6. 分页获取海报墙，进入详情并取得可播放 locator。

在三端构建清单和 API 骨架完成前，本目录只保留平台入口说明。

- [Swift 示例](swift/README.md)
- [Android 示例](android/README.md)
- [OpenHarmony 示例](ohos/README.md)

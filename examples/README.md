# 示例应用

示例目录用于展示 Apple 应用的端到端调用路径：

1. 初始化 SDK 并恢复登录状态。
2. 通过 OAuth 登录或切换账号。
3. 添加一个远程媒体源，并把连接配置与明文 `CredentialRecord` 同步到账号。
4. 在新设备完成 Stellar OAuth 后直接恢复凭据、验证连接并启动扫描。
5. 订阅扫描进度和媒体库增量。
6. 分页获取海报墙，进入详情并取得可播放 locator。

- [Swift 示例](swift/README.md)

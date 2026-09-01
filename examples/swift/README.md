# Swift 示例

## iOS OAuth Demo

打开 [`StellarOAuthDemo/StellarOAuthDemo.xcodeproj`](StellarOAuthDemo/StellarOAuthDemo.xcodeproj)，
按照同目录 README 配置签名，即可验证 claimed HTTPS OAuth 登录、Keychain 会话恢复、
公开资料刷新、账户切换和注销。

2026-08-18 已使用该工程在真机完成上述 OAuth 与非交互 Keychain 路径验收。

该工程要求 iOS 17.4 或更高版本，并直接引用 `platforms/swift` 本地 Package。

## CLI

当前可直接运行的最小示例是 Swift Package 中的 CLI：

```bash
cd ../../platforms/swift
swift run stellar-media parse "The.Matrix.1999.2160p.mkv"
```

后续 SwiftUI 示例将继续覆盖 WebDAV/SMB 配置、手动扫描和海报墙分页。播放器层只消费 SDK 返回的可播放资源，不放入本 SDK。

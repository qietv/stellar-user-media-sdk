# Swift 示例计划

当前可直接运行的最小示例是 Swift Package 中的 CLI：

```bash
cd ../../platforms/swift
swift run stellar-media parse "The.Matrix.1999.2160p.mkv"
```

计划提供一个 SwiftUI 示例，覆盖会话恢复、OAuth 登录、WebDAV/SMB 配置、手动扫描和海报墙分页。播放器层只消费 SDK 返回的可播放资源，不放入本 SDK。

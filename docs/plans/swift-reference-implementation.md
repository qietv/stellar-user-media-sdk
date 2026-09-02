# Apple Swift Implementation Plan

状态：当前实施计划
平台：iOS/iPadOS 17、macOS 14、tvOS 17
工具链：Swift 6.3、Swift 6 language mode

旧版本计划曾把 Swift SDK 作为多平台 reference implementation，并包含非 Apple
构建与自编译 libsmb2 里程碑。该方向已由
[ADR-0007](../decisions/0007-apple-only-platform-scope.md) 取代；旧 libsmb2 分发方案的历史背景见
[ADR-0003](../decisions/0003-libsmb2-distribution-and-abi.md)。

## 目标

1. 用一套原生 Swift API 覆盖支持的 Apple 设备族。
2. 通过清晰的 target 边界隔离 Core、Auth、Storage、MediaLibrary、PosterWall、来源 adapter
   与截图能力。
3. 所有外部依赖使用 exact version 或 immutable revision，并提交 `Package.resolved`。
4. 公开 API、SQLite schema、wire fixture、安全规则与迁移必须可重复验证。
5. 产品代码不得包含非 Apple fallback、非 Apple 网络/XML overlay 或兼容性条件分支。

## 包结构

```text
StellarCore
├── StellarAuth
├── StellarRemoteMedia
│   ├── StellarLocalMedia
│   ├── StellarWebDAV
│   └── StellarSMB2Core ← StellarSMB2Apple ← AMSMB2
├── StellarStorage ← GRDB
├── StellarMediaLibrary
├── StellarPosterWall
└── StellarMediaImaging ← CStellarFFmpegScreenshot ← FFmpegKit/libav
```

`StellarUserMediaSDK` 是业务 facade；`StellarSMB2` 与 `StellarMediaImaging` 独立导出，避免
宿主不使用这些能力时被迫耦合第三方类型。`stellar-media` 只作为 macOS 开发与验收宿主。

## 当前完成项

- [x] Swift 6.3 package 与 Apple 最低系统版本；
- [x] OAuth PKCE、session actor、Data Protection Keychain 与多账户切换；
- [x] 来源无关 scanner、WebDAV、本地目录与 remote range read；
- [x] GRDB migration、repository、scan sink、metadata matching 和 PosterWall；
- [x] AMSMB2 Apple adapter 与 SMB contract tests；
- [x] FFmpegKit/libav 帧解码和 PNG/JPEG 截图；
- [x] 公共 API baseline、依赖锁定、schema、fixture 与 secret guards；
- [x] macOS CI 和 iOS device/simulator 的主 SDK、SMB、截图产品编译门禁。

## 下一阶段

- [ ] 完成来源配置同步 transport、remote apply 与 conflict resolution；
- [ ] 将来源变化接入真实扫描调度；
- [ ] 为远端截图实现 seek-friendly 自定义 libav I/O，避免整文件暂存；
- [ ] 补充 display matrix、sample aspect ratio 与 HDR tone mapping；
- [ ] 在具备相应 SDK 的构建机加入 tvOS 产品编译门禁；
- [ ] 完成第三方二进制许可证、隐私清单和 App Store 合规审查。

## 持续门禁

macOS CI 必须执行：

1. `swift format lint --recursive --strict Sources Tests Package.swift`；
2. 精确依赖与 `Package.resolved` 检查；
3. 主 SDK 与截图模块公共 API baseline；
4. debug tests 与 release build；
5. iOS device/simulator 的 `StellarUserMediaSDK`、`StellarSMB2` 与 `StellarMediaImaging` 构建；
6. SQLite schema/checksum、fixture、secret scan 和 repository guard tests。

任何新增平台都必须通过新的 ADR 明确授权；不得以条件编译或 CI 矩阵的形式静默恢复。

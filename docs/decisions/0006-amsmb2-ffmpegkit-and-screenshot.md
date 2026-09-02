# ADR-0006：采用 AMSMB2、FFmpegKit 与解码帧截图

状态：Accepted  
日期：2026-09-02

## 背景

Swift SDK 原先自行固定、编译、符号前缀化并分发 libsmb2，同时维护 C wrapper、Linux 静态库、Apple XCFramework 和 LGPL relink kit。这条链路维护成本高，也与应用侧已经采用 TracyPlayer 组件的方向重复。

截图需求需要从本地或远端媒体中定位一个时间点、解码视频帧并生成通用图片。Infuse iOS 8.5.1 的静态证据显示，其缩略图路径由专用 decoder 创建视频 picture/pixel buffer，之后再交给图像或渲染层；它不是简单截取 UIKit 界面。我们只借鉴这一职责分层，不复制第三方私有实现。

## 决策

1. Apple 平台 SMB backend 使用 `TracyPlayer/AMSMB2` 4.0.3。选择这个精确版本是因为其 libsmb2 submodule 使用公开 HTTPS 地址；依赖由 SwiftPM 获取，本仓库不再保存或维护直接编译 libsmb2 的入口，底层 target 由 AMSMB2 package 自身管理。
2. 保留 `StellarSMB2Core` 的 `SMB2Transport` / `SMB2Session` 公共 seam。`StellarSMB2Apple` 只把 AMSMB2 的目录、属性、range read 和错误映射到现有值模型，不向 SDK 用户泄漏 AMSMB2/libsmb2 类型。
3. AMSMB2 没有公开 dialect 限制或 required-signing 配置。adapter 对无法忠实表达的策略返回 `invalidConfiguration`；协商 dialect 暂以 future-safe unknown 值报告。required encryption 映射到 AMSMB2 的 `encrypted` 参数。
4. Swift task 取消通过 SDK continuation gate 立即返回；AMSMB2 的私有同步 poll 在其自身队列上以缩短后的 timeout 安全收尾，不从取消线程销毁 context。
5. 截图使用 `TracyPlayer/FFmpegKit` commit `233c6bb6657a244ef57178e5d54979d1fd3cd45d`。只链接截图所需的 libavformat、libavcodec、libavutil、libswscale 及其直接运行时依赖，不调用 FFmpeg CLI。
6. `CStellarFFmpegScreenshot` 负责打开媒体、选择视频流、seek、解码目标时间点之后的第一帧、按最大边等比缩放并输出 BGRA8。Swift 层使用 ImageIO 编码 PNG/JPEG，并通过 `MediaScreenshotGenerating` 暴露本地文件和 `MediaSourceSession` 两个入口。
7. 远端媒体首版按 4 MiB 分块完整暂存到系统临时目录，再进入同一本地解码路径。来源 URL、用户名和密码不会传入 FFmpeg；临时文件在成功和失败路径都清理。
8. Infuse IPA 的展开文件、机械分析和方法定位结果保存在 `debug-infuse/infuse-ios-8.5.1/`。大体积目录默认不进入 Git，但不得作为构建清理目标。

## 结果与限制

- 自编译 libsmb2 的源码 module、C wrapper、静态 archive/XCFramework、lock、CI 构建检查和 Linux relink kit 被移除；ADR-0003 仅保留为历史记录。
- 当前生产 SMB backend 是 Apple-only；Linux 仍保留来源无关 seam 和 fake contract tests，但不再提供旧的自编译 libsmb2 transport/CLI。
- 首版远端截图会产生与媒体文件同量级的临时磁盘和网络 I/O。后续可在不改变公共 API 的前提下增加 custom AVIO/range-read cache。
- 首版截图不应用容器 display matrix、非方形像素校正或 HDR tone mapping；这些需要以方向、SAR 和色彩测试样本继续完善。
- FFmpegKit 当前固定构建的 `CONFIG_GPL=0`、`CONFIG_NONFREE=0`、`CONFIG_VERSION3=1`，但其仓库 README 与所带第三方二进制的许可证组合仍需在发布前逐项审查。AMSMB2 内含 LGPL libsmb2 源码。本文不构成法律意见。

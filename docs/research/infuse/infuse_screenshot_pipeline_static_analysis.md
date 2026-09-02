# Infuse iOS 8.5.1 截图/缩略图路径静态分析

版本：1.0  
日期：2026-09-02  
对象：用户提供的 `com.firecore.infuse_8.5.1_und3fined.ipa`

## 结论

Infuse 8.5.1 对媒体缩略图采用“专用 decoder → 解码 video frame → picture/pixel buffer → 图片或渲染层”的路径，而不是对 UIKit 播放界面做通用 screen capture。SDK 因此采用同样的职责边界：用 FFmpegKit/libav 精确解码一个媒体帧，再由平台 ImageIO 输出 PNG/JPEG。

这是 clean-room 架构结论。SDK 没有复制 Infuse 的函数体、数据结构或私有算法；时间点语义、错误合同、远端读取和编码接口均由本项目重新设计并以测试固定。

## 样本与保存位置

- IPA SHA-256：`964c1df87cc55b0c5c5b350c281ce6242a8c3ee3688a89c8f986ac4529f7eda1`
- 主程序 SHA-256：`1ba8ad02d9a9252511e3c92f8e83e33cb357ea59914dfb30b909e32b89098bf2`
- Bundle/build：`com.firecore.infuse`，8.5.1 / 8.5.5726
- 主程序：arm64 Mach-O，`cryptid=0`
- 保留工作区：[`debug-infuse/infuse-ios-8.5.1`](../../../debug-infuse/infuse-ios-8.5.1/README.md)

工作区保留完整 IPA 展开结果、strings、symbols、load commands、Objective-C metadata、方法定位表和反汇编片段，约 1.6 GiB。`extracted/` 与 `analysis/` 默认不提交 Git，但不会由项目清理脚本删除。

## 静态证据

主程序直接链接/引用 libavformat、libavcodec、libavutil、libswscale、VideoToolbox、CoreVideo、ImageIO，以及 UIKit 的 PNG/JPEG 表达能力。Objective-C selector 与 IMP 定位得到以下关键入口：

| 类 | selector | IMP |
|---|---|---:|
| `FCDecoderFactory` | `decoderForThumbnailGenerationWithDescriptor:` | `0x10007e834` |
| `FCSoftwareDecoder` | `decoderForThumbnailGeneration` | `0x10015c24c` |
| `FCSoftwareDecoder` | `postProcessCurrentFrameIntoPicture:` | `0x10015cde8` |
| `FCVideoPictureFactory` | `createPictureFromPixelBuffer:format:dts:pts:bufferItem:` | `0x1001d01b4` |
| `FCVTHardwareDecoder` | `addPictureWithPixelBuffer:dts:pts:contentLightMetadata:` | `0x10012e9a4` |
| `FCMediaPlayer` | `showCurrentFrame` | `0x1000d1ad0` |
| `MetalAmbientRenderer` | `captureFramebuffer:in:` | `0x100b5bf74` |

前五项共同说明媒体缩略图存在独立 decoder 工厂、软件/硬件解码和 pixel-buffer picture 工厂。`captureFramebuffer:in:` 属于 Metal ambient renderer 的渲染捕获入口，不能据此推断普通媒体缩略图总是从最终 UI framebuffer 读取。

## 对 SDK 的映射

SDK 的首版实现位于：

- `CStellarFFmpegScreenshot`：libavformat 打开/seek，libavcodec 解码，libswscale 转 BGRA8；
- `StellarMediaImaging`：请求校验、Swift cancellation、远端暂存、ImageIO PNG/JPEG 编码；
- `FFmpegMediaScreenshotGenerator`：本地文件与任意 `MediaSourceSession` 的公共入口。

时间点按毫秒输入。decoder 从目标时间之前的关键帧开始解码，返回目标时间点或之后的第一帧；最大像素边可选，并保持像素宽高比。FFmpegKit 固定构建没有启用 image muxer/PNG/JPEG encoder，因此没有走 CLI 输出文件，而是直接消费 libav 解码帧。这也减少了命令行全局状态和凭据泄漏面。

远端媒体首版通过来源无关的 range-read seam 以 4 MiB 块暂存到系统临时文件，随后复用本地路径。它不会生成带 SMB 用户名/密码的 URL。正常、错误和取消退出都会清理临时文件。

## 已知差距

- 远端文件目前需要完整暂存；下一步应实现基于 `MediaSourceSession` 的 seekable custom AVIO/cache。
- 当前没有应用 container display matrix、sample aspect ratio 校正和 HDR tone mapping。
- 还需要真实 H.264/H.265、旋转视频、VFR、HDR、损坏输入和超长 GOP fixture。
- 静态分析无法证明 Infuse 的精确 seek 容差、缩放 filter、色彩管理或硬件/软件 fallback 权重；这些不应被描述为已复刻。

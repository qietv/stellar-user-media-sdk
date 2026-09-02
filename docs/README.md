# 文档索引

## 架构

- [架构总览](architecture/overview.md)：模块、依赖方向、数据流和平台边界。
- [原生三端 + 公共合同决策](decisions/0001-native-sdks-shared-contracts.md)：为何暂不使用共享运行时。
- [第三方凭据同步决策](decisions/0005-synced-credential-storage.md)：v1 如何在无额外用户操作的前提下同步明文凭据，并预留未来保护模式升级。
- [AMSMB2、FFmpegKit 与截图架构决策](decisions/0006-amsmb2-ffmpegkit-and-screenshot.md)：第三方依赖固定、SMB adapter、解码帧截图与初版远端暂存边界。
- [安全基线](security.md)：OAuth、当前明文远程凭据、日志、网络和本地数据要求。
- [路线图](roadmap.md)：从项目骨架到稳定 SDK 的阶段计划。
- [Swift Reference Implementation Plan](plans/swift-reference-implementation.md)：Swift-first 实施顺序、Linux libsmb2 验收、测试门禁和 iOS 集成。
- [StellarSync Backend Requirements v1](plans/stellar-sync-backend-requirements.md)：来源配置与第三方凭据同步的后端 API、幂等、冲突、安全和验收要求。

## 规范

规范位于 [`specs/`](../specs/README.md)，是 Swift、Android 和 OHOS 实现之间的共同合同。研究文档不能替代规范；研究结论需要先转化为公开、可测试的合同，才能进入生产代码。

## 研究资料

- [Infuse 行为研究和讨论总结](research/infuse/README.md)

研究资料用于理解成熟媒体库产品的行为边界。生产实现必须保持 clean-room，只依赖公开协议、官方文档和本仓库重新设计的模型。

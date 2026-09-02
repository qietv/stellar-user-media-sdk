# ADR-0007：项目范围收紧为 Apple 平台

状态：已接受
日期：2026-09-02
取代：[ADR-0001](0001-native-sdks-shared-contracts.md) 中的多平台实现决策

## 背景

仓库早期把 Swift SDK 同时作为非 Apple reference implementation，并预留 Android 与
OpenHarmony 实现。这要求维护 Foundation overlay fallback、非 Apple 条件编译、额外 CI
矩阵和多语言占位结构，但当前产品只会交付 Apple 客户端。继续保留这些路径会让未验收的平台
看起来像受支持目标，也会限制 Apple framework 的直接使用。

## 决策

1. 本项目只支持 iOS/iPadOS 17、macOS 14 与 tvOS 17。
2. SwiftPM 清单只允许在 macOS 宿主上解析，Apple dependencies、targets 和 products 直接
   声明，不再通过宿主操作系统条件隐藏。
3. 删除非 Apple Foundation/Glibc fallback、Ubuntu Swift CI、portable-import guard 和非
   Apple CLI 分支。
4. 删除 Android/OpenHarmony 平台与示例占位目录；它们不再属于当前路线图。
5. `specs/` 继续作为 Apple SDK 与 Stellar 服务端之间的稳定 wire、SQLite 和行为合同，
   fixture 仍用于兼容性回归，但不再承诺多语言实现。
6. 历史 ADR 与 clean-room 研究资料继续保留并明确标注历史语境，不作为当前平台承诺。

## 结果

- Apple framework 可以在相关 target 中直接导入；
- CI 与发布门禁只覆盖 Apple 工具链和 Apple destinations；
- 非 Apple 主机运行 SwiftPM 会以明确的 unsupported message 失败；
- 若未来新增平台，必须先通过新的 ADR 定义产品范围、API、依赖与完整验收矩阵。

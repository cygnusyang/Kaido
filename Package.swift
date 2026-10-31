// swift-tools-version:5.9
import PackageDescription

// macOS 应用与 GUI 测试仅在 macOS 主机参与构建；Linux CI 只验证核心与接口层（ADR-004）。
#if os(macOS)
let macOSAppTargets: [Target] = [
    // OTA 通用更新模块（Security/CryptoKit 依赖 → 仅 Apple 平台）
    .target(
        name: "KaidoUpdater",
        path: "Sources/KaidoUpdater"
    ),
    // macOS SwiftUI 应用（import KaidoCore；经 KaidoCommands 命令层实现 .kaido 读写）
    // 互操作入口（14 §2）同样落在这一层：适配器按 capability 取用，UI 不认识具体格式的解析细节。
    .executableTarget(
        name: "KaidoMacApp",
        dependencies: [
            "KaidoCore", "KaidoCommands", "KaidoPresentation", "KaidoUpdater",
            "KaidoInterop", "InteropMSPDI", "InteropOmniPlan",
        ],
        path: "Apps/macos/Sources"
    ),
    // 应用层（GUI）测试：视图渲染、门面状态与键盘交互
    .testTarget(
        name: "AppTests",
        dependencies: [
            "KaidoMacApp", "KaidoCore", "KaidoCommands", "KaidoPresentation", "KaidoUpdater",
            "KaidoInterop", "InteropMSPDI", "InteropOmniPlan",
        ],
        path: "Tests/AppTests"
    ),
    // OTA 更新模块测试（验签/版本比较/状态机/白名单/安装脚本）
    .testTarget(
        name: "KaidoUpdaterTests",
        dependencies: ["KaidoUpdater"],
        path: "Tests/KaidoUpdaterTests"
    )
]

// KaidoUpdater 产品仅在 Apple 平台导出（Security 框架依赖，Linux CI 不参与）。
let updaterProduct: [Product] = [.library(name: "KaidoUpdater", targets: ["KaidoUpdater"])]

// OmniPlan .oplx 通道：解压用 Compression framework（raw deflate），Linux 无此模块，
// 故整块按 canImport 条件包含——Linux CI 不构建它，也就不为它装任何三方 zip 依赖。
// 依赖只有 KaidoInterop（14 §2 硬规则 1/2）：不 import InteropMSPDI、不 import KaidoCore。
let omniPlanTargets: [Target] = [
    .target(
        name: "InteropOmniPlan",
        dependencies: ["KaidoInterop"],
        path: "Sources/InteropOmniPlan"
    ),
    // 独立测试 target：只依赖本通道 + IR（多一个 KaidoCore 仅为桥接后的项目形态断言），
    // 从 manifest 层面证明「删掉 InteropMSPDI 时本通道仍能编译并全绿」。
    .testTarget(
        name: "InteropOmniPlanTests",
        dependencies: ["InteropOmniPlan", "KaidoInterop", "KaidoCore"],
        path: "Tests/InteropOmniPlanTests"
    )
]
let omniPlanProducts: [Product] = [.library(name: "InteropOmniPlan", targets: ["InteropOmniPlan"])]
#else
let macOSAppTargets: [Target] = []
let updaterProduct: [Product] = []
let omniPlanTargets: [Target] = []
let omniPlanProducts: [Product] = []
#endif

let package = Package(
    name: "Kaido",
    platforms: [
        .macOS(.v14),
        .iOS(.v17)
    ],
    products: [
        // 显式库产品：为 UI / CLI / MCP 之外的复用（如 iPadOS 壳）保留稳定入口。
        .library(name: "KaidoCore", targets: ["KaidoCore"]),
        .library(name: "KaidoCommands", targets: ["KaidoCommands"]),
        .library(name: "KaidoPresentation", targets: ["KaidoPresentation"]),
        // 互操作 IR 与适配器契约（ADR-014：格式通道互相独立，UI/CLI/MCP 只认 capability）
        .library(name: "KaidoInterop", targets: ["KaidoInterop"]),
        // MS Project XML（MSPDI）通道：只依赖 KaidoInterop，不 import KaidoCore
        .library(name: "InteropMSPDI", targets: ["InteropMSPDI"])
    ] + updaterProduct + omniPlanProducts,
    targets: [
        // 跨平台核心（纯逻辑，ADR-004：零 AppKit/SwiftUI/Combine import）
        .target(
            name: "KaidoCore",
            path: "Sources/KaidoCore"
        ),
        // MCP/CLI 共享命令层（ADR-005 契约同源）
        .target(
            name: "KaidoCommands",
            dependencies: ["KaidoCore"],
            path: "Sources/KaidoCommands"
        ),
        // 平台中立呈现层（ADR-013）：视图状态 → 快照 + 动作；不得 import SwiftUI/AppKit/Combine
        .target(
            name: "KaidoPresentation",
            dependencies: ["KaidoCore", "KaidoCommands"],
            path: "Sources/KaidoPresentation"
        ),
        // 互操作 IR：供应商无关文档模型 + 有损登记 + 适配器协议 + Kaido 桥接（ADR-014）
        .target(
            name: "KaidoInterop",
            dependencies: ["KaidoCore"],
            path: "Sources/KaidoInterop"
        ),
        // MSPDI 适配器：只依赖 KaidoInterop（硬规则 1/2：适配器之间零依赖、不碰 KaidoCore 业务模型）
        .target(
            name: "InteropMSPDI",
            dependencies: ["KaidoInterop"],
            path: "Sources/InteropMSPDI"
        ),
        // MCP 服务（stdio JSON-RPC，复用 KaidoCore + KaidoCommands）
        .executableTarget(
            name: "KaidoMCP",
            dependencies: ["KaidoCore", "KaidoCommands"],
            path: "Sources/KaidoMCP"
        ),
        // CLI（复用 KaidoCore + KaidoCommands；从 MCP 契约派生命令）
        .executableTarget(
            name: "KaidoCLI",
            dependencies: ["KaidoCore", "KaidoCommands"],
            path: "Sources/KaidoCLI"
        ),
        // 核心全量单测（现有 17 项迁入；状态回写/资源 CRUD 走命令层 KaidoSession，故含 KaidoCommands）
        .testTarget(
            name: "KaidoCoreTests",
            dependencies: ["KaidoCore", "KaidoCommands"],
            path: "Tests/KaidoCoreTests"
        ),
        // 呈现层快照与 Presenter 纯函数测试（ADR-013）
        .testTarget(
            name: "KaidoPresentationTests",
            dependencies: ["KaidoPresentation", "KaidoCore", "KaidoCommands"],
            path: "Tests/KaidoPresentationTests"
        ),
        // 互操作契约测试：同一套 AdapterConformanceSuite 跑每个适配器（硬规则 4）
        .testTarget(
            name: "InteropTests",
            dependencies: ["KaidoInterop", "InteropMSPDI", "KaidoCore"],
            path: "Tests/InteropTests"
        ),
        // MCP/CLI 对等性契约测试（US-E5-05）
        .testTarget(
            name: "InterfaceTests",
            dependencies: ["KaidoCore", "KaidoCommands", "KaidoMCP", "KaidoCLI"],
            path: "Tests/InterfaceTests"
        )
    ] + macOSAppTargets + omniPlanTargets
)

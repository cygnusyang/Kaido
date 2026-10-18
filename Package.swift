// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "Kairo",
    platforms: [
        .macOS(.v14)
    ],
    targets: [
        // 跨平台核心（纯逻辑，ADR-004：零 AppKit/SwiftUI/Combine import）
        .target(
            name: "KairoCore",
            path: "Sources/KairoCore"
        ),
        // macOS SwiftUI 应用（import KairoCore；经 KairoCommands 命令层实现 .kairo 读写）
        .executableTarget(
            name: "KairoMacApp",
            dependencies: ["KairoCore", "KairoCommands"],
            path: "Apps/macos/Sources"
        ),
        // MCP/CLI 共享命令层（ADR-005 契约同源）
        .target(
            name: "KairoCommands",
            dependencies: ["KairoCore"],
            path: "Sources/KairoCommands"
        ),
        // MCP 服务（stdio JSON-RPC，复用 KairoCore + KairoCommands）
        .executableTarget(
            name: "KairoMCP",
            dependencies: ["KairoCore", "KairoCommands"],
            path: "Sources/KairoMCP"
        ),
        // CLI（复用 KairoCore + KairoCommands；从 MCP 契约派生命令）
        .executableTarget(
            name: "KairoCLI",
            dependencies: ["KairoCore", "KairoCommands"],
            path: "Sources/KairoCLI"
        ),
        // 核心全量单测（现有 17 项迁入；状态回写/资源 CRUD 走命令层 KairoSession，故含 KairoCommands）
        .testTarget(
            name: "KairoCoreTests",
            dependencies: ["KairoCore", "KairoCommands"],
            path: "Tests/KairoCoreTests"
        ),
        // MCP/CLI 对等性契约测试（US-E5-05）
        .testTarget(
            name: "InterfaceTests",
            dependencies: ["KairoCore", "KairoCommands", "KairoMCP", "KairoCLI"],
            path: "Tests/InterfaceTests"
        )
    ]
)

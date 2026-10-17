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
        // macOS SwiftUI 应用（import KairoCore）
        .executableTarget(
            name: "KairoMacApp",
            dependencies: ["KairoCore"],
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
        // 核心全量单测（现有 17 项迁入）
        .testTarget(
            name: "KairoCoreTests",
            dependencies: ["KairoCore"],
            path: "Tests/KairoCoreTests"
        ),
        // MCP/CLI 对等性契约测试（US-E5-05）
        .testTarget(
            name: "InterfaceTests",
            dependencies: ["KairoCore"],
            path: "Tests/InterfaceTests"
        )
    ]
)

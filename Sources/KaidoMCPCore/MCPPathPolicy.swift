import Foundation

/// MCP 工具的路径准入策略。
///
/// 官网直装版没有沙盒，任何路径都通（默认 `AllowAllPaths`）。
/// App Store 版由 app 注入白名单：只有用户在应用内显式授权的目录下才可读写。
/// 沙盒本身也会拦住越界访问，但底层报的是「文件不存在」——那会让人以为路径写错了。
/// 在这里先判一次，返回可读的「未授权」。
public protocol MCPPathPolicy: Sendable {
    /// 是否允许该路径参与读写。
    func allows(_ url: URL) -> Bool
}

/// 不做任何限制（官网版 / 测试默认）。
public struct AllowAllPaths: MCPPathPolicy {
    public init() {}
    public func allows(_ url: URL) -> Bool { true }
}

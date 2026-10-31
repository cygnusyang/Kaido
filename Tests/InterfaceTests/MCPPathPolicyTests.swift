import Foundation
import Testing
@testable import KaidoMCPCore

/// MCP 路径准入（App Store 沙盒版）：工具只能碰用户授权目录。
@Suite("MCP 路径准入")
struct MCPPathPolicyTests {
    private struct DenyAll: MCPPathPolicy {
        func allows(_ url: URL) -> Bool { false }
    }

    private struct AllowPrefix: MCPPathPolicy {
        let prefix: String
        func allows(_ url: URL) -> Bool { url.path.hasPrefix(prefix) }
    }

    @Test func deniedPathFailsWithDedicatedReason() throws {
        let server = MCPServer(pathPolicy: DenyAll())
        let response = try #require(server.handle(requestJSON: """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_open","arguments":{"path":"/tmp/not-authorized.kaido"}}}
        """))
        #expect(response.contains("mcp_path_not_authorized"))
        #expect(response.contains("\"isError\":true"))
    }

    @Test func authorizedPathReachesTheTool() throws {
        let server = MCPServer(pathPolicy: AllowPrefix(prefix: "/tmp"))
        let response = try #require(server.handle(requestJSON: """
        {"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_open","arguments":{"path":"/tmp/does-not-exist.kaido"}}}
        """))
        // 放行后由工具自己报「文件不存在」，错误原因不再是准入拦截。
        #expect(!response.contains("mcp_path_not_authorized"))
    }

    @Test func toolsWithoutPathAreUnaffected() throws {
        let server = MCPServer(pathPolicy: DenyAll())
        let response = try #require(server.handle(requestJSON: #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#))
        #expect(response.contains("project_open"))
        #expect(!response.contains("mcp_path_not_authorized"))
    }
}

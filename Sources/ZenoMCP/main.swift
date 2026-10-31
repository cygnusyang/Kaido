import Foundation

// ZenoMCP：stdio JSON-RPC 2.0 服务（ADR-010，零第三方依赖）。
// 逐行读 stdin，逐行写 stdout（每行一条 JSON-RPC 消息，MCP stdio 传输）。
let server = MCPServer()

while let line = readLine() {
    guard let response = server.handle(requestJSON: line) else { continue }
    print(response)
    fflush(stdout)
}

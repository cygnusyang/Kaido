import Foundation
import Testing
@testable import KairoMCP

// 接口对等性契约测试（US-E5-05）：MCP 侧 JSON-RPC 编解码与工具往返。
// CLI 侧路由测试见 CLITests.swift。

/// 发送一行请求并解析响应为 JSONValue。
private func send(_ server: MCPServer, _ json: String) throws -> JSONValue {
    let response = server.handle(requestJSON: json)!
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
}

/// 取出 tools/call 的 result.content[0].text，并解析为 JSONValue。
private func toolResult(_ value: JSONValue) throws -> JSONValue {
    let content = value.objectValue?["result"]?.objectValue?["content"]?.arrayValue ?? []
    let text = content.first?.objectValue?["text"]?.stringValue ?? "{}"
    return try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
}

// MARK: - initialize 握手

@Test func initializeHandshakeReturnsProtocolAndServerInfo() throws {
    let server = MCPServer()
    let response = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"测试"}}}"#
    )
    #expect(response.objectValue?["id"] == .number(1))
    let result = response.objectValue?["result"]?.objectValue
    #expect(result?["protocolVersion"]?.stringValue == "2024-11-05")
    #expect(result?["serverInfo"]?.objectValue?["name"]?.stringValue == "kairo")
    #expect(result?["capabilities"]?.objectValue?["tools"] != nil)
}

// MARK: - tools/list schema

@Test func toolsListReturnsSprint1ToolSetWithSchema() throws {
    let server = MCPServer()
    let response = try send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = response.objectValue?["result"]?.objectValue?["tools"]?.arrayValue ?? []
    let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
    #expect(names == [
        "project_create", "project_open", "project_save",
        "task_add", "task_list", "task_get", "task_update", "task_delete",
        "wbs_import",
    ])
    #expect(tools.allSatisfy { $0.objectValue?["inputSchema"]?.objectValue?["type"]?.stringValue == "object" })
    let taskAdd = tools.first { $0.objectValue?["name"]?.stringValue == "task_add" }
    #expect(taskAdd?.objectValue?["inputSchema"]?.objectValue?["required"]?.arrayValue?.first?.stringValue == "title")
}

// MARK: - tools/call 往返

@Test func taskAddThenTaskListRoundTrip() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"演示项目"}}}"#
    )
    let addResponse = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"任务 A","kind":"group"}}}"#
    )
    let taskID = try toolResult(addResponse).objectValue?["taskID"]?.stringValue
    #expect(taskID != nil)

    let listResponse = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_list","arguments":{}}}"#
    )
    let tasks = try toolResult(listResponse).objectValue?["tasks"]?.arrayValue ?? []
    #expect(tasks.count == 1)
    #expect(tasks.first?.objectValue?["id"]?.stringValue == taskID)
    #expect(tasks.first?.objectValue?["kind"]?.stringValue == "group")
}


// MARK: - 错误契约

@Test func unknownMethodReturnsJSONRPCError() throws {
    let server = MCPServer()
    let response = try send(server, #"{"jsonrpc":"2.0","id":9,"method":"frobnicate"}"#)
    let errorCode = response.objectValue?["error"]?.objectValue?["code"]?.doubleValue
    #expect(errorCode == Double(JSONRPCErrorCode.methodNotFound))
    #expect(response.objectValue?["error"]?.objectValue?["message"]?.stringValue?.contains("未知方法") == true)
}

@Test func toolErrorReturnsIsErrorWithStructuredCode() throws {
    let server = MCPServer()
    // 未打开项目时 task_get 应返回 isError=true + 结构化错误码。
    let response = try send(
        server,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"task_get","arguments":{"taskID":"\#(UUID().uuidString)"}}}"#
    )
    let result = response.objectValue?["result"]?.objectValue
    #expect(result?["isError"]?.boolValue == true)
    let text = result?["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? "{}"
    let failure = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    #expect(failure.objectValue?["code"]?.stringValue == "project_not_open")
    #expect(failure.objectValue?["message"]?.stringValue != nil)
}

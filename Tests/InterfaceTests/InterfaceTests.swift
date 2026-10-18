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

@Test func toolsListReturnsSprint2ToolSetWithSchema() throws {
    let server = MCPServer()
    let response = try send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#)
    let tools = response.objectValue?["result"]?.objectValue?["tools"]?.arrayValue ?? []
    let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
    #expect(names == [
        "project_create", "project_open", "project_save",
        "task_add", "task_list", "task_get", "task_update", "task_delete",
        "wbs_import",
        "schedule_compute", "schedule_critical_path", "violations_list", "status_update",
        "status_batch_update", "resource_add", "resource_list",
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


@Test func taskAddWithDependenciesCreatesFSChain() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"相关性项目","projectStart":"2026-11-02T00:00:00Z"}}}"#
    )
    let a = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"前驱","durationDays":2}}}"#
    )
    let aID = try #require(try toolResult(a).objectValue?["taskID"]?.stringValue)
    let b = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"后继","durationDays":3,"dependencies":[{"predecessorID":"\#(aID)","type":"fs"}]}}}"#
    )
    let bID = try #require(try toolResult(b).objectValue?["taskID"]?.stringValue)

    let get = try send(
        server,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"task_get","arguments":{"taskID":"\#(bID)"}}}"#
    )
    let deps = try toolResult(get).objectValue?["dependencies"]?.arrayValue ?? []
    #expect(deps.count == 1)
    #expect(deps.first?.objectValue?["predecessorID"]?.stringValue == aID)
    #expect(deps.first?.objectValue?["type"]?.stringValue == "fs")

    // 排期传播：后继的开始应等于前驱的结束。
    let schedule = try send(
        server,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"schedule_compute","arguments":{"projectStart":"2026-11-02T00:00:00Z"}}}"#
    )
    let scheduled = try toolResult(schedule).objectValue?["tasks"]?.arrayValue ?? []
    let aEntry = scheduled.first { $0.objectValue?["taskID"]?.stringValue == aID }
    let bEntry = scheduled.first { $0.objectValue?["taskID"]?.stringValue == bID }
    #expect(bEntry?.objectValue?["scheduledStart"]?.stringValue == aEntry?.objectValue?["scheduledFinish"]?.stringValue)
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

@Test func statusBatchUpdateReportsPerTaskSuccessAndFailure() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"批量回写"}}}"#
    )
    let a = try send(server, #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"任务一"}}}"#)
    let aID = try #require(try toolResult(a).objectValue?["taskID"]?.stringValue)
    let b = try send(server, #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"任务二"}}}"#)
    let bID = try #require(try toolResult(b).objectValue?["taskID"]?.stringValue)
    let missing = UUID().uuidString

    let response = try send(
        server,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"status_batch_update","arguments":{"tasks":[{"taskID":"\#(aID)","status":"done"},{"taskID":"\#(bID)","progress":0.5},{"taskID":"\#(missing)","status":"done"}]}}}"#
    )
    let result = try toolResult(response)
    #expect(result.objectValue?["succeeded"]?.doubleValue == 2)
    #expect(result.objectValue?["failed"]?.doubleValue == 1)
    let entries = result.objectValue?["entries"]?.arrayValue ?? []
    #expect(entries.count == 3)
    #expect(entries.last?.objectValue?["ok"]?.boolValue == false)
    #expect(entries.last?.objectValue?["error"]?.stringValue != nil)
}

@Test func resourceAddThenListRoundTrip() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"资源项目"}}}"#
    )
    let add = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"resource_add","arguments":{"name":"李工","kind":"person","units":1,"efficiency":0.9}}}"#
    )
    let id = try #require(try toolResult(add).objectValue?["resourceID"]?.stringValue)
    let list = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"resource_list","arguments":{}}}"#
    )
    let resources = try toolResult(list).objectValue?["resources"]?.arrayValue ?? []
    #expect(resources.count == 1)
    #expect(resources.first?.objectValue?["id"]?.stringValue == id)
    #expect(resources.first?.objectValue?["name"]?.stringValue == "李工")
    #expect(resources.first?.objectValue?["efficiency"]?.doubleValue == 0.9)
}

@Test func taskAssignmentDrivesDurationFromEffort() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"投入换算"}}}"#
    )
    let res = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"resource_add","arguments":{"name":"李工","efficiency":1}}}"#
    )
    let resourceID = try #require(try toolResult(res).objectValue?["resourceID"]?.stringValue)
    let task = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"受分配任务","effortHours":8,"assignments":[{"resourceID":"\#(resourceID)","units":1}]}}}"#
    )
    _ = try #require(try toolResult(task).objectValue?["taskID"]?.stringValue)

    let schedule = try send(
        server,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"schedule_compute","arguments":{"projectStart":"2026-11-02T00:00:00Z"}}}"#
    )
    let scheduled = try toolResult(schedule).objectValue?["tasks"]?.arrayValue ?? []
    // duration = 8h / 8h 每日 / (1 单位 × 100% 效率) = 1 天。
    #expect(scheduled.first?.objectValue?["durationDays"]?.doubleValue == 1)
}

// MARK: - Sprint 2 工具（schedule / violations / status）

@Test func scheduleComputeReportsConstraintConflictThenViolationsList() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"排期项目"}}}"#
    )
    // 任务 A：持续 5 天；任务 B：开始不晚于项目开始后 2 天（D0+2），与前驱冲突。
    let a = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"任务 A","durationDays":5}}}"#
    )
    let aID = try #require(try toolResult(a).objectValue?["taskID"]?.stringValue)
    let b = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"任务 B","durationDays":1,"constraint":"startNoEarlierThan:2026-11-09T00:00:00Z"}}}"#
    )
    _ = try #require(try toolResult(b).objectValue?["taskID"]?.stringValue)

    let schedule = try send(
        server,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"schedule_compute","arguments":{"projectStart":"2026-11-02T00:00:00Z","projectEnd":"2026-11-08T00:00:00Z"}}}"#
    )
    let result = try toolResult(schedule)
    let tasks = result.objectValue?["tasks"]?.arrayValue ?? []
    #expect(tasks.count == 2)
    #expect(tasks.allSatisfy { $0.objectValue?["scheduledStart"]?.stringValue != nil })

    // 任务 A 持续 5 天 → 结束 D0+5（2026-11-07）> 项目结束 D0+6（2026-11-08）？不：D0+5=11-07 < 11-08。任务 B 时限与相关性冲突。
    let violations = try send(
        server,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"violations_list","arguments":{}}}"#
    )
    let vres = try toolResult(violations)
    let vs = vres.objectValue?["violations"]?.arrayValue ?? []
    let vcodes = vs.compactMap { $0.objectValue?["code"]?.stringValue }
    #expect(!vcodes.isEmpty)
    _ = aID
}

@Test func statusUpdateDoneReturnsCompletedAtAndGroupAggregate() throws {
    let server = MCPServer()
    _ = try send(
        server,
        #"{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"project_create","arguments":{"title":"回写项目"}}}"#
    )
    let g = try send(
        server,
        #"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"群组 G","kind":"group"}}}"#
    )
    let gID = try #require(try toolResult(g).objectValue?["taskID"]?.stringValue)
    let c = try send(
        server,
        #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"task_add","arguments":{"title":"子一","parentID":"\#(gID)","effortHours":4}}}"#
    )
    let cID = try #require(try toolResult(c).objectValue?["taskID"]?.stringValue)

    let up = try send(
        server,
        #"{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"status_update","arguments":{"taskID":"\#(cID)","status":"done"}}}"#
    )
    let updated = try toolResult(up)
    #expect(updated.objectValue?["status"]?.stringValue == "done")
    #expect(updated.objectValue?["progress"]?.doubleValue == 1)
    #expect(updated.objectValue?["completedAt"]?.stringValue != nil)

    // 只读查询群组聚合（不传 status/progress）。
    let gread = try send(
        server,
        #"{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"status_update","arguments":{"taskID":"\#(gID)"}}}"#
    )
    let gres = try toolResult(gread)
    #expect(gres.objectValue?["groupProgress"]?.doubleValue == 1)
}

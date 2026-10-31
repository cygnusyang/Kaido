import Foundation
import Testing
import ZenoCore
import ZenoCommands
@testable import ZenoMCP
@testable import ZenoCLI

// v0.16 B2：CLI / MCP 的「已取消」词汇与取消原因（\`cancelled\` + \`cancelReason\`）。
//
// 口径（与 core 侧 B1 同源）：
// - CLI \`status update <id> --status cancelled --reason "…"\`：缺 \`--reason\` 或原因为纯空白
//   必须在会话层之前拦下（用法错误，退出码 2），且任务不被修改；
// - 成功回执带状态与原因；\`task get\` / \`task list\` 文本与 \`--json\` 带 \`cancelReason\`
//   （空值不写键，与既有可空字段一致）；
// - MCP \`status_update\` / \`status_batch_update\` 的 status 枚举含 \`cancelled\`，且增
//   \`cancelReason\`（status == cancelled 必填），缺原因透出 \`model_cancel_reason_required\`；
// - 已取消任务不进 \`schedule compute\` 输出（core 已排除，这里验接口面没有漏出甘特行）。

private let budgetReason = "预算砍掉，本期不做"
private let scopeReason = "范围收缩，移到下一版"

/// 建临时工作目录与 .zeno 路径；调用方用 defer 清理目录。
private func makeScratch() throws -> (dir: URL, zeno: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zeno-cancel-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir: dir, zeno: dir.appendingPathComponent("cancel.zeno"))
}

/// 建项目 + 两个任务，返回（取消目标, 对照组）的 ID。
private func makeProjectWithTwoTasks(in file: URL, titles: (String, String) = ("被砍的任务", "留下的任务")) throws -> (target: UUID, other: UUID) {
    try cliRun(["project", "create", "取消接口", "--file", file.path])
    try cliRun(["task", "add", titles.0, "--file", file.path])
    try cliRun(["task", "add", titles.1, "--file", file.path])
    let project = try ZenoFile.load(from: file)
    let target = try #require(project.tasks.first { $0.title == titles.0 }).id
    let other = try #require(project.tasks.first { $0.title == titles.1 }).id
    return (target: target, other: other)
}

/// 取 CLI 人类输出：注入 emit 收集，语言钉死中文（CI 为英文系统语言，不钉会假红）。
///
/// 为什么不用 `captureStdout`：它靠 dup2 替换进程级 fd 1，只能串行化「同样走 captureStdout」
/// 的用例；并行套件里别的代码直接 print 的字节会混进同一条管道（JSON 断言会直接解码失败）。
/// 注入 emit 不碰 fd，天然与并行无关。
private func cliOutput(_ arguments: [String]) throws -> String {
    var lines: [String] = []
    try CLIRouter.execute(
        arguments: arguments,
        environment: ["ZENO_LANG": "zh-Hans"],
        preferredLanguages: [],
        emit: { lines.append($0) }
    )
    return lines.joined(separator: "\n")
}

/// 静默执行准备步骤（建项目 / 建任务）：不落 fd 1，避免污染其它套件的 stdout 抓取窗口。
private func cliRun(_ arguments: [String]) throws {
    try CLIRouter.execute(
        arguments: arguments,
        environment: ["ZENO_LANG": "zh-Hans"],
        preferredLanguages: [],
        emit: { _ in }
    )
}

// MARK: - MCP 小工具（与 InterfaceTests.swift 同形，避免跨文件依赖 private 符号）

private func mcpSend(_ server: MCPServer, _ json: String) throws -> JSONValue {
    let response = try #require(server.handle(requestJSON: json))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
}

private func mcpCall(_ server: MCPServer, id: Int, tool: String, arguments: String) throws -> (isError: Bool, payload: JSONValue) {
    let response = try mcpSend(
        server,
        "{\"jsonrpc\":\"2.0\",\"id\":\(id),\"method\":\"tools/call\",\"params\":{\"name\":\"\(tool)\",\"arguments\":\(arguments)}}"
    )
    let result = try #require(response.objectValue?["result"]?.objectValue)
    let isError = result["isError"]?.boolValue ?? false
    let text = result["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue ?? "{}"
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    return (isError: isError, payload: payload)
}

// MARK: - CLI：取消写入与回执

@Test func cliStatusUpdateCancelPersistsReasonAndEchoesIt() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)

    // 首尾空白由会话层归一：落盘的是裁剪后的原因。
    let output = try cliOutput([
        "status", "update", ids.target.uuidString,
        "--status", "cancelled",
        "--reason", "  \(budgetReason)  ",
        "--file", scratch.zeno.path,
    ])

    #expect(output.contains("已取消"))
    #expect(output.contains("取消原因：\(budgetReason)"), "成功回执必须带原因，否则用户无从确认砍掉的理由")

    let task = try #require(try ZenoFile.load(from: scratch.zeno).tasks.first { $0.id == ids.target })
    #expect(task.status == .cancelled)
    #expect(task.cancelReason == budgetReason)
    #expect(task.completedAt == nil, "没做完就没有完成时刻")
}

@Test func cliCancelWithoutReasonIsUsageErrorAndLeavesTaskUntouched() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)

    // 缺 --reason 与纯空白原因都属用法错误（2），不能等到会话层才拒。
    let missing = CLIRouter.run(arguments: [
        "status", "update", ids.target.uuidString, "--status", "cancelled", "--file", scratch.zeno.path,
    ])
    #expect(missing == 2, "缺 --reason 必须是用例错误，不该透传到会话层")

    let blank = CLIRouter.run(arguments: [
        "status", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", "   ", "--file", scratch.zeno.path,
    ])
    #expect(blank == 2, "纯空白原因等于没写理由")

    let task = try #require(try ZenoFile.load(from: scratch.zeno).tasks.first { $0.id == ids.target })
    #expect(task.status == .pending, "被拒的取消不得改动任务")
    #expect(task.cancelReason == nil)
}

@Test func cliTaskUpdateRejectsCancelAndPointsToStatusUpdate() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)

    // task update 的写入口不落取消原因：置为 cancelled 一律用法错误，避免出现「无理由终态」。
    #expect(CLIRouter.run(arguments: [
        "task", "update", ids.target.uuidString, "--status", "cancelled", "--file", scratch.zeno.path,
    ]) == 2)

    // 带 --reason 也进不去：该命令没有这个选项，取消只有 status update 一条路。
    #expect(CLIRouter.run(arguments: [
        "task", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", scopeReason, "--file", scratch.zeno.path,
    ]) == 2)

    let task = try #require(try ZenoFile.load(from: scratch.zeno).tasks.first { $0.id == ids.target })
    #expect(task.status == .pending)
    #expect(task.cancelReason == nil)
}

// MARK: - CLI：文本与 --json 输出

@Test func cliTaskGetAndListPrintCancelReason() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)
    try cliRun([
        "status", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", budgetReason, "--file", scratch.zeno.path,
    ])

    let detail = try cliOutput(["task", "get", ids.target.uuidString, "--file", scratch.zeno.path])
    #expect(detail.contains("取消原因：\(budgetReason)"))

    // 未取消的任务不出现「取消原因」行（缺值不占行，与其它可选行同口径）。
    let otherDetail = try cliOutput(["task", "get", ids.other.uuidString, "--file", scratch.zeno.path])
    #expect(!otherDetail.contains("取消原因"))

    let list = try cliOutput(["task", "list", "--file", scratch.zeno.path])
    #expect(list.contains(budgetReason), "列表文本也要能看出为什么砍掉")
}

@Test func cliTaskListJSONOmitsAbsentCancelReasonKey() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)
    try cliRun([
        "status", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", budgetReason, "--file", scratch.zeno.path,
    ])

    let json = try cliOutput(["task", "list", "--json", "--file", scratch.zeno.path])
    let rows = try #require(try JSONDecoder().decode(JSONValue.self, from: Data(json.utf8)).arrayValue)
    let cancelled = try #require(rows.first { $0.objectValue?["id"]?.stringValue == ids.target.uuidString })
    #expect(cancelled.objectValue?["status"]?.stringValue == "cancelled")
    #expect(cancelled.objectValue?["cancelReason"]?.stringValue == budgetReason)

    let kept = try #require(rows.first { $0.objectValue?["id"]?.stringValue == ids.other.uuidString })
    #expect(kept.objectValue?["cancelReason"] == nil, "空原因不写键，与其它可空字段一致")
    #expect(kept.objectValue?.keys.contains("cancelReason") == false)
}

// MARK: - MCP：status_update / status_batch_update / task_get

@Test func mcpStatusUpdateCancelReturnsReasonAndTaskGetAgrees() throws {
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, tool: "project_create", arguments: #"{"title":"取消 MCP"}"#)
    let added = try mcpCall(server, id: 2, tool: "task_add", arguments: #"{"title":"砍掉的任务"}"#)
    let taskID = try #require(added.payload.objectValue?["taskID"]?.stringValue)

    let cancelled = try mcpCall(
        server, id: 3, tool: "status_update",
        arguments: "{\"taskID\":\"\(taskID)\",\"status\":\"cancelled\",\"cancelReason\":\"\(budgetReason)\"}"
    )
    #expect(!cancelled.isError)
    #expect(cancelled.payload.objectValue?["status"]?.stringValue == "cancelled")
    #expect(cancelled.payload.objectValue?["cancelReason"]?.stringValue == budgetReason)

    let fetched = try mcpCall(server, id: 4, tool: "task_get", arguments: "{\"taskID\":\"\(taskID)\"}")
    #expect(fetched.payload.objectValue?["cancelReason"]?.stringValue == budgetReason)
    #expect(fetched.payload.objectValue?["status"]?.stringValue == "cancelled")
}

@Test func mcpCancelWithoutReasonReportsCancelReasonRequiredCode() throws {
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, tool: "project_create", arguments: #"{"title":"缺原因 MCP"}"#)
    let added = try mcpCall(server, id: 2, tool: "task_add", arguments: #"{"title":"缺原因任务"}"#)
    let taskID = try #require(added.payload.objectValue?["taskID"]?.stringValue)

    let code = ZenoErrorCode.cancelReasonRequired.rawValue
    #expect(code == "model_cancel_reason_required", "细码是冻结契约，改动会破坏按码匹配的消费者")

    for (index, arguments) in [
        "{\"taskID\":\"\(taskID)\",\"status\":\"cancelled\"}",
        "{\"taskID\":\"\(taskID)\",\"status\":\"cancelled\",\"cancelReason\":\"  \"}",
    ].enumerated() {
        let failure = try mcpCall(server, id: 10 + index, tool: "status_update", arguments: arguments)
        #expect(failure.isError)
        #expect(failure.payload.objectValue?["code"]?.stringValue == "invalid_argument")
        #expect(failure.payload.objectValue?["reason"]?.stringValue == code)
    }

    // 被拒后任务原样未动。
    let fetched = try mcpCall(server, id: 20, tool: "task_get", arguments: "{\"taskID\":\"\(taskID)\"}")
    #expect(fetched.payload.objectValue?["status"]?.stringValue == "pending")
    #expect(fetched.payload.objectValue?["cancelReason"] == nil)
}

@Test func mcpStatusBatchCancelRequiresReasonAndCarriesIt() throws {
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, tool: "project_create", arguments: #"{"title":"批量取消"}"#)
    let added = try mcpCall(server, id: 2, tool: "task_add", arguments: #"{"title":"批量砍掉的任务"}"#)
    let taskID = try #require(added.payload.objectValue?["taskID"]?.stringValue)

    // 缺原因：整请求拒绝并透出与单条相同的细码（批次条目无法承载错误码，只能请求级失败）。
    let missing = try mcpCall(
        server, id: 3, tool: "status_batch_update",
        arguments: "{\"tasks\":[{\"taskID\":\"\(taskID)\",\"status\":\"cancelled\"}]}"
    )
    #expect(missing.isError)
    #expect(missing.payload.objectValue?["reason"]?.stringValue == ZenoErrorCode.cancelReasonRequired.rawValue)

    let ok = try mcpCall(
        server, id: 4, tool: "status_batch_update",
        arguments: "{\"tasks\":[{\"taskID\":\"\(taskID)\",\"status\":\"cancelled\",\"cancelReason\":\"\(scopeReason)\"}]}"
    )
    #expect(!ok.isError)
    let entry = try #require(ok.payload.objectValue?["entries"]?.arrayValue?.first)
    #expect(entry.objectValue?["ok"]?.boolValue == true)
    #expect(entry.objectValue?["task"]?.objectValue?["cancelReason"]?.stringValue == scopeReason)
}

// MARK: - 对等性：同一任务两边读写同一份原因

@Test func cliAndMCPCancelAgreeOnReason() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno)

    // CLI 写 → MCP 读。
    try cliRun([
        "status", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", budgetReason, "--file", scratch.zeno.path,
    ])
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, tool: "project_open", arguments: "{\"path\":\"\(scratch.zeno.path)\"}")
    let fromMCP = try mcpCall(server, id: 2, tool: "task_get", arguments: "{\"taskID\":\"\(ids.target.uuidString)\"}")
    #expect(fromMCP.payload.objectValue?["cancelReason"]?.stringValue == budgetReason)

    // MCP 改原因 → 落盘 → CLI 读。
    let updated = try mcpCall(
        server, id: 3, tool: "status_update",
        arguments: "{\"taskID\":\"\(ids.target.uuidString)\",\"status\":\"cancelled\",\"cancelReason\":\"\(scopeReason)\"}"
    )
    #expect(!updated.isError)
    _ = try mcpCall(server, id: 4, tool: "project_save", arguments: "{}")

    let saved = try #require(try ZenoFile.load(from: scratch.zeno).tasks.first { $0.id == ids.target })
    #expect(saved.cancelReason == scopeReason)
    let detail = try cliOutput(["task", "get", ids.target.uuidString, "--file", scratch.zeno.path])
    #expect(detail.contains("取消原因：\(scopeReason)"))
}

// MARK: - 已取消任务不进排期输出

@Test func cancelledTaskIsAbsentFromScheduleComputeOnBothInterfaces() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    // 专用标题：并行用例都往同一 fd 打印，按标题断言才不会被别人的输出带跑。
    let ids = try makeProjectWithTwoTasks(in: scratch.zeno, titles: ("砍掉的排期任务", "留下的排期任务"))
    try cliRun([
        "status", "update", ids.target.uuidString, "--status", "cancelled",
        "--reason", budgetReason, "--file", scratch.zeno.path,
    ])

    let output = try cliOutput(["schedule", "compute", "--file", scratch.zeno.path])
    // 排期行的形状是「  <短ID> <标题>  <开始> → <结束>（…）」：按「含 → 的行」判定甘特条目。
    let scheduleRows = output.split(separator: "\n").filter { $0.contains("→") }
    #expect(scheduleRows.contains { $0.contains("留下的排期任务") }, "对照组必须出现在排期里")
    #expect(!scheduleRows.contains { $0.contains("砍掉的排期任务") }, "已取消任务不该有甘特行")

    let server = MCPServer()
    _ = try mcpCall(server, id: 1, tool: "project_open", arguments: "{\"path\":\"\(scratch.zeno.path)\"}")
    let computed = try mcpCall(server, id: 2, tool: "schedule_compute", arguments: "{}")
    let rows = try #require(computed.payload.objectValue?["tasks"]?.arrayValue)
    let scheduledIDs = rows.compactMap { $0.objectValue?["taskID"]?.stringValue }
    #expect(scheduledIDs.contains(ids.other.uuidString))
    #expect(!scheduledIDs.contains(ids.target.uuidString), "MCP 排期结果同样不含已取消任务")
}

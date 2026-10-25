import Foundation
import Testing
import KairoCore
import KairoCommands
@testable import KairoMCP
@testable import KairoCLI

// 判据 6 / 12（docs/features/08-baselines.md §9-6 / §9-12）：
// - 任何偏差输出都带 baselineID / name / createdAt；
// - CLI 与 MCP 的偏差数值与 BaselineEngine.variance 逐字段一致（对等性门禁）。
//
// 口径：
// - 空值一律省略键，不写 0（0 = 准时，与「无数据」语义不同）；
// - 基线结束日在远期（2030 年）→ overdueDays 恒为 0 或 nil，用例不受运行日期影响；
// - 语言显式钉死 zh-Hans（CI 为英文系统语言，不钉会因标签语言不同而假红）。

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

/// 建临时工作目录与 .kairo 路径；调用方用 defer 清理目录。
private func makeScratch() throws -> (dir: URL, kairo: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-baseline-interface-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir: dir, kairo: dir.appendingPathComponent("baseline.kairo"))
}

/// 跑一条 CLI 命令并捕获 stdout（语言钉死 zh-Hans）。
private func runCLI(_ arguments: [String]) throws -> String {
    try captureStdout {
        try CLIRouter.execute(
            arguments: arguments,
            environment: ["KAIRO_LANG": "zh-Hans"],
            preferredLanguages: []
        )
    }
}

/// 跑一条 CLI 命令，把 --json 输出的最后一行解析为 JSONValue。
private func runCLIJSON(_ arguments: [String]) throws -> JSONValue {
    let text = try runCLI(arguments)
    let payload = try #require(text.split(separator: "\n").last.map(String.init))
    return try JSONDecoder().decode(JSONValue.self, from: Data(payload.utf8))
}

/// 发一条 JSON-RPC 请求，返回完整响应。
private func mcpSend(_ server: MCPServer, _ json: String) throws -> JSONValue {
    let response = try #require(server.handle(requestJSON: json))
    return try JSONDecoder().decode(JSONValue.self, from: Data(response.utf8))
}

/// 调一个 MCP 工具并返回 (isError, 载荷)。
private func mcpCallResult(
    _ server: MCPServer, id: Int, name: String, arguments: String
) throws -> (isError: Bool, payload: JSONValue) {
    let request = #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"\#(name)","arguments":\#(arguments)}}"#
    let response = try mcpSend(server, request)
    let result = try #require(response.objectValue?["result"]?.objectValue)
    let content = result["content"]?.arrayValue ?? []
    let text = content.first?.objectValue?["text"]?.stringValue ?? "{}"
    let payload = try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8))
    return (isError: result["isError"]?.boolValue ?? false, payload: payload)
}

/// 只取载荷的成功路径（失败时由用例自行断言 isError）。
private func mcpCall(_ server: MCPServer, id: Int, name: String, arguments: String) throws -> JSONValue {
    try mcpCallResult(server, id: id, name: name, arguments: arguments).payload
}

/// 对等性夹具：一条已基线、随后计划推迟 3 天并已完成（实际提前 1 天）的任务；
/// 一条保持开放的已基线任务；一条被删除（孤儿）；一条基线之后新增。
private struct BaselineFixture {
    let dir: URL
    let file: URL
    let baseline: Baseline
    let rescheduledTaskID: UUID
    let openTaskID: UUID
    let orphanTaskID: UUID
    let addedTaskID: UUID
}

private func makeFixture() throws -> BaselineFixture {
    let scratch = try makeScratch()
    let file = scratch.kairo
    try CLIRouter.execute(arguments: [
        "project", "create", "基线接口夹具", "--start", "2030-01-01", "--end", "2030-02-01",
        "--file", file.path,
    ])
    for title in ["任务甲", "任务乙", "任务丙"] {
        try CLIRouter.execute(arguments: ["task", "add", title, "--duration", "2", "--file", file.path])
    }
    try CLIRouter.execute(arguments: ["baseline", "create", "--name", "基线甲", "--file", file.path])

    let afterCreate = try KairoFile.load(from: file)
    let baseline = try #require(afterCreate.baselines.first)
    let ids = Dictionary(uniqueKeysWithValues: afterCreate.tasks.map { ($0.title, $0.id) })
    let rescheduledID = try #require(ids["任务甲"])
    let openID = try #require(ids["任务乙"])
    let orphanID = try #require(ids["任务丙"])
    let entry = try #require(baseline.entry(for: rescheduledID))
    let baselineSpan = CalendarDayMath.dayOffset(
        from: entry.start, to: entry.finish, calendar: utcCalendar
    )

    // 基线与计划脱钩：计划工期 +3 天；实际提前 1 天完成；丙被删（孤儿）；丁在基线之后新增。
    let session = KairoSession()
    _ = try session.openProject(at: file)
    _ = try session.updateTask(id: rescheduledID, durationDays: Double(baselineSpan + 3))
    _ = try session.setActualStart(id: rescheduledID, date: entry.start)
    _ = try session.setActualFinish(id: rescheduledID, date: entry.finish.addingTimeInterval(-86_400))
    _ = try session.deleteTaskCascade(id: orphanID)
    let addedID = try session.addTask(title: "任务丁", durationDays: 1)
    try session.saveProject()

    return BaselineFixture(
        dir: scratch.dir,
        file: file,
        baseline: baseline,
        rescheduledTaskID: rescheduledID,
        openTaskID: openID,
        orphanTaskID: orphanID,
        addedTaskID: addedID
    )
}

/// 引擎直算报告（对等性基准）。时钟与接口层同为运行时刻；逾期恒为 0 故与时钟无关。
private func engineReport(_ fixture: BaselineFixture) throws -> BaselineVarianceReport {
    let session = KairoSession()
    _ = try session.openProject(at: fixture.file)
    let project = try #require(session.project)
    let result = try session.computeSchedule()
    return BaselineEngine.variance(
        baseline: fixture.baseline,
        tasks: project.tasks,
        schedules: BaselineEngine.scheduleIndex(from: result),
        now: Date()
    )
}

/// 逐字段比对一条任务偏差（缺值 = 键不存在，不得写 0）。
private func expectRowMatches(
    _ row: JSONValue,
    _ expected: TaskVariance,
    source: String
) {
    let object = row.objectValue ?? [:]
    #expect(object["taskID"]?.stringValue == expected.taskID.uuidString, "\(source): taskID")
    #expect(object["hasBaseline"]?.boolValue == expected.hasBaseline, "\(source): hasBaseline")
    #expect(object["isForecast"]?.boolValue == expected.isForecast, "\(source): isForecast")

    let intFields: [(String, Int?)] = [
        ("planStartVariance", expected.planStartVariance),
        ("planFinishVariance", expected.planFinishVariance),
        ("actualStartVariance", expected.actualStartVariance),
        ("actualFinishVariance", expected.actualFinishVariance),
        ("overdueDays", expected.overdueDays),
        ("durationVariance", expected.durationVariance),
    ]
    for (key, value) in intFields {
        guard let value else {
            #expect(object[key] == nil, "\(source): \(key) 为空时不得写出键（更不能写 0）")
            continue
        }
        #expect(object[key]?.doubleValue == Double(value), "\(source): \(key) 数值不一致")
    }

    let dateFields: [(String, Date?)] = [
        ("baselineStart", expected.baselineStart),
        ("baselineFinish", expected.baselineFinish),
    ]
    for (key, value) in dateFields {
        guard let value else {
            #expect(object[key] == nil, "\(source): \(key) 为空时不得写出键")
            continue
        }
        let expectedISO = ISO8601DateFormatter().string(from: value)
        #expect(object[key]?.stringValue == expectedISO, "\(source): \(key) 日期不一致")
    }
}

/// 逐字段比对整个报告的身份字段与聚合字段。
private func expectReportMatches(_ report: JSONValue, _ expected: BaselineVarianceReport, source: String) {
    let object = report.objectValue ?? [:]
    #expect(object["baselineID"]?.stringValue == expected.baselineID.uuidString, "\(source): baselineID")
    #expect(object["baselineName"]?.stringValue == expected.baselineName, "\(source): baselineName")
    #expect(
        object["baselineCreatedAt"]?.stringValue == ISO8601DateFormatter().string(from: expected.baselineCreatedAt),
        "\(source): baselineCreatedAt"
    )
    #expect(object["lateTaskCount"]?.doubleValue == Double(expected.lateTaskCount), "\(source): lateTaskCount")
    #expect(object["overdueOpenCount"]?.doubleValue == Double(expected.overdueOpenCount), "\(source): overdueOpenCount")
    #expect(
        object["tasksWithoutBaseline"]?.doubleValue == Double(expected.tasksWithoutBaseline),
        "\(source): tasksWithoutBaseline"
    )
    #expect(
        object["predictedTaskCount"]?.doubleValue == Double(expected.predictedTaskCount),
        "\(source): predictedTaskCount"
    )
    if let projectVariance = expected.projectFinishVariance {
        #expect(
            object["projectFinishVariance"]?.doubleValue == Double(projectVariance),
            "\(source): projectFinishVariance"
        )
    } else {
        #expect(object["projectFinishVariance"] == nil, "\(source): projectFinishVariance 为空时不得写出键")
    }
    #expect(object["orphans"]?.arrayValue?.count == expected.orphans.count, "\(source): orphans 数量")
}

// MARK: - B-06：CLI 基线的增删查与 task get 基线段

@Test func baselineCLICreateListDeleteRoundTrip() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let file = scratch.kairo

    try CLIRouter.execute(arguments: ["project", "create", "基线会话", "--start", "2030-01-01", "--file", file.path])
    try CLIRouter.execute(arguments: ["task", "add", "任务一", "--duration", "2", "--file", file.path])

    let created = try runCLI(["baseline", "create", "--name", "验收基线", "--file", file.path])
    #expect(created.contains("验收基线"))

    let listed = try runCLI(["baseline", "list", "--file", file.path])
    #expect(listed.contains("验收基线"))
    let json = try runCLIJSON(["baseline", "list", "--json", "--file", file.path])
    let rows = try #require(json.objectValue?["baselines"]?.arrayValue)
    #expect(rows.count == 1)
    #expect(rows.first?.objectValue?["name"]?.stringValue == "验收基线")
    let rawID = try #require(rows.first?.objectValue?["baselineID"]?.stringValue)
    let createdAt = try #require(rows.first?.objectValue?["createdAt"]?.stringValue)

    // 判据 6：list / create / delete 三个出口都必须带 baselineID + name + createdAt。
    #expect(listed.contains(rawID))
    #expect(created.contains(rawID))
    #expect(created.contains(createdAt))
    // 前缀解析：8 位前缀即可删除（与 task / resource 同规则）。
    let prefix = String(rawID.prefix(8))
    let deleted = try runCLI(["baseline", "delete", prefix, "--file", file.path])
    #expect(deleted.contains(rawID))
    #expect(deleted.contains("验收基线"))
    #expect(deleted.contains(createdAt))
    #expect(try KairoFile.load(from: file).baselines.isEmpty)
    let empty = try runCLI(["baseline", "list", "--file", file.path])
    #expect(empty.contains("尚未创建基线"))
}

@Test func baselineCLIDeleteRejectsTooShortPrefix() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    try CLIRouter.execute(arguments: ["project", "create", "前缀校验", "--file", scratch.kairo.path])
    #expect(throws: UsageError.self) {
        try CLIRouter.execute(arguments: ["baseline", "delete", "abc", "--file", scratch.kairo.path])
    }
}

@Test func baselineTaskGetPrintsBaselineSection() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    let detail = try runCLI(["task", "get", fixture.rescheduledTaskID.uuidString, "--file", fixture.file.path])
    let entry = try #require(fixture.baseline.entry(for: fixture.rescheduledTaskID))
    let formatter = ISO8601DateFormatter()
    #expect(detail.contains("基线：基线甲"))
    #expect(detail.contains(fixture.baseline.id.uuidString))
    #expect(detail.contains(formatter.string(from: entry.start)))
    #expect(detail.contains(formatter.string(from: entry.finish)))
    #expect(detail.contains("计划偏差："))
    #expect(detail.contains("实际偏差："))
    // 实际提前 1 天：负号必须保留，不能写成 0 也不能丢符号。
    #expect(detail.contains("-1 天"))
}

// MARK: - B-12：CLI / MCP / 引擎三方对等性

@Test func baselineVarianceJSONMatchesEngine() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)

    let json = try runCLIJSON(["baseline", "variance", "--json", "--file", fixture.file.path])
    expectReportMatches(json, expected, source: "CLI")
    let rows = try #require(json.objectValue?["tasks"]?.arrayValue)
    #expect(rows.count == expected.tasks.count)
    for row in rows {
        let taskID = try #require(row.objectValue?["taskID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let variance = try #require(expected.tasks[taskID])
        expectRowMatches(row, variance, source: "CLI")
    }
}

@Test func baselineVarianceMCPMatchesEngine() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)

    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)
    let report = try mcpCall(server, id: 2, name: "baseline_variance", arguments: "{}")
    expectReportMatches(report, expected, source: "MCP")
    let rows = try #require(report.objectValue?["tasks"]?.arrayValue)
    #expect(rows.count == expected.tasks.count)
    for row in rows {
        let taskID = try #require(row.objectValue?["taskID"]?.stringValue.flatMap(UUID.init(uuidString:)))
        let variance = try #require(expected.tasks[taskID])
        expectRowMatches(row, variance, source: "MCP")
    }
}

@Test func baselineVarianceCLIAndMCPAgreeOnFilteredTask() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)
    let target = try #require(expected.tasks[fixture.rescheduledTaskID])

    let cli = try runCLIJSON([
        "baseline", "variance", "--json",
        "--baseline", fixture.baseline.id.uuidString,
        "--task", fixture.rescheduledTaskID.uuidString,
        "--file", fixture.file.path,
    ])
    let cliRows = try #require(cli.objectValue?["tasks"]?.arrayValue)
    #expect(cliRows.count == 1)
    expectRowMatches(try #require(cliRows.first), target, source: "CLI --task")

    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)
    let mcp = try mcpCall(server, id: 2, name: "baseline_variance", arguments: #"{"baselineID":"\#(fixture.baseline.id.uuidString)","taskID":"\#(fixture.rescheduledTaskID.uuidString)"}"#)
    let mcpRows = try #require(mcp.objectValue?["tasks"]?.arrayValue)
    #expect(mcpRows.count == 1)
    expectRowMatches(try #require(mcpRows.first), target, source: "MCP taskID")

    // 身份字段在过滤后仍必须齐全（判据 6）。
    #expect(cli.objectValue?["baselineID"]?.stringValue == fixture.baseline.id.uuidString)
    #expect(mcp.objectValue?["baselineID"]?.stringValue == fixture.baseline.id.uuidString)
}

@Test func baselineVarianceJSONOmitsEmptyValuesAndKeepsSigns() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    let json = try runCLIJSON(["baseline", "variance", "--json", "--file", fixture.file.path])
    let rows = try #require(json.objectValue?["tasks"]?.arrayValue)

    let added = try #require(rows.first { $0.objectValue?["taskID"]?.stringValue == fixture.addedTaskID.uuidString })
    #expect(added.objectValue?["hasBaseline"]?.boolValue == false)
    for key in [
        "baselineStart", "baselineFinish", "planStartVariance", "planFinishVariance",
        "actualStartVariance", "actualFinishVariance", "overdueDays", "durationVariance",
    ] {
        #expect(added.objectValue?[key] == nil, "基线之后新增的 \(key) 不得写成 0")
    }

    let rescheduled = try #require(
        rows.first { $0.objectValue?["taskID"]?.stringValue == fixture.rescheduledTaskID.uuidString }
    )
    #expect(rescheduled.objectValue?["planFinishVariance"]?.doubleValue == 3)
    #expect(rescheduled.objectValue?["actualFinishVariance"]?.doubleValue == -1)
    #expect(rescheduled.objectValue?["isForecast"]?.boolValue == false)

    // 孤儿（丙）只在 orphans 里，不进 tasks。
    #expect(rows.allSatisfy { $0.objectValue?["taskID"]?.stringValue != fixture.orphanTaskID.uuidString })
    let orphans = try #require(json.objectValue?["orphans"]?.arrayValue)
    #expect(orphans.count == 1)
    #expect(orphans.first?.objectValue?["taskID"]?.stringValue == fixture.orphanTaskID.uuidString)
}

@Test func baselineVarianceTextCarriesBaselineIdentityAndSignedDays() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    let text = try runCLI(["baseline", "variance", "--file", fixture.file.path])
    #expect(text.contains("基线甲"))
    #expect(text.contains(fixture.baseline.id.uuidString))
    // 判据 6（§4.5）：偏差输出必须带创建时刻，否则报表跨版本不可比。
    #expect(text.contains(ISO8601DateFormatter().string(from: fixture.baseline.createdAt)))
    #expect(text.contains("项目结束偏差："))
    #expect(text.contains("+3 天"))
    #expect(text.contains("-1 天"))
    #expect(!text.contains("+-1"))
}

// MARK: - MCP 工具面与稳定错误码

@Test func baselineMCPToolsAreListedWithSchemas() throws {
    let server = MCPServer()
    let response = try mcpSend(server, #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)
    let tools = response.objectValue?["result"]?.objectValue?["tools"]?.arrayValue ?? []
    let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
    for name in ["baseline_create", "baseline_list", "baseline_delete", "baseline_variance"] {
        #expect(names.contains(name), "缺少工具 \(name)")
        let tool = tools.first { $0.objectValue?["name"]?.stringValue == name }
        #expect(tool?.objectValue?["inputSchema"]?.objectValue?["type"]?.stringValue == "object")
    }
}

@Test func baselineMCPCreateThenListCarriesIdentity() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_create", arguments: #"{"title":"MCP 基线","projectStart":"2030-01-01T00:00:00Z"}"#)
    _ = try mcpCall(server, id: 2, name: "task_add", arguments: #"{"title":"任务甲","durationDays":2}"#)

    let created = try mcpCall(server, id: 3, name: "baseline_create", arguments: #"{"name":"MCP 基线甲"}"#)
    #expect(created.objectValue?["baselineID"] != nil)
    #expect(created.objectValue?["name"]?.stringValue == "MCP 基线甲")
    #expect(created.objectValue?["createdAt"] != nil)
    #expect(created.objectValue?["entryCount"]?.doubleValue == 1)

    let listed = try mcpCall(server, id: 4, name: "baseline_list", arguments: "{}")
    let baselines = try #require(listed.objectValue?["baselines"]?.arrayValue)
    #expect(baselines.count == 1)
    #expect(baselines.first?.objectValue?["baselineID"]?.stringValue == created.objectValue?["baselineID"]?.stringValue)

    let baselineID = try #require(created.objectValue?["baselineID"]?.stringValue)
    let deleted = try mcpCall(server, id: 5, name: "baseline_delete", arguments: #"{"baselineID":"\#(baselineID)"}"#)
    #expect(deleted.objectValue?["ok"]?.boolValue == true)
    // 判据 6：删除回执同样带身份三字段。
    #expect(deleted.objectValue?["baselineID"]?.stringValue == baselineID)
    #expect(deleted.objectValue?["name"]?.stringValue == "MCP 基线甲")
    #expect(deleted.objectValue?["createdAt"]?.stringValue == created.objectValue?["createdAt"]?.stringValue)
    let afterDelete = try mcpCall(server, id: 6, name: "baseline_list", arguments: "{}")
    #expect(afterDelete.objectValue?["baselines"]?.arrayValue?.isEmpty == true)
}

@Test func baselineMCPVarianceWithoutBaselineReturnsStableCode() throws {
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_create", arguments: #"{"title":"无基线","projectStart":"2030-01-01T00:00:00Z"}"#)
    _ = try mcpCall(server, id: 2, name: "task_add", arguments: #"{"title":"任务甲","durationDays":1}"#)
    let (isError, payload) = try mcpCallResult(server, id: 3, name: "baseline_variance", arguments: "{}")
    #expect(isError)
    #expect(payload.objectValue?["reason"]?.stringValue == KairoErrorCode.baselineNotFound.rawValue)
    #expect(payload.objectValue?["code"]?.stringValue == "invalid_argument")
}

@Test func baselineMCPCreateWithEmptyNameReturnsStableCode() throws {
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_create", arguments: #"{"title":"空名基线","projectStart":"2030-01-01T00:00:00Z"}"#)
    let (isError, payload) = try mcpCallResult(server, id: 2, name: "baseline_create", arguments: #"{"name":"   "}"#)
    #expect(isError)
    #expect(payload.objectValue?["reason"]?.stringValue == KairoErrorCode.baselineNameEmpty.rawValue)
}

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
    for name in [
        "baseline_create", "baseline_list", "baseline_delete", "baseline_variance",
        "baseline_set_color",
    ] {
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

// MARK: - v0.14 颜色索引（10-multi-baseline-gantt §4）

/// 从 `baseline list --json` 取 baselineID → colorIndex。
///
/// colorIndex 必须存在且是整数：缺键就是「没派生」，与写 0 冒充一样不可接受。
private func cliColorIndexes(_ file: URL) throws -> [String: Int] {
    let json = try runCLIJSON(["baseline", "list", "--json", "--file", file.path])
    let rows = try #require(json.objectValue?["baselines"]?.arrayValue)
    var result: [String: Int] = [:]
    for row in rows {
        let id = try #require(row.objectValue?["baselineID"]?.stringValue)
        let color = try #require(row.objectValue?["colorIndex"]?.doubleValue)
        result[id] = Int(color)
    }
    return result
}

/// 从 MCP `baseline_list` 取 baselineID → colorIndex（与 CLI 同口径的另一条出口）。
private func mcpColorIndexes(_ server: MCPServer, id: Int) throws -> [String: Int] {
    let listed = try mcpCall(server, id: id, name: "baseline_list", arguments: "{}")
    let rows = try #require(listed.objectValue?["baselines"]?.arrayValue)
    var result: [String: Int] = [:]
    for row in rows {
        let baselineID = try #require(row.objectValue?["baselineID"]?.stringValue)
        let color = try #require(row.objectValue?["colorIndex"]?.doubleValue)
        result[baselineID] = Int(color)
    }
    return result
}

/// 建一个带 N 条基线的项目（按创建顺序拿 0,1,2…）。
private func makeMultiBaselineFixture(names: [String]) throws -> (dir: URL, file: URL, ids: [UUID]) {
    let scratch = try makeScratch()
    try CLIRouter.execute(arguments: [
        "project", "create", "多基线配色", "--start", "2030-01-01", "--file", scratch.kairo.path,
    ])
    try CLIRouter.execute(arguments: ["task", "add", "任务一", "--duration", "2", "--file", scratch.kairo.path])
    for name in names {
        try CLIRouter.execute(arguments: ["baseline", "create", "--name", name, "--file", scratch.kairo.path])
    }
    let ids = try KairoFile.load(from: scratch.kairo).baselines.map(\.id)
    return (dir: scratch.dir, file: scratch.kairo, ids: ids)
}

/// 判据 4（接口面）：同一条基线在 CLI 与 MCP 报出同一个颜色索引；create / list / variance 都带。
@Test func baselineColorIndexMatchesAcrossCLIAndMCP() throws {
    let fixture = try makeMultiBaselineFixture(names: ["保守基线", "基准基线", "激进基线"])
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    // CLI：三条按创建顺序 0/1/2；第四条取最小未用 3。
    var cliColors = try cliColorIndexes(fixture.file)
    #expect(cliColors.count == 3)
    for (position, id) in fixture.ids.enumerated() {
        #expect(cliColors[id.uuidString] == position)
    }
    let createdText = try runCLI(["baseline", "create", "--name", "第四条", "--file", fixture.file.path])
    #expect(createdText.contains("颜色索引：3"))
    cliColors = try cliColorIndexes(fixture.file)
    #expect(cliColors.count == 4)

    // MCP 打开同一文件：list 逐条同值（同一份快照，两条出口，判据 12 对等性）。
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)
    #expect(try mcpColorIndexes(server, id: 2) == cliColors)

    // MCP 在内存里是第 5 条 → 颜色 4；回执必须带这个值。
    let mcpCreated = try mcpCall(server, id: 3, name: "baseline_create", arguments: #"{"name":"MCP 第五条"}"#)
    #expect(mcpCreated.objectValue?["colorIndex"]?.doubleValue == 4)
    let createdID = try #require(mcpCreated.objectValue?["baselineID"]?.stringValue)

    // variance 带的是「所比较那条」的颜色：MCP 最新 = 刚建的（4）；
    // CLI 看不到 MCP 未落盘的改动，最新仍是第四条（3）。
    let mcpVariance = try mcpCall(server, id: 4, name: "baseline_variance", arguments: "{}")
    #expect(mcpVariance.objectValue?["baselineID"]?.stringValue == createdID)
    #expect(mcpVariance.objectValue?["colorIndex"]?.doubleValue == 4)

    let cliVariance = try runCLIJSON(["baseline", "variance", "--json", "--file", fixture.file.path])
    let cliVarianceID = try #require(cliVariance.objectValue?["baselineID"]?.stringValue)
    let expectedCLIColor = try #require(cliColors[cliVarianceID])
    #expect(cliVariance.objectValue?["colorIndex"]?.doubleValue == Double(expectedCLIColor))
    let varianceText = try runCLI(["baseline", "variance", "--file", fixture.file.path])
    #expect(varianceText.contains("颜色索引：3"))
}

/// CLI 改色：唯一前缀即可，回执带名称与新索引，list（文本 / JSON / 落盘）立即反映。
@Test func baselineColorCLIReflectsImmediatelyInList() throws {
    let fixture = try makeMultiBaselineFixture(names: ["验收基线"])
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let baselineID = try #require(fixture.ids.first)
    #expect(try cliColorIndexes(fixture.file)[baselineID.uuidString] == 0)

    let receipt = try runCLI([
        "baseline", "color", String(baselineID.uuidString.prefix(8)), "5", "--file", fixture.file.path,
    ])
    #expect(receipt.contains("验收基线"))
    #expect(receipt.contains("颜色索引：5"))

    let listed = try runCLI(["baseline", "list", "--file", fixture.file.path])
    #expect(listed.contains("颜色索引：5"))
    #expect(try cliColorIndexes(fixture.file)[baselineID.uuidString] == 5)
    // 已落盘：不是只改内存。
    #expect(try KairoFile.load(from: fixture.file).baselines.first?.colorIndex == 5)
}

/// MCP 改色：variance 返回体带新颜色，且落盘后 CLI 读到同一色。
@Test func baselineSetColorMCPShowsInVariance() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)

    let recolored = try mcpCall(
        server, id: 2, name: "baseline_set_color",
        arguments: #"{"baselineID":"\#(fixture.baseline.id.uuidString)","colorIndex":3}"#
    )
    #expect(recolored.objectValue?["baselineID"]?.stringValue == fixture.baseline.id.uuidString)
    #expect(recolored.objectValue?["name"]?.stringValue == fixture.baseline.name)
    #expect(recolored.objectValue?["colorIndex"]?.doubleValue == 3)

    let variance = try mcpCall(server, id: 3, name: "baseline_variance", arguments: "{}")
    #expect(variance.objectValue?["baselineID"]?.stringValue == fixture.baseline.id.uuidString)
    #expect(variance.objectValue?["colorIndex"]?.doubleValue == 3)

    _ = try mcpCall(server, id: 4, name: "project_save", arguments: "{}")
    #expect(try cliColorIndexes(fixture.file)[fixture.baseline.id.uuidString] == 3)
}

/// 越界索引：两条出口都报 model_baseline_color_index_invalid，且都不落库。
@Test func baselineColorIndexOutOfRangeReportsStableCodeOnBothSides() throws {
    let fixture = try makeMultiBaselineFixture(names: ["越界基线"])
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let baselineID = try #require(fixture.ids.first)

    for raw in ["8", "-1"] {
        var caught: SessionError?
        do {
            _ = try runCLI(["baseline", "color", baselineID.uuidString, raw, "--file", fixture.file.path])
        } catch let error as SessionError {
            caught = error
        }
        let error = try #require(caught)
        #expect(error.reason == .baselineColorIndexInvalid, "CLI 越界 \(raw) 的细码")
        #expect(error.code == .invalidArgument)
    }
    #expect(try cliColorIndexes(fixture.file)[baselineID.uuidString] == 0)

    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)
    for (offset, raw) in ["8", "-1"].enumerated() {
        let (isError, payload) = try mcpCallResult(
            server, id: 2 + offset, name: "baseline_set_color",
            arguments: #"{"baselineID":"\#(baselineID.uuidString)","colorIndex":\#(raw)}"#
        )
        #expect(isError)
        #expect(payload.objectValue?["reason"]?.stringValue == KairoErrorCode.baselineColorIndexInvalid.rawValue)
        #expect(payload.objectValue?["code"]?.stringValue == "invalid_argument")
    }
    let listed = try mcpCall(server, id: 4, name: "baseline_list", arguments: "{}")
    #expect(listed.objectValue?["baselines"]?.arrayValue?.first?.objectValue?["colorIndex"]?.doubleValue == 0)
}

/// 旧文件缺 colorIndex：读路径按创建顺序派生，CLI / MCP 同值，且只读出口不写回。
@Test func baselineColorIndexDerivedForLegacyFileWithoutField() throws {
    let fixture = try makeMultiBaselineFixture(names: ["旧甲", "旧乙"])
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    // 模拟 v0.13 快照：把 colorIndex 整个字段摘掉。
    let data = try Data(contentsOf: fixture.file)
    let object = try JSONSerialization.jsonObject(with: data)
    var root = try #require(object as? [String: Any])
    let rows = try #require(root["baselines"] as? [[String: Any]])
    root["baselines"] = rows.map { row in
        var copy = row
        copy.removeValue(forKey: "colorIndex")
        return copy
    }
    try JSONSerialization.data(withJSONObject: root).write(to: fixture.file)

    let colors = try cliColorIndexes(fixture.file)
    #expect(colors[fixture.ids[0].uuidString] == 0)
    #expect(colors[fixture.ids[1].uuidString] == 1)

    let server = MCPServer()
    _ = try mcpCall(server, id: 1, name: "project_open", arguments: #"{"path":"\#(fixture.file.path)"}"#)
    #expect(try mcpColorIndexes(server, id: 2) == colors)

    let after = try String(contentsOf: fixture.file, encoding: .utf8)
    #expect(!after.contains("colorIndex"), "只读出口不得把派生颜色写回文件")
}

// MARK: - v0.15：CSV 导出与项目摘要（09-baseline-version-plan §4）

/// CSV 列头（逐字；顺序即数据列顺序，与 `VarianceCSV.header` 契约一致）。
private let csvHeaderColumns = [
    "taskID", "title", "baselineStart", "baselineFinish",
    "planStartVariance", "planFinishVariance",
    "actualStartVariance", "actualFinishVariance",
    "overdueDays", "hasBaseline", "isForecast",
]

/// 与 CSV 相同的时间表示（ISO 8601 / UTC），用于逐字比对。
private func csvDate(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// 最小 CSV 状态机（RFC 4180），独立于生产代码实现——复用生产解析器会「同错同过」。
///
/// 规则：引号**只在字段起始处**生效（与 python `csv` 一致），字段内含逗号/引号/换行时整体加引号，
/// 内部引号写成两个引号。裸引号（字段中间出现、未包裹）按字面保留。
private func csvFields(_ line: String) -> [String] {
    var fields: [String] = []
    var current = ""
    var inQuotes = false
    var fieldStarted = false
    var index = line.startIndex
    while index < line.endIndex {
        let character = line[index]
        if inQuotes {
            if character == "\"" {
                let next = line.index(after: index)
                if next < line.endIndex, line[next] == "\"" {
                    current.append("\"")
                    index = line.index(after: next)
                    continue
                }
                inQuotes = false
            } else {
                current.append(character)
            }
        } else if character == "\"" , !fieldStarted, current.isEmpty {
            inQuotes = true
            fieldStarted = true
        } else if character == "," {
            fields.append(current)
            current = ""
            fieldStarted = false
        } else {
            current.append(character)
            fieldStarted = true
        }
        index = line.index(after: index)
    }
    fields.append(current)
    return fields
}

/// CSV 形状不满足预期：**抛错而不是数组越界**。
/// 越界会以 signal 5 炸掉整个测试进程，后面所有用例连跑都跑不到；红断言才定位得到问题。
private struct CSVShapeViolation: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// 断言列数恰为列头宽度（不满足即抛，后续下标才安全）。
private func requireCSVWidth(_ fields: [String], _ context: String) throws {
    guard fields.count == csvHeaderColumns.count else {
        throw CSVShapeViolation(
            message: "\(context)：列数 \(fields.count) ≠ \(csvHeaderColumns.count)，原始行 \(fields)"
        )
    }
}

/// 取第 index 节（缺节即抛，不越界）。
private func requireCSVSection(_ sections: [[String]], _ index: Int, _ context: String) throws -> [String] {
    guard sections.indices.contains(index) else {
        throw CSVShapeViolation(message: "\(context)：缺少第 \(index + 1) 节（实得 \(sections.count) 节）")
    }
    return sections[index]
}

/// 取第 index 列（缺列即抛，不越界）。
private func requireCSVField(_ fields: [String], _ index: Int, _ context: String) throws -> String {
    guard fields.indices.contains(index) else {
        throw CSVShapeViolation(message: "\(context)：缺少第 \(index + 1) 列（实得 \(fields.count) 列）")
    }
    return fields[index]
}

/// 读 CSV 并切成「列头 + 若干数据行」的分节：遇到逐字列头即开新节。
/// 返回 (全部行, 各节数据行, 是否以 BOM 开头)。
private func csvSections(_ url: URL) throws -> (lines: [String], sections: [[String]], hasBOM: Bool) {
    let data = try Data(contentsOf: url)
    let hasBOM = data.starts(with: [0xEF, 0xBB, 0xBF])
    let raw = String(decoding: data, as: UTF8.self)
    // BOM 是 U+FEFF 字符，不剥掉会让首行既不是 "#" 注释也不是列头。
    let text = hasBOM ? String(raw.dropFirst()) : raw
    let header = csvHeaderColumns.joined(separator: ",")
    let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    var sections: [[String]] = []
    for line in lines {
        if line.isEmpty || line.hasPrefix("#") { continue }
        if line == header {
            sections.append([])
        } else {
            // 首行不是列头时按「无列头」容错收集：让断言红在明处，而不是数组越界炸掉整个测试进程。
            if sections.isEmpty { sections.append([]) }
            sections[sections.count - 1].append(line)
        }
    }
    return (lines, sections, hasBOM)
}

/// 逐字段比对一行 CSV 与引擎给出的单任务偏差（缺值必须是空字段，不能是 0）。
private func expectCSVRow(_ fields: [String], matches variance: TaskVariance, title: String) throws {
    try requireCSVWidth(fields, "任务行")
    #expect(try requireCSVField(fields, 0, "任务行") == variance.taskID.uuidString)
    #expect(try requireCSVField(fields, 1, "任务行") == title)
    #expect(try requireCSVField(fields, 2, "任务行") == (variance.baselineStart.map(csvDate) ?? ""))
    #expect(try requireCSVField(fields, 3, "任务行") == (variance.baselineFinish.map(csvDate) ?? ""))
    let intFields = [
        variance.planStartVariance, variance.planFinishVariance,
        variance.actualStartVariance, variance.actualFinishVariance, variance.overdueDays,
    ]
    for (offset, value) in intFields.enumerated() {
        let expected = value.map { String($0) } ?? ""
        let actual = try requireCSVField(fields, 4 + offset, "任务行")
        #expect(actual == expected, "\(csvHeaderColumns[4 + offset]) 期望 \(expected)，实际 \(actual)")
    }
    #expect(try requireCSVField(fields, 9, "任务行") == (variance.hasBaseline ? "true" : "false"))
    #expect(try requireCSVField(fields, 10, "任务行") == (variance.isForecast ? "true" : "false"))
}

@Test func baselineVarianceCSVHeaderIsVerbatimAndRowsMatchEngine() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)
    let titles = Dictionary(uniqueKeysWithValues: try KairoFile.load(from: fixture.file).tasks.map { ($0.id, $0.title) })
    let csvURL = fixture.dir.appendingPathComponent("variance.csv")

    let receipt = try runCLI(["baseline", "variance", "--csv", csvURL.path, "--file", fixture.file.path])
    #expect(receipt.contains("已导出 CSV"))

    let parsed = try csvSections(csvURL)
    #expect(parsed.hasBOM, "UTF-8 文件必须带 BOM，否则 Excel 打开中文乱码")
    // 身份三字段（§4.5）：文件脱离终端单独流转时必须自带标识。
    #expect(parsed.lines.contains("# baselineID," + expected.baselineID.uuidString))
    #expect(parsed.lines.contains("# baselineCreatedAt," + csvDate(expected.baselineCreatedAt)))
    #expect(parsed.lines.contains { $0.hasPrefix("# baselineName,") })
    // 列头逐字 + 主表行数 = 报告任务数，孤儿单独一节。
    let main = try requireCSVSection(parsed.sections, 0, "主表")
    let orphans = try requireCSVSection(parsed.sections, 1, "孤儿节")
    #expect(parsed.sections.count == 2)
    #expect(main.count == expected.tasks.count)
    #expect(orphans.count == expected.orphans.count)

    // 列头逐字：拆出来必须与契约数组逐项相等（不是 startsWith，也不是「前三列对」）。
    let headerLine = try #require(parsed.lines.first { !$0.isEmpty && !$0.hasPrefix("#") })
    #expect(csvFields(headerLine) == csvHeaderColumns)

    for line in parsed.sections.flatMap({ $0 }) {
        try requireCSVWidth(csvFields(line), "数据行")
    }
    for line in main {
        let fields = csvFields(line)
        let taskID = try #require(UUID(uuidString: try requireCSVField(fields, 0, "任务行")))
        let variance = try #require(expected.tasks[taskID])
        try expectCSVRow(fields, matches: variance, title: try #require(titles[taskID]))
    }
}

@Test func baselineVarianceCSVKeepsSignsAndLeavesEmptyCellsEmpty() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)
    let csvURL = fixture.dir.appendingPathComponent("variance.csv")
    _ = try runCLI(["baseline", "variance", "--csv", csvURL.path, "--file", fixture.file.path])

    let sections = try csvSections(csvURL).sections
    let main = try requireCSVSection(sections, 0, "主表")
    var rowsByID: [String: [String]] = [:]
    for line in main {
        let fields = csvFields(line)
        try requireCSVWidth(fields, "任务行")
        rowsByID[try requireCSVField(fields, 0, "任务行")] = fields
    }

    // 计划推迟 3 天、实际提前 1 天：符号必须保留（不写 +，- 不能丢）。
    let rescheduled = try #require(rowsByID[fixture.rescheduledTaskID.uuidString])
    #expect(try requireCSVField(rescheduled, 5, "任务甲") == "3")
    #expect(try requireCSVField(rescheduled, 7, "任务甲") == "-1")
    #expect(!rescheduled.joined().contains("+-"))

    // 基线之后新增：基线起止与四类偏差全部留空（不写 0，§4.1）。
    let added = try #require(rowsByID[fixture.addedTaskID.uuidString])
    #expect(try requireCSVField(added, 1, "任务丁") == "任务丁")
    for index in [2, 3, 4, 5, 6, 7, 8] {
        let actual = try requireCSVField(added, index, "任务丁")
        #expect(actual == "", "\(csvHeaderColumns[index]) 无数据时必须留空")
    }
    #expect(try requireCSVField(added, 9, "任务丁") == "false")

    // 已基线但未完成：overdueDays 有值（远期基线恒 0），实际偏差留空。
    let open = try #require(rowsByID[fixture.openTaskID.uuidString])
    #expect(try requireCSVField(open, 6, "任务乙") == "")
    #expect(try requireCSVField(open, 7, "任务乙") == "")
    #expect(try requireCSVField(open, 8, "任务乙") != "")
    #expect(try requireCSVField(open, 10, "任务乙") == "true")
    #expect(expected.tasks.count == rowsByID.count)
}

@Test func baselineVarianceCSVOrphanSectionIsReproducible() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let expected = try engineReport(fixture)
    let first = fixture.dir.appendingPathComponent("first.csv")
    let second = fixture.dir.appendingPathComponent("second.csv")

    _ = try runCLI(["baseline", "variance", "--csv", first.path, "--file", fixture.file.path])
    _ = try runCLI(["baseline", "variance", "--csv", second.path, "--file", fixture.file.path])
    #expect(try Data(contentsOf: first) == (try Data(contentsOf: second)), "同一份文件两次导出必须逐字节一致")

    let sections = try csvSections(first).sections
    let main = try requireCSVSection(sections, 0, "主表")
    let orphanRows = try requireCSVSection(sections, 1, "孤儿节")
    #expect(sections.count == 2)
    #expect(orphanRows.count == 1)
    let orphan = try #require(expected.orphans.first)
    let fields = csvFields(try #require(orphanRows.first))
    try requireCSVWidth(fields, "孤儿行")
    #expect(try requireCSVField(fields, 0, "孤儿行") == fixture.orphanTaskID.uuidString)
    #expect(try requireCSVField(fields, 0, "孤儿行") == orphan.taskID.uuidString)
    #expect(try requireCSVField(fields, 1, "孤儿行") == "", "孤儿没有标题（任务已删），标题留空")
    #expect(try requireCSVField(fields, 2, "孤儿行") == csvDate(orphan.start))
    #expect(try requireCSVField(fields, 3, "孤儿行") == csvDate(orphan.finish))
    for index in [4, 5, 6, 7, 8] {
        let actual = try requireCSVField(fields, index, "孤儿行")
        #expect(actual == "", "\(csvHeaderColumns[index]) 孤儿无偏差数据，必须留空")
    }
    #expect(try requireCSVField(fields, 9, "孤儿行") == "true")
    #expect(try requireCSVField(fields, 10, "孤儿行") == "false")
    // 孤儿不得混进主表（主表按任务行渲染）。
    #expect(!main.contains { csvFields($0).first == fixture.orphanTaskID.uuidString })
}

/// CSV 状态机自身的用例：解析绝不能是「按逗号切」（那正是越界崩溃的来源）。
@Test func csvParserStateMachineHandlesQuotesCommasAndEmptyFields() {
    #expect(csvFields("plain") == ["plain"])
    #expect(csvFields("") == [""])
    #expect(csvFields("a,,c") == ["a", "", "c"], "空字段必须保留占位，不能塌成 2 列")
    #expect(csvFields("甲,带逗号") == ["甲", "带逗号"], "未加引号的逗号按分隔符切")
    #expect(csvFields("\"甲,带逗号\",x") == ["甲,带逗号", "x"], "引号内的逗号不分隔")
    #expect(csvFields("他说\"hi\",x") == ["他说\"hi\"", "x"], "字段中间的裸引号按字面保留")
    #expect(csvFields("\"他说\"\"hi\"\"\",x") == ["他说\"hi\"", "x"], "翻倍引号还原为一个")
    #expect(csvFields("a,\"b\"\"c\",") == ["a", "b\"c", ""])
}

/// 判据 3（RFC 4180）：标题为 `甲,带逗号` 与 `他说"hi"` 时——
/// 每行列数与列头一致、取回值原样；基线名同样走转义。
@Test func baselineVarianceCSVQuotesCommasAndQuotesRoundTrip() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let file = scratch.kairo
    try CLIRouter.execute(arguments: [
        "project", "create", "逗号项目", "--start", "2030-01-01", "--end", "2030-02-01",
        "--file", file.path,
    ])
    let titles = ["甲,带逗号", "他说\"hi\"", "丙 普通"]
    for title in titles {
        try CLIRouter.execute(arguments: ["task", "add", title, "--duration", "1", "--file", file.path])
    }
    let baselineName = "基线\"甲\", 逗号"
    try CLIRouter.execute(arguments: ["baseline", "create", "--name", baselineName, "--file", file.path])

    let csvURL = scratch.dir.appendingPathComponent("quoted.csv")
    _ = try runCLI(["baseline", "variance", "--csv", csvURL.path, "--file", file.path])
    let parsed = try csvSections(csvURL)

    // 列头逐字解析回来仍是 11 列（「列数与列头一致」的第一道关）。
    let headerLine = try #require(parsed.lines.first { !$0.isEmpty && !$0.hasPrefix("#") })
    let headerFields = csvFields(headerLine)
    #expect(headerFields == csvHeaderColumns)
    try requireCSVWidth(headerFields, "列头")

    let main = try requireCSVSection(parsed.sections, 0, "主表")
    #expect(main.count == titles.count)
    var exportedTitles: [String] = []
    for line in main {
        let fields = csvFields(line)
        try requireCSVWidth(fields, "含逗号/引号的标题行")
        exportedTitles.append(try requireCSVField(fields, 1, "标题列"))
    }
    #expect(exportedTitles == titles, "标题必须原样取回（引号/逗号不得被吞或被切列）")

    // 基线名同样转义：含引号与逗号时写成 "基线""甲"", 逗号"。
    let escapedName = "\"基线\"\"甲\"\", 逗号\""
    #expect(parsed.lines.contains("# baselineName," + escapedName))

    // 第二种解析器交叉验证（python csv）：同一份文件列数必须恒为 11。
    if let widths = try pythonCSVColumnWidths(csvURL.path) {
        #expect(Set(widths) == [csvHeaderColumns.count], "python 解析列数应恒为 \(csvHeaderColumns.count)，实际 \(Set(widths))")
    }
}

@Test func baselineVarianceCSVIsParsedByPythonCSV() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    let csvURL = fixture.dir.appendingPathComponent("python.csv")
    _ = try runCLI(["baseline", "variance", "--csv", csvURL.path, "--file", fixture.file.path])

    guard let widths = try pythonCSVColumnWidths(csvURL.path) else { return }
    #expect(!widths.isEmpty, "python csv 必须能读出数据行")
    #expect(Set(widths) == [csvHeaderColumns.count], "全部行必须是 \(csvHeaderColumns.count) 列，实际 \(Set(widths))")
}

@Test func baselineVarianceCSVRejectsJSONCombinationAndMissingPath() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }
    #expect(throws: UsageError.self) {
        try runCLI([
            "baseline", "variance", "--json", "--csv", fixture.dir.appendingPathComponent("x.csv").path,
            "--file", fixture.file.path,
        ])
    }
    #expect(throws: UsageError.self) {
        try runCLI(["baseline", "variance", "--csv", "--file", fixture.file.path])
    }
}

@Test func projectSummaryCarriesVarianceBlockSameAsBaselineVariance() throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.dir) }

    let summary = try runCLIJSON(["project", "summary", "--json", "--file", fixture.file.path])
    let variance = try #require(summary.objectValue?["variance"]?.objectValue)
    let report = try runCLIJSON(["baseline", "variance", "--json", "--file", fixture.file.path])
    let reportObject = try #require(report.objectValue)

    // 同源：项目级字段逐字同值（口径漂移会在这里红）。
    for key in [
        "baselineID", "baselineName", "colorIndex", "baselineCreatedAt",
        "projectFinishVariance", "lateTaskCount", "overdueOpenCount",
        "tasksWithoutBaseline", "predictedTaskCount",
    ] {
        #expect(variance[key] == reportObject[key], "\(key) 必须与 baseline variance 同源")
    }
    #expect(variance["orphanCount"]?.doubleValue == Double(reportObject["orphans"]?.arrayValue?.count ?? -1))

    // 项目字段与文件同源：直接按落盘内容算期望值，避免把夹具数字写死。
    let loaded = try KairoFile.load(from: fixture.file)
    let project = try #require(summary.objectValue?["project"]?.objectValue)
    #expect(project["taskCount"]?.doubleValue == Double(loaded.tasks.count))
    #expect(project["groupCount"]?.doubleValue == Double(loaded.tasks.filter { $0.kind == .group }.count))
    #expect(
        project["statusCounts"]?.objectValue?["done"]?.doubleValue
            == Double(loaded.tasks.filter { $0.status == .done }.count)
    )

    let text = try runCLI(["project", "summary", "--file", fixture.file.path])
    #expect(text.contains("项目结束偏差："))
    #expect(text.contains("晚完成"))
    #expect(text.contains("孤儿：1 条"))
    #expect(text.contains(fixture.baseline.id.uuidString))
}

@Test func projectSummaryWithoutBaselineShowsNoVarianceBlock() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let file = scratch.kairo
    try CLIRouter.execute(arguments: [
        "project", "create", "无基线项目", "--start", "2030-01-01", "--end", "2030-02-01",
        "--file", file.path,
    ])
    try CLIRouter.execute(arguments: ["task", "add", "任务甲", "--duration", "1", "--file", file.path])

    let text = try runCLI(["project", "summary", "--file", file.path])
    #expect(text.contains("尚未创建基线"))
    #expect(!text.contains("项目结束偏差"), "无基线不得把缺少比较基准渲染成「0 天」")

    let json = try runCLIJSON(["project", "summary", "--json", "--file", file.path])
    #expect(json.objectValue?["variance"] == nil)
    #expect(json.objectValue?["project"]?.objectValue?["taskCount"]?.doubleValue == 1)
}

/// 用系统 python3 的 csv 模块解析导出文件，返回每行的列数（含列头行）。
/// 返回 `nil` 表示本机没有 python3（精简 CI 镜像），调用方跳过该断言。
private func pythonCSVColumnWidths(_ path: String) throws -> [Int]? {
    guard FileManager.default.isExecutableFile(atPath: "/usr/bin/python3") else { return nil }
    let script = """
    import csv, sys
    with open(sys.argv[1], newline='', encoding='utf-8-sig') as handle:
        rows = [row for row in csv.reader(handle) if row and not row[0].startswith('#')]
    print(' '.join(str(len(row)) for row in rows))
    """
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", script, path]
    let output = Pipe()
    process.standardOutput = output
    process.standardError = Pipe()
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return String(decoding: data, as: UTF8.self)
        .split(separator: " ")
        .compactMap { Int($0) }
}


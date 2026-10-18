import Foundation
import Testing
import KairoCore
import KairoCommands
@testable import KairoCLI

// CLI 对等性契约测试（US-E5-05 / ADR-005）：路由解析与 KairoSession 往返。
// MCP 侧对应测试见 InterfaceTests.swift；两接口层共享同一命令层契约。

// MARK: - 参数与枚举解析（路由级）

struct OptionsParsingTests {
    @Test func operandsAndFlagValues() throws {
        // 路由已剥离子命令，Options 只接收操作数与选项。
        let o = Options(["标题", "--kind", "group", "--effort", "8"])
        #expect(try o.operand(0, name: "标题") == "标题")
        #expect(o.value(for: "--kind") == "group")
        #expect(o.double(for: "--effort") == 8)
        #expect(o.value(for: "--parent") == nil)
    }

    @Test func repeatedDependencyValues() throws {
        let idA = UUID().uuidString
        let idB = UUID().uuidString
        let o = Options(["add", "任务", "--dep", "\(idA):fs", "--dep", "\(idB):ff:2"])
        let specs = o.values(for: "--dep")
        #expect(specs == ["\(idA):fs", "\(idB):ff:2"])
    }

    @Test func enumsParseValidKinds() throws {
        #expect(try CLIEnums.kind("task") == .task)
        #expect(try CLIEnums.kind("group") == .group)
        #expect(try CLIEnums.kind("milestone") == .milestone)
        #expect(try CLIEnums.kind(nil) == nil)
    }

    @Test func enumsRejectInvalidValues() throws {
        #expect(throws: UsageError.self) { _ = try CLIEnums.kind("gantt") }
        #expect(throws: CLIError.self) { _ = try CLIEnums.priority("urgent") }
        #expect(throws: CLIError.self) { _ = try CLIEnums.status("paused") }
        #expect(try CLIEnums.priority("critical") == .critical)
        #expect(try CLIEnums.status("in_progress") == .inProgress)
    }

    @Test func dependencySpecParsesTypeAndLag() throws {
        let id = UUID()
        let dep = try CLIEnums.dependency("\(id.uuidString):ff:2")
        #expect(dep.predecessorID == id)
        #expect(dep.type == .ff)
        #expect(dep.lagDays == 2)
    }

    @Test func dependencySpecDefaultsToFSNoLag() throws {
        let id = UUID()
        let dep = try CLIEnums.dependency(id.uuidString)
        #expect(dep.type == .fs)
        #expect(dep.lagDays == 0)
    }

    @Test func dependencySpecRejectsBadIDAndType() throws {
        #expect(throws: CLIError.self) { _ = try CLIEnums.dependency("not-a-uuid") }
        #expect(throws: CLIError.self) {
            _ = try CLIEnums.dependency("\(UUID().uuidString):xx")
        }
    }

    @Test func schedulingPolicyAndConstraintParse() throws {
        #expect(try CLIEnums.schedulingPolicy("alap") == .alap)
        #expect(try CLIEnums.schedulingPolicy(nil) == nil)
        #expect(throws: UsageError.self) { _ = try CLIEnums.schedulingPolicy("soon") }

        let constraint = try CLIEnums.constraint("startNoLaterThan:2026-11-05T00:00:00Z")
        guard case .startNoLaterThan(let date) = constraint else {
            Issue.record("应解析为 startNoLaterThan")
            return
        }
        #expect(ISO8601DateFormatter().string(from: date) == "2026-11-05T00:00:00Z")
        #expect(try CLIEnums.constraint(nil) == nil)
        #expect(throws: UsageError.self) { _ = try CLIEnums.constraint("bad-spec") }
    }
}

// MARK: - 端到端路由（临时目录内 create → import → list）

struct RouteTests {
    /// 建临时工作目录，返回目录与其中的两个路径（.kairo 与 wbs.json）。
    /// 调用方用 defer 在测试结束后清理目录。
    private func makeScratch() throws -> (dir: URL, kairo: URL, wbs: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-cli-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (
            dir: dir,
            kairo: dir.appendingPathComponent("demo.kairo"),
            wbs: dir.appendingPathComponent("wbs.json")
        )
    }

    @Test func projectCreateThenWBSImportPersistsTree() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "演示项目", "--file", file.path])

        let wbs = #"""
        [
          {"title": "设计", "children": [
            {"title": "原型"},
            {"title": "评审"}
          ]},
          {"title": "开发", "kind": "group", "children": [
            {"title": "后端", "kind": "milestone"}
          ]}
        ]
        """#
        try Data(wbs.utf8).write(to: scratch.wbs)
        try CLIRouter.execute(arguments: ["wbs", "import", scratch.wbs.path, "--file", file.path])

        let project = try KairoFile.load(from: file)
        #expect(project.metadata.title == "演示项目")
        #expect(project.tasks.count == 5)
        // 层级：设计(根) → 原型/评审；开发(根) → 后端。
        let design = try #require(project.tasks.first { $0.title == "设计" })
        let dev = try #require(project.tasks.first { $0.title == "开发" })
        let proto = try #require(project.tasks.first { $0.title == "原型" })
        #expect(design.kind == .group)
        #expect(design.parentID == nil)
        #expect(proto.parentID == design.id)
        #expect(dev.kind == .group)
        #expect(try #require(project.tasks.first { $0.title == "后端" }).kind == .milestone)
    }

    @Test func taskAddWithDependencyThenGetRoundTrip() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "依赖演示", "--file", file.path])
        try CLIRouter.execute(arguments: ["task", "add", "前驱任务", "--file", file.path])

        var project = try KairoFile.load(from: file)
        let predecessor = try #require(project.tasks.first)
        try CLIRouter.execute(arguments: [
            "task", "add", "后继任务",
            "--dep", "\(predecessor.id.uuidString):ff:2",
            "--priority", "high",
            "--effort", "8",
            "--file", file.path,
        ])

        project = try KairoFile.load(from: file)
        let successor = try #require(project.tasks.first { $0.title == "后继任务" })
        #expect(successor.dependencies.count == 1)
        #expect(successor.dependencies.first?.predecessorID == predecessor.id)
        #expect(successor.dependencies.first?.type == .ff)
        #expect(successor.dependencies.first?.lagDays == 2)
        #expect(successor.priority == .high)
        #expect(successor.effortHours == 8)

        try CLIRouter.execute(arguments: ["task", "get", predecessor.id.uuidString, "--file", file.path])
    }

    @Test func taskUpdateProgressAndStatus() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "更新演示", "--file", file.path])
        try CLIRouter.execute(arguments: ["task", "add", "进行中的任务", "--file", file.path])
        let project0 = try KairoFile.load(from: file)
        let id = try #require(project0.tasks.first).id

        try CLIRouter.execute(arguments: [
            "task", "update", id.uuidString,
            "--status", "in_progress",
            "--progress", "0.6",
            "--tags", "后端, 搜索",
            "--file", file.path,
        ])

        let project = try KairoFile.load(from: file)
        let task = try #require(project.tasks.first)
        #expect(task.status == .inProgress)
        #expect(task.progress == 0.6)
        #expect(task.tags == ["后端", "搜索"])
    }

    @Test func taskListSupportsParentFilter() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "列表演示", "--file", file.path])
        let wbs = #"[{"title": "群组A", "children": [{"title": "子一"}, {"title": "子二"}]}]"#
        try Data(wbs.utf8).write(to: scratch.wbs)
        try CLIRouter.execute(arguments: ["wbs", "import", scratch.wbs.path, "--file", file.path])

        let project = try KairoFile.load(from: file)
        let group = try #require(project.tasks.first { $0.title == "群组A" })
        try CLIRouter.execute(arguments: ["task", "list", "--parent", group.id.uuidString, "--file", file.path])
    }
}

// MARK: - 错误契约与退出码

struct RouteErrorTests {
    @Test func unknownCommandThrowsUsageError() {
        #expect(throws: UsageError.self) {
            try CLIRouter.execute(arguments: ["frobnicate", "x"])
        }
    }

    @Test func missingOperandThrowsUsageError() {
        #expect(throws: UsageError.self) {
            try CLIRouter.execute(arguments: ["task", "get"])
        }
    }

    @Test func taskOnMissingFileReturnsRuntimeExitCode() throws {
        let code = CLIRouter.run(arguments: [
            "task", "list", "--file", "/nonexistent/kairo/demo.kairo",
        ])
        #expect(code == 1)
    }

    @Test func unknownCommandReturnsUsageExitCode() {
        #expect(CLIRouter.run(arguments: ["nope", "x"]) == 2)
    }

    @Test func updateRejectsDependencyFlag() {
        let code = CLIRouter.run(arguments: ["task", "update", UUID().uuidString, "--dep", "x:fs"])
        #expect(code == 2)
    }
}

// MARK: - Sprint 2 命令（schedule / status / resource）

struct Sprint2CommandTests {
    private func makeScratch() throws -> (dir: URL, kairo: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-cli2-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return (dir: dir, kairo: dir.appendingPathComponent("demo.kairo"))
    }

    @Test func scheduleComputeThenStatusUpdatePersistsCompletedAt() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "闭环演示", "--file", file.path])
        try CLIRouter.execute(arguments: ["task", "add", "任务 A", "--duration", "3", "--file", file.path])
        let groupID = try addTaskID(title: "群组 G", kind: "group", file: file)

        // 排期计算命令（含项目边界）不抛错。
        try CLIRouter.execute(arguments: [
            "schedule", "compute",
            "--start", "2026-11-02T00:00:00Z",
            "--end", "2026-11-16T00:00:00Z",
            "--file", file.path,
        ])
        // 重要路径命令。
        try CLIRouter.execute(arguments: ["schedule", "path", "--file", file.path])
        // 违例命令（此时应无违例）。
        try CLIRouter.execute(arguments: ["violations", "--file", file.path])

        // 状态回写：子任务完成 → completedAt 落盘。
        let childID = try addTaskID(title: "子一", kind: "task", file: file, parentID: groupID, effort: "4")
        try CLIRouter.execute(arguments: [
            "status", "update", childID.uuidString, "--status", "done", "--file", file.path,
        ])
        let project = try KairoFile.load(from: file)
        let child = try #require(project.tasks.first { $0.id == childID })
        #expect(child.status == .done)
        #expect(child.progress == 1)
        #expect(child.completedAt != nil)
    }

    @Test func resourceAddAndListPersist() throws {
        let scratch = try makeScratch()
        defer { try? FileManager.default.removeItem(at: scratch.dir) }
        let file = scratch.kairo

        try CLIRouter.execute(arguments: ["project", "create", "资源演示", "--file", file.path])
        try CLIRouter.execute(arguments: [
            "resource", "add", "李工", "--type", "person", "--units", "1", "--efficiency", "0.9", "--file", file.path,
        ])
        try CLIRouter.execute(arguments: ["resource", "list", "--file", file.path])

        let project = try KairoFile.load(from: file)
        #expect(project.resources.count == 1)
        #expect(project.resources.first?.name == "李工")
        #expect(project.resources.first?.kind == .person)
        #expect(project.resources.first?.efficiency == 0.9)
    }

    private func addTaskID(
        title: String, kind: String, file: URL, parentID: UUID? = nil, effort: String? = nil
    ) throws -> UUID {
        var args = ["task", "add", title, "--kind", kind, "--file", file.path]
        if let parentID { args += ["--parent", parentID.uuidString] }
        if let effort { args += ["--effort", effort] }
        try CLIRouter.execute(arguments: args)
        let project = try KairoFile.load(from: file)
        return try #require(project.tasks.first { $0.title == title }).id
    }
}

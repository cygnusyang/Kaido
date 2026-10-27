import Foundation
import Testing
import KairoCommands
import KairoCore
import KairoInterop
import InteropMSPDI
import InteropOmniPlan
@testable import KairoMacApp

/// 互操作 UI（v1.2 / 14 §P4）：预检报告、导入落地方式、导出产物与旁注。
///
/// 只测界面层能担保的事：报告来自同一份 `FidelityLedger`、取消不改项目、确认后新建项目、
/// 导出真的写出两个文件、菜单入口与文案键存在。格式内部映射由 InteropTests 覆盖。
@MainActor
@Suite("互操作导入 / 导出（应用侧）")
struct InteropUITests {
    // MARK: - 夹具

    private func makeStore(seedsDemoData: Bool = false) -> WorkspaceStore {
        let suite = "kairo.apptests.interop.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: seedsDemoData,
            projectLoader: { try KairoFile.read(from: $0) }
        )
    }

    /// 最小 MSPDI 样本：1 汇总 + 2 任务 + 1 里程碑，5 天工作周，1 条带 lag 的依赖，1 条 SNET 约束。
    private func mspdiFixture() -> Data {
        let weekdays = (1...7).map { day -> String in
            let working = (2...6).contains(day)
            let times = working
                ? """
                  <WorkingTimes>
                      <WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime>
                      <WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime>
                  </WorkingTimes>
                  """
                : ""
            return "<WeekDay><DayType>\(day)</DayType><DayWorking>\(working ? 1 : 0)</DayWorking>\(times)</WeekDay>"
        }.joined()
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <Project xmlns="http://schemas.microsoft.com/project">
            <SaveVersion>14</SaveVersion>
            <Name>fixture</Name>
            <Title>导入样本</Title>
            <CreationDate>2026-01-01T09:00:00</CreationDate>
            <LastSaved>2026-01-02T09:00:00</LastSaved>
            <ScheduleFromStart>1</ScheduleFromStart>
            <StartDate>2026-01-05T08:00:00</StartDate>
            <FinishDate>2026-01-30T17:00:00</FinishDate>
            <CalendarUID>1</CalendarUID>
            <MinutesPerDay>480</MinutesPerDay>
            <Calendars>
                <Calendar>
                    <UID>1</UID>
                    <Name>标准</Name>
                    <IsBaseCalendar>1</IsBaseCalendar>
                    <WeekDays>\(weekdays)</WeekDays>
                </Calendar>
            </Calendars>
            <Tasks>
                <Task>
                    <UID>1</UID><ID>1</ID><Name>阶段一</Name><OutlineLevel>1</OutlineLevel>
                    <Summary>1</Summary><Milestone>0</Milestone><IsNull>0</IsNull>
                </Task>
                <Task>
                    <UID>2</UID><ID>2</ID><Name>任务A</Name><OutlineLevel>2</OutlineLevel>
                    <Summary>0</Summary><Milestone>0</Milestone><IsNull>0</IsNull>
                    <Duration>PT40H0M0S</Duration><PercentComplete>0</PercentComplete>
                    <ConstraintType>4</ConstraintType><ConstraintDate>2026-01-06T08:00:00</ConstraintDate>
                    <CalendarUID>-1</CalendarUID>
                </Task>
                <Task>
                    <UID>3</UID><ID>3</ID><Name>任务B</Name><OutlineLevel>2</OutlineLevel>
                    <Summary>0</Summary><Milestone>0</Milestone><IsNull>0</IsNull>
                    <Duration>PT40H0M0S</Duration><PercentComplete>0</PercentComplete>
                    <CalendarUID>-1</CalendarUID>
                    <PredecessorLink>
                        <PredecessorUID>2</PredecessorUID><Type>1</Type><LinkLag>4800</LinkLag>
                    </PredecessorLink>
                </Task>
                <Task>
                    <UID>4</UID><ID>4</ID><Name>评审通过</Name><OutlineLevel>2</OutlineLevel>
                    <Summary>0</Summary><Milestone>1</Milestone><IsNull>0</IsNull>
                    <Duration>PT0H0M0S</Duration><CalendarUID>-1</CalendarUID>
                </Task>
            </Tasks>
        </Project>
        """
        return Data(xml.utf8)
    }

    private func writeFixture() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-interop-\(UUID().uuidString).xml")
        try mspdiFixture().write(to: url)
        return url
    }

    // MARK: - 预检报告来自 Ledger

    @Test func preflightRowsComeFromLedgerWithCounts() {
        var ledger = FidelityLedger()
        ledger.record(field: "cost", kind: .dropped, count: 3, detail: "成本丢弃", samples: ["标准费率", "固定成本"])
        ledger.record(field: "constraint", kind: .degraded, count: 2, detail: "硬约束转软")
        ledger.record(field: "calendar.workingWeekdays", kind: .converted, count: 4, detail: "工作周换算")
        let document = InteropDocument(
            tasks: [
                InteropTask(id: "1", title: "汇总", kind: .group),
                InteropTask(id: "2", title: "任务", kind: .task),
                InteropTask(id: "3", title: "里程碑", kind: .milestone),
            ]
        )
        let report = PreflightReport(
            formatID: MSPDIAdapter.formatID,
            formatVersion: "SaveVersion 14",
            summary: "3 任务",
            ledger: ledger
        )

        let preflight = ImportPreflight(
            document: document,
            report: report,
            ledger: ledger,
            fileName: "Plan.xml"
        )

        // 三块清单互不重叠：其他有损项、依赖降级、日历项各自只出现一次。
        #expect(preflight.losses.map(\.field) == ["cost"])
        #expect(preflight.losses.first?.kind == .dropped)
        #expect(preflight.losses.first?.count == 3)
        #expect(preflight.losses.first?.samples == ["标准费率", "固定成本"])
        #expect(preflight.dependencyLosses.map(\.field) == ["constraint"])
        #expect(preflight.dependencyLosses.first?.count == 2)
        #expect(preflight.calendarLosses.map(\.field) == ["calendar.workingWeekdays"])
        #expect(preflight.taskCount == 3)
        #expect(preflight.formatName == InteropFormats.displayName(for: MSPDIAdapter.formatID))
        // 规模行直接来自 IR 计数。
        #expect(preflight.scale.first { $0.id == "tasks" }?.value == 3)
        #expect(preflight.scale.first { $0.id == "groups" }?.value == 1)
        #expect(preflight.scale.first { $0.id == "milestones" }?.value == 1)
        #expect(preflight.copyText.contains("cost"))
    }

    /// 5 天工作周 → Kairo 按日历天推进：两条 5 工作日的链合计 10 天，按 7/5 - 1 = 40% 提前 4 天。
    @Test func preflightEstimatesCalendarAdvance() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore()
        try store.beginImport(from: url)

        let preflight = try #require(store.importPreflight)
        #expect(preflight.scale.first { $0.id == "tasks" }?.value == 4)
        #expect(preflight.scale.first { $0.id == "dependencies" }?.value == 1)
        let calendar = try #require(preflight.calendar)
        #expect(calendar.affectedTasks == 4)
        #expect(calendar.hoursPerDay == 8)
        #expect(calendar.estimatedAdvanceDays == 4)
        #expect(preflight.calendarLine(calendar).contains("4"))
        // 真实样本里的 SNET 约束与任务 id 丢失都要出现在预检里。
        #expect(preflight.dependencyLosses.contains { $0.field == "constraint" })
        #expect(preflight.losses.contains { $0.field == "taskID" })
        #expect(preflight.hasLosses)
    }

    // MARK: - 取消不改项目

    @Test func cancelImportLeavesProjectUntouched() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore()
        _ = try store.sessionForTesting.addTask(title: "原有任务")
        store.refresh()
        let revisionBefore = store.sessionForTesting.revision
        let tasksBefore = store.exportProject.tasks.map(\.title)

        try store.beginImport(from: url)
        #expect(store.importPreflight != nil)
        // 预检阶段就不得动项目：报告只是「会发生什么」。
        #expect(store.sessionForTesting.revision == revisionBefore)
        #expect(store.exportProject.tasks.map(\.title) == tasksBefore)

        store.cancelImport()
        #expect(store.importPreflight == nil)
        #expect(store.sessionForTesting.revision == revisionBefore)
        #expect(store.exportProject.tasks.map(\.title) == tasksBefore)
    }

    // MARK: - 确认后新建项目

    @Test func confirmImportCreatesNewProjectWithImportedTasks() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-import-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = makeStore()
        // 先把当前项目落到磁盘并保存干净：导入是「新建项目」，不该覆盖这份文档。
        _ = try store.sessionForTesting.addTask(title: "原有任务")
        let currentURL = directory.appendingPathComponent("current.kairo")
        try store.sessionForTesting.saveProject(to: currentURL)
        store.refresh()
        #expect(!store.hasUnsavedChanges)

        try store.beginImport(from: url)
        let expected = try #require(store.importPreflight).taskCount
        #expect(store.importBlockedReason == nil)
        store.confirmImport()

        #expect(store.importPreflight == nil)
        // 落地方式是新建项目：会话里是导入结果，且没有磁盘路径（尚未保存）。
        #expect(store.exportProject.tasks.count == expected)
        #expect(store.exportProject.tasks.contains { $0.title == "任务A" })
        #expect(store.projectURL == nil)
        #expect(store.hasUnsavedChanges, "新建项目尚未保存，应处于脏状态")
        // 原来的 .kairo 文件在磁盘上原样保留（不覆盖当前文档）。
        let reread = try KairoFile.read(from: currentURL)
        #expect(reread.project.tasks.map(\.title) == ["原有任务"])
    }

    @Test func importIsBlockedWhileProjectHasUnsavedChanges() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore()
        _ = try store.sessionForTesting.addTask(title: "未保存的任务")

        try store.beginImport(from: url)
        let blocked = try #require(store.importBlockedReason)

        store.confirmImport()
        // 置灰不是装饰：确认调用也必须拒绝，项目仍是原来那份。
        #expect(store.importPreflight != nil)
        #expect(store.exportProject.tasks.map(\.title) == ["未保存的任务"])
        #expect(blocked.contains("⌘S"))
    }

    // MARK: - 导出：XML + 旁注

    @Test func exportWritesXMLAndCompanionNotes() throws {
        let store = makeStore()
        let session = store.sessionForTesting
        _ = try session.createProject(title: "导出样本")
        let cancelledID = try session.addTask(title: "砍掉的任务")
        var patch = TaskPatch()
        patch.status = .cancelled
        patch.cancelReason = "预算冻结"
        _ = try session.updateTask(id: cancelledID, patch: patch)
        let blockedID = try session.addTask(title: "卡住的任务")
        var blockedPatch = TaskPatch()
        blockedPatch.status = .blocked
        _ = try session.updateTask(id: blockedID, patch: blockedPatch)
        let baseline = try session.createBaseline(name: "初版基线")
        #expect(baseline.name == "初版基线")
        store.refresh()

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-export-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let xmlURL = directory.appendingPathComponent("导出样本.xml")

        let notesURL = try store.exportMSProjectXML(to: xmlURL)

        #expect(FileManager.default.fileExists(atPath: xmlURL.path))
        #expect(notesURL.lastPathComponent == "导出样本.kairo-export-notes.md")
        #expect(FileManager.default.fileExists(atPath: notesURL.path))

        let xml = try String(contentsOf: xmlURL, encoding: .utf8)
        #expect(xml.contains("<Project"))
        #expect(xml.contains("<SaveVersion>14</SaveVersion>"))
        // 取消原因绝不写进对方文件（13 §5：不污染备注）。
        #expect(!xml.contains("预算冻结"))

        let notes = try String(contentsOf: notesURL, encoding: .utf8)
        // 边注里必须能查到取消原因与「单向快照」的边界说明。
        #expect(notes.contains("预算冻结"))
        #expect(notes.contains("cancelReason"))
        #expect(notes.contains("one-way snapshot"))
        // Kairo 独有信息的其余几条也必须进旁注（13 §5：不写进对方字段、只进旁注）。
        #expect(notes.contains("status"), "blocked 状态要在旁注里登记")
        #expect(notes.contains("baseline.color"))
        #expect(notes.contains("初版基线"))
        #expect(notes.contains("导出样本.xml"))
        #expect(notes.contains("SaveVersion 14"))
    }

    @Test func exportFilenameFollowsProjectTitle() {
        let store = makeStore()
        #expect(store.suggestedMSProjectFilename.hasSuffix(".xml"))
        #expect(!store.suggestedMSProjectFilename.hasSuffix(".kairo.xml"))
    }

    // MARK: - 视图

    /// 预检 sheet 必须真的画出内容：空面板会让「不可跳过」的清单变成一句都没得看的空白。
    @Test func preflightSheetRendersContent() throws {
        let url = try writeFixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let store = makeStore()
        try store.beginImport(from: url)
        let preflight = try #require(store.importPreflight)

        let snapshot = try #require(
            GUIRenderer.snapshot(
                ImportPreflightSheet(
                    preflight: preflight,
                    blockedReason: nil,
                    onCancel: {},
                    onConfirm: {}
                ),
                width: 640,
                height: 620
            )
        )
        #expect(snapshot.distinctColorCount > 5, "预检面板渲染成了空白或纯色")
    }

    // MARK: - 命令与文案

    @Test func commandCatalogExposesInteropEntries() throws {
        let store = makeStore()
        let commands = KairoCommandCatalog.make(store: store, requestOpen: {}, requestSave: {}, requestSaveAs: {})

        let importCommand = try #require(commands.first { $0.id == "project.import" })
        #expect(importCommand.group == .project)
        #expect(importCommand.isEnabled)
        #expect(importCommand.shortcut == nil)

        let exportXML = try #require(commands.first { $0.id == "project.exportMSProjectXML" })
        #expect(exportXML.group == .project)
        #expect(exportXML.isEnabled)

        // OmniPlan 写还没实现：入口在、但置灰并带说明（不留「功能不存在」的错觉）。
        let exportOmniPlan = try #require(commands.first { $0.id == "project.exportOmniPlan" })
        #expect(exportOmniPlan.group == .project)
        #expect(exportOmniPlan.isEnabled == false)
        #expect(exportOmniPlan.disabledHint?.isEmpty == false)
        #expect(InteropFormats.canWrite(formatID: OmniPlanAdapter.formatID) == false)
        #expect(InteropFormats.canWrite(formatID: MSPDIAdapter.formatID))

        // 「项目」分组：设置 + 导入 + 两个导出（逐条登记，数量变化会被看见）。
        #expect(commands.filter { $0.group == .project }.count == 4)
    }

    @Test func catalogHasInteropStringsInBothLanguages() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root.appendingPathComponent("Apps/macos/Resources/Localizable.xcstrings")
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let strings = try #require(object?["strings"] as? [String: Any])

        let keys = [
            "menu.project.import",
            "menu.project.export_mspdi",
            "menu.project.export_omniplan",
            "menu.project.export_omniplan.hint",
            "interop.import.title",
            "interop.import.confirm",
            "interop.import.copy",
            "interop.import.unsaved",
            "interop.import.panel.message",
            "interop.section.scale",
            "interop.section.calendar",
            "interop.section.dependencies",
            "interop.section.losses",
            "interop.calendar.summary",
            "interop.calendar.advance",
            "interop.losses.samples",
            "interop.notes.title",
            "interop.notes.one_way",
            "interop.notes.check.cancel_reason",
            "alert.export.done.title",
            "alert.export.done.message",
            "action.open_notes",
            "notice.import.done",
            "notice.export.done",
        ]
        for key in keys {
            let entry = try #require(strings[key] as? [String: Any], "Catalog 缺少键：\(key)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hans"] {
                let unit = try #require(
                    (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                    "键 \(key) 缺少 \(language) 译文"
                )
                let value = try #require(unit["value"] as? String)
                #expect(!value.isEmpty)
                // 中文侧不写英文兜底：除专有名词（MS Project XML / OmniPlan / Kairo）外应是中文。
                if language == "zh-Hans" {
                    #expect(value != "Import…" && value != "Cancel")
                }
            }
        }
    }
}

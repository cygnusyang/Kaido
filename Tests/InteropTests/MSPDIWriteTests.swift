import Foundation
import Testing
import KairoInterop
import InteropMSPDI

/// MSPDI 写出（P1）与往返对拍。
///
/// 判据分四层：
/// 1. **往返**：真实样本 → IR → 写 → 再读，计数与关键字段逐项相等；
/// 2. **幂等**：同一份 IR 写两次字节完全相同；
/// 3. **语义**：四类依赖、正负/小数前导、里程碑零工期、群组 Summary；
/// 4. **降级**：Kairo 独有信息只进 FidelityLedger，不进 XML（尤其不污染 Notes）。
@Suite("MSPDI 写出")
struct MSPDIWriteTests {
    private let adapter = MSPDIAdapter()

    private static let samplePath = ProcessInfo.processInfo.environment["KAIRO_MSPDI_SAMPLE"]
        ?? "/tmp/plb2012.xml"

    private static var sampleAvailable: Bool {
        FileManager.default.fileExists(atPath: samplePath)
    }

    private func loadSample() throws -> InteropDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.samplePath))
        return try adapter.read(data)
    }

    private func text(_ data: Data) -> String {
        String(decoding: data, as: UTF8.self)
    }

    private func date(_ value: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return formatter.date(from: value) ?? Date(timeIntervalSince1970: 0)
    }

    // MARK: - 往返

    @Test("真实样本往返：规模与 15-mpp-sample-analysis §2 一致", .enabled(if: sampleAvailable))
    func roundTripScale() throws {
        let original = try loadSample()
        let reread = try adapter.read(try adapter.write(original))

        #expect(reread.tasks.count == 187)
        #expect(reread.tasks.filter { $0.kind == .group }.count == 37)
        #expect(reread.tasks.filter { $0.kind == .milestone }.count == 2)
        #expect(reread.tasks.flatMap { $0.dependencies }.count == 126)
        #expect(reread.tasks.flatMap { $0.dependencies }.allSatisfy { $0.type == .finishToStart })
        #expect(reread.calendars.count == 3)
        #expect(reread.baselines.count == 4)
        #expect(reread.baselines.reduce(0) { $0 + $1.entries.count } == 478)
        #expect(reread.resources.count == 1)
        #expect(reread.assignments.count == 166)
        #expect(reread.customFields.count == 4)
    }

    @Test("真实样本往返：任务字段逐项相等", .enabled(if: sampleAvailable))
    func roundTripTasks() throws {
        let original = try loadSample()
        let reread = try adapter.read(try adapter.write(original))

        #expect(reread.tasks.map(\.id) == original.tasks.map(\.id))
        #expect(reread.tasks.map(\.title) == original.tasks.map(\.title))
        #expect(reread.tasks.map(\.notes) == original.tasks.map(\.notes))
        #expect(reread.tasks.map(\.kind) == original.tasks.map(\.kind))
        #expect(reread.tasks.map(\.outlineLevel) == original.tasks.map(\.outlineLevel))
        #expect(reread.tasks.map(\.parentID) == original.tasks.map(\.parentID))
        #expect(reread.tasks.map(\.plannedStart) == original.tasks.map(\.plannedStart))
        #expect(reread.tasks.map(\.plannedFinish) == original.tasks.map(\.plannedFinish))
        #expect(reread.tasks.map(\.durationSeconds) == original.tasks.map(\.durationSeconds))
        #expect(reread.tasks.map(\.effortHours) == original.tasks.map(\.effortHours))
        #expect(reread.tasks.map(\.progress) == original.tasks.map(\.progress))
        #expect(reread.tasks.map(\.actualStart) == original.tasks.map(\.actualStart))
        #expect(reread.tasks.map(\.actualFinish) == original.tasks.map(\.actualFinish))
        #expect(reread.tasks.map(\.dependencies) == original.tasks.map(\.dependencies))
        #expect(reread.tasks.map(\.constraint) == original.tasks.map(\.constraint))
        #expect(reread.tasks.map(\.calendarID) == original.tasks.map(\.calendarID))
        #expect(reread.tasks.map(\.attributes) == original.tasks.map(\.attributes))
    }

    @Test("真实样本往返：项目/日历/资源/分配/基线/自定义域逐项相等", .enabled(if: sampleAvailable))
    func roundTripStructure() throws {
        let original = try loadSample()
        let reread = try adapter.read(try adapter.write(original))

        #expect(reread.metadata.title == original.metadata.title)
        #expect(reread.metadata.author == original.metadata.author)
        #expect(reread.metadata.createdAt == original.metadata.createdAt)
        #expect(reread.metadata.lastSavedAt == original.metadata.lastSavedAt)
        #expect(reread.metadata.plannedStart == original.metadata.plannedStart)
        #expect(reread.metadata.plannedFinish == original.metadata.plannedFinish)
        #expect(reread.metadata.defaultCalendarID == original.metadata.defaultCalendarID)
        #expect(reread.metadata.direction == original.metadata.direction)

        #expect(reread.calendars.map(\.id) == original.calendars.map(\.id))
        #expect(reread.calendars.map(\.name) == original.calendars.map(\.name))
        #expect(reread.calendars.map(\.workingWeekdays) == original.calendars.map(\.workingWeekdays))
        #expect(reread.calendars.map(\.hoursPerDay) == original.calendars.map(\.hoursPerDay))
        #expect(reread.calendars.map(\.exceptions) == original.calendars.map(\.exceptions))

        #expect(reread.resources == original.resources)
        #expect(reread.assignments == original.assignments)
        #expect(reread.baselines.map(\.id) == original.baselines.map(\.id))
        #expect(reread.baselines.map(\.entries) == original.baselines.map(\.entries))
        #expect(reread.customFields == original.customFields)
    }

    // MARK: - 幂等

    @Test("同一份 IR 写两次字节完全相同", .enabled(if: sampleAvailable))
    func idempotent() throws {
        let document = try loadSample()
        let first = try adapter.write(document)
        let second = try adapter.write(document)
        #expect(first == second)
        #expect(!first.isEmpty)
    }

    @Test("空计划写出后可读回，且带 7 天全工作周日历")
    func emptyDocument() throws {
        let export = try adapter.export(InteropDocument(metadata: InteropMetadata(title: "空计划")))
        let reread = try adapter.read(export.data)
        #expect(reread.tasks.isEmpty)
        #expect(reread.calendars.count == 1)
        #expect(reread.calendars.first?.workingWeekdays == InteropCalendar.allWeekdays)
        #expect(reread.calendars.first?.hoursPerDay == 8)
        #expect(text(export.data).contains("<SaveVersion>14</SaveVersion>"))
    }

    @Test("能力声明：可写")
    func canWrite() {
        #expect(adapter.capabilities.canWrite)
        #expect(adapter.capabilities.canRead)
    }

    // MARK: - 语义

    @Test("四类依赖的 Type 口径与 lag 正负/小数")
    func dependencies() throws {
        let start = date("2026-01-05T08:00:00")
        var document = InteropDocument()
        document.metadata.plannedStart = start
        document.tasks = [
            InteropTask(id: "1", title: "前驱 A", plannedStart: start, durationSeconds: 28_800),
            InteropTask(id: "2", title: "前驱 B", plannedStart: start, durationSeconds: 28_800),
            InteropTask(id: "3", title: "前驱 C", plannedStart: start, durationSeconds: 28_800),
            InteropTask(id: "4", title: "前驱 D", plannedStart: start, durationSeconds: 28_800),
            InteropTask(
                id: "5",
                title: "后继",
                plannedStart: start,
                durationSeconds: 28_800,
                dependencies: [
                    InteropDependency(predecessorID: "1", type: .finishToStart, lagSeconds: 0),
                    InteropDependency(predecessorID: "2", type: .finishToFinish, lagSeconds: 3_600),
                    InteropDependency(predecessorID: "3", type: .startToStart, lagSeconds: -7_200),
                    InteropDependency(predecessorID: "4", type: .startToFinish, lagSeconds: 43_200)
                ]
            )
        ]

        let xml = text(try adapter.write(document))
        #expect(xml.contains("<Type>0</Type>"))
        #expect(xml.contains("<Type>1</Type>"))
        #expect(xml.contains("<Type>2</Type>"))
        #expect(xml.contains("<Type>3</Type>"))
        // 1 分钟 = 10 个十分之一分钟：1h=600、-2h=-1200、12h=7200。
        #expect(xml.contains("<LinkLag>600</LinkLag>"))
        #expect(xml.contains("<LinkLag>-1200</LinkLag>"))
        #expect(xml.contains("<LinkLag>7200</LinkLag>"))

        let reread = try adapter.read(try adapter.write(document))
        let links = try #require(reread.tasks.last?.dependencies)
        #expect(links.map(\.type) == [.finishToStart, .finishToFinish, .startToStart, .startToFinish])
        #expect(links.map(\.lagSeconds) == [0, 3_600, -7_200, 43_200])
    }

    @Test("里程碑写 PT0H0M0S，群组写 Summary=1 并保住父子层级")
    func kinds() throws {
        let start = date("2026-01-05T08:00:00")
        var document = InteropDocument()
        document.tasks = [
            InteropTask(id: "1", title: "阶段一", kind: .group, outlineLevel: 0, sequence: 0),
            InteropTask(
                id: "2",
                title: "子任务",
                outlineLevel: 1,
                sequence: 1,
                plannedStart: start,
                plannedFinish: start.addingTimeInterval(28_800),
                durationSeconds: 28_800
            ),
            InteropTask(
                id: "3",
                title: "评审通过",
                kind: .milestone,
                outlineLevel: 1,
                sequence: 2,
                plannedStart: start,
                plannedFinish: start,
                durationSeconds: 0
            )
        ]

        let xml = text(try adapter.write(document))
        #expect(xml.contains("<Summary>1</Summary>"))
        #expect(xml.contains("<Milestone>1</Milestone>"))
        #expect(xml.contains("<Duration>PT0H0M0S</Duration>"))

        let reread = try adapter.read(try adapter.write(document))
        #expect(reread.tasks.map(\.kind) == [.group, .task, .milestone])
        #expect(reread.tasks[1].parentID == "1")
        #expect(reread.tasks[2].parentID == "1")
        #expect(reread.tasks[2].durationSeconds == 0)
    }

    @Test("7 天日历与 5 天日历：前者保证日期一一对应，后者如实写出并登记")
    func calendarPolicy() throws {
        let start = date("2026-01-05T08:00:00")

        // 无日历（Kairo 默认 7 天）：写 7 天全工作周，日期可直接往返。
        var sevenDay = InteropDocument()
        sevenDay.tasks = [InteropTask(id: "1", title: "任务", plannedStart: start, durationSeconds: 28_800)]
        let sevenExport = try adapter.export(sevenDay)
        #expect(text(sevenExport.data).contains("<DayWorking>1</DayWorking>"))
        #expect(sevenExport.ledger.entry(field: "calendar.weekdays")?.kind == .converted)

        // 来源是 5 天工作周：如实写出，且把「日期可能漂移」登记给用户。
        var fiveDay = InteropDocument()
        fiveDay.calendars = [
            InteropCalendar(id: "1", name: "标准", workingWeekdays: [2, 3, 4, 5, 6], hoursPerDay: 8)
        ]
        fiveDay.metadata.defaultCalendarID = "1"
        fiveDay.tasks = [InteropTask(id: "1", title: "任务", plannedStart: start, durationSeconds: 28_800)]
        let fiveExport = try adapter.export(fiveDay)
        let entry = try #require(fiveExport.ledger.entry(field: "calendar.workingWeekdays"))
        #expect(entry.kind == .converted)
        #expect(entry.count == 1)
        #expect(entry.detail.contains("工作日推进"))
        #expect(text(fiveExport.data).contains("<DayType>1</DayType>"))
        let reread = try adapter.read(fiveExport.data)
        #expect(reread.calendars.first?.workingWeekdays == [2, 3, 4, 5, 6])
    }

    // MARK: - 降级

    @Test("Kairo 独有信息进 Ledger，不进 XML、不污染 Notes")
    func kairoOnlyGoesToLedger() throws {
        var document = InteropDocument(metadata: InteropMetadata(title: "导出样本"))
        document.customFields = [InteropCustomFieldDefinition(id: "188743731", fieldName: "Text1", alias: "差异时间")]
        document.tasks = [
            InteropTask(
                id: "1",
                title: "客户取消的任务",
                notes: "原有备注：与客户确认过范围",
                plannedStart: date("2026-01-05T08:00:00"),
                durationSeconds: 28_800,
                constraint: .startNoEarlierThan(date("2026-01-05T08:00:00")),
                attributes: [
                    "kairo.status": "cancelled",
                    "kairo.cancelReason": "客户取消：预算冻结",
                    "Text1": "差异值"
                ]
            )
        ]
        // 文档级 Kairo 独有信息由上层预置在 ledger 里（IR 不表达基线颜色）。
        document.ledger.record(
            field: "baseline.color",
            kind: .dropped,
            count: 1,
            detail: "基线颜色索引无法写入 MSPDI。",
            sample: "基线 1"
        )

        let export = try adapter.export(document)
        let xml = text(export.data)

        #expect(export.ledger.entry(field: "cancelReason")?.count == 1)
        #expect(export.ledger.entry(field: "cancelReason")?.samples == ["客户取消：预算冻结"])
        #expect(export.ledger.entry(field: "status")?.count == 1)
        #expect(export.ledger.entry(field: "baseline.color")?.count == 1)
        let constraint = try #require(export.ledger.entry(field: "constraint"))
        #expect(constraint.kind == .degraded)
        #expect(constraint.count == 1)

        // 原文备注保留；Kairo 独有信息既不进 Notes，也不出现在 XML 任何位置。
        #expect(xml.contains("原有备注：与客户确认过范围"))
        #expect(!xml.contains("客户取消：预算冻结"))
        #expect(!xml.contains("kairo."))
        #expect(xml.contains("差异值"))
    }

    @Test("基线超过 11 槽的部分被丢弃并登记")
    func baselineSlots() throws {
        var document = InteropDocument()
        let start = date("2026-01-05T08:00:00")
        document.tasks = [InteropTask(id: "1", title: "任务", plannedStart: start, durationSeconds: 28_800)]
        document.baselines = (0...11).map { number in
            InteropBaseline(
                id: String(number),
                entries: [InteropBaselineEntry(taskID: "1", start: start, finish: start.addingTimeInterval(28_800))]
            )
        }

        let export = try adapter.export(document)
        let slot = try #require(export.ledger.entry(field: "baseline.slot"))
        #expect(slot.kind == .dropped)
        #expect(slot.count == 1)
        #expect(export.ledger.entry(field: "baseline.color")?.count == 11)

        let reread = try adapter.read(export.data)
        #expect(reread.baselines.count == 11)
    }

    // MARK: - 结构合法性

    @Test("xmllint --noout 通过", .enabled(if: sampleAvailable))
    func wellFormedXML() throws {
        let export = try adapter.export(try loadSample())
        try assertWellFormed(export.data)
    }

    private func assertWellFormed(_ data: Data) throws {
        let tool = "/usr/bin/xmllint"
        guard FileManager.default.isExecutableFile(atPath: tool) else {
            // 没有 xmllint 就跳过：不把「未验证」伪装成「通过」。
            return
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-mspdi-export-\(UUID().uuidString).xml")
        try data.write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = ["--noout", url.path]
        let pipe = Pipe()
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let message = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        #expect(process.terminationStatus == 0, "xmllint 报错：\(message)")
    }
}

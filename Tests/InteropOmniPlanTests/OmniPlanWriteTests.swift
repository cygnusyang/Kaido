import Foundation
import Testing
import KairoInterop
@testable import InteropOmniPlan

/// OmniPlan 写出（.oplx）验收：容器、字段、往返与有损登记。
///
/// 判据来自 docs/features/11-interop-omniplan.md §7（885 B 最小容器已被 OmniPlan 4.10.3
/// 打开并回读）：写出的容器必须能被本通道读回同一份 IR，且真实样本往返后逐项相等。
@Suite("OmniPlan 写出（.oplx）")
struct OmniPlanWriteTests {
    private let adapter = OmniPlanAdapter()

    private static let samplePath = ProcessInfo.processInfo.environment["KAIRO_OMNIPLAN_SAMPLE"]
        ?? "/tmp/omniplan-sample.oplx"

    private static var sampleAvailable: Bool {
        FileManager.default.fileExists(atPath: samplePath)
    }

    // MARK: - 往返

    @Test("真实样本往返：26 任务 / 深度 4 / 4 资源 / 0 依赖 逐项相等", .enabled(if: sampleAvailable))
    func roundTripsRealSample() throws {
        let original = try adapter.read(Data(contentsOf: URL(fileURLWithPath: Self.samplePath)))
        let written = try adapter.write(original)
        #expect(adapter.sniff(written))

        let reread = try adapter.read(written)
        #expect(reread.tasks.count == 26)
        #expect(reread.tasks.filter { $0.kind == .group }.count == 10)
        #expect(reread.tasks.filter { $0.kind == .milestone }.count == 1)
        #expect(reread.tasks.map(\.outlineLevel).max() == 4)
        #expect(reread.resources.count == 4)
        #expect(reread.assignments.isEmpty)
        #expect(reread.tasks.flatMap(\.dependencies).isEmpty)

        // 逐项相等：id 复用、层级/顺序/父子、工时、约束、备注都必须原样回来。
        #expect(reread.tasks == original.tasks)
        #expect(reread.resources == original.resources)
        #expect(reread.assignments == original.assignments)
        #expect(reread.calendars.map(\.workingWeekdays) == original.calendars.map(\.workingWeekdays))
        #expect(reread.calendars.map(\.hoursPerDay) == original.calendars.map(\.hoursPerDay))
        #expect(reread.calendars.map(\.exceptions) == original.calendars.map(\.exceptions))
        #expect(reread.metadata.plannedStart == original.metadata.plannedStart)
        #expect(reread.metadata.defaultCalendarID == original.metadata.defaultCalendarID)
    }

    @Test("四类依赖样本往返：kind 与 lead 秒不变")
    func roundTripsDependencySample() throws {
        let original = try adapter.read(try OPLXFixture.committed("omniplan-four-dependencies.oplx"))
        let reread = try adapter.read(try adapter.write(original))

        #expect(reread.tasks == original.tasks)
        let edges = reread.tasks.flatMap { $0.dependencies }
        #expect(edges.count == 4)
        #expect(Set(edges.map(\.type)) == Set(InteropDependencyType.allCases))
        #expect(edges.contains { $0.type == .startToStart && abs($0.lagSeconds - 3600) < 0.5 })
        #expect(edges.contains { $0.type == .finishToFinish && abs($0.lagSeconds - 7200) < 0.5 })
        #expect(edges.contains { $0.type == .startToFinish && $0.lagSeconds == 0 })
        #expect(edges.contains { $0.type == .finishToStart && abs($0.lagSeconds - 1800) < 0.5 })
    }

    // MARK: - 字段覆盖

    @Test("写全字段：层级/种类/四型依赖/负 lead/分配/日历/工时换算")
    func writesEverySupportedField() throws {
        let document = featureDocument()
        let export = try adapter.export(document)
        let reread = try adapter.read(export.data)

        // Kairo 导出的是 1 起层级、多条顶层任务：写进一个空标题根群组。
        let root = try #require(reread.tasks.first)
        #expect(root.kind == .group)
        #expect(root.title.isEmpty)
        #expect(root.parentID == nil)
        #expect(root.outlineLevel == 0)
        #expect(reread.tasks.filter { $0.parentID == root.id }.map(\.title) == ["设计", "交付"])

        let design = try #require(reread.tasks.first { $0.title == "设计" })
        #expect(design.kind == .task)
        #expect(design.outlineLevel == 1)
        #expect(design.durationSeconds == 57_600)
        #expect(design.effortHours == 16)
        #expect(abs(design.progress - 0.5) < 0.0001)
        #expect(design.constraint == .startNoEarlierThan(Self.date(2026, 3, 2)))

        let group = try #require(reread.tasks.first { $0.title == "交付" })
        #expect(group.kind == .group)
        #expect(reread.tasks.filter { $0.parentID == group.id }.count == 3)

        let acceptance = try #require(reread.tasks.first { $0.title == "验收" })
        #expect(acceptance.kind == .milestone)
        #expect(acceptance.durationSeconds == nil)

        // 四型依赖 + 负 lead（lag）：FS 省略 kind，其余原样写出。
        let implementation = try #require(reread.tasks.first { $0.title == "实现" })
        let startStart = try #require(implementation.dependencies.first)
        #expect(startStart.type == .startToStart)
        #expect(abs(startStart.lagSeconds + 3600) < 0.5)

        let finishFinish = try #require(reread.tasks.first { $0.title == "验收" }?.dependencies.first)
        #expect(finishFinish.type == .finishToFinish)
        #expect(abs(finishFinish.lagSeconds - 7200) < 0.5)

        let startFinish = try #require(reread.tasks.first { $0.title == "收尾" }?.dependencies.first)
        #expect(startFinish.type == .startToFinish)
        #expect(abs(startFinish.lagSeconds - 1800) < 0.5)

        let finishStart = try #require(reread.tasks.first { $0.title == "复盘" }?.dependencies.first)
        #expect(finishStart.type == .finishToStart)
        #expect(finishStart.lagSeconds == 0)

        // 分配：idref + units。
        #expect(reread.assignments.count == 2)
        #expect(reread.resources.map(\.name) == ["团队", "设备"])
        #expect(reread.assignments.contains {
            $0.taskID == design.id && $0.resourceID == reread.resources[0].id && abs($0.units - 0.5) < 0.0001
        })
        #expect(reread.assignments.contains {
            $0.taskID == implementation.id && $0.resourceID == reread.resources[1].id && $0.units == 1
        })

        // 日历：schedule-day + hours-per-day + 整日例外。
        let calendar = try #require(reread.calendars.first)
        #expect(calendar.hoursPerDay == 16)
        #expect(calendar.workingWeekdays == Set(2...6))
        #expect(calendar.exceptions.contains { !$0.isWorking && $0.date == Self.date(2026, 2, 28) })
        #expect(calendar.exceptions.contains { $0.isWorking && $0.date == Self.date(2026, 3, 1) })

        // 层级最深 3：根(0) → 交付(1) → 实现(2) → 复盘(3)。
        #expect(reread.tasks.map(\.outlineLevel).max() == 3)

        let rootEntry = try #require(export.ledger.entry(field: "task.root"))
        #expect(rootEntry.kind == .derived)
    }

    @Test("没有日历时按 16 小时/日 写 duration-format")
    func defaultHoursPerDay() throws {
        var document = InteropDocument()
        document.tasks = [
            InteropTask(
                id: "t1",
                title: "单任务",
                outlineLevel: 1,
                sequence: 1,
                durationSeconds: 57_600,
                effortHours: 16
            )
        ]

        let export = try adapter.export(document)
        let reread = try adapter.read(export.data)
        let task = try #require(reread.tasks.first { $0.title == "单任务" })
        // 57 600 s ÷ (16 h × 3600) = 1 个工作日：写死 8 会让工期整体差一倍（11 §4）。
        #expect(task.durationSeconds == 57_600)
        #expect(reread.calendars.first?.hoursPerDay == 16)
        #expect(export.ledger.entry(field: "calendar.hoursPerDay")?.kind == .derived)
        // 没有日历也没有资源：不凭空造资源。
        #expect(reread.resources.isEmpty)
    }

    @Test("有日历没有资源：补一条项目资源承载项目日历")
    func synthesisesProjectResource() throws {
        var document = InteropDocument()
        document.calendars = [
            InteropCalendar(id: "cal", workingWeekdays: Set(2...6), hoursPerDay: 16)
        ]
        document.tasks = [
            InteropTask(id: "t1", title: "单任务", outlineLevel: 1, sequence: 1, durationSeconds: 28_800)
        ]

        let export = try adapter.export(document)
        let reread = try adapter.read(export.data)
        #expect(reread.resources.count == 1)
        #expect(reread.calendars.first?.workingWeekdays == Set(2...6))
        #expect(reread.calendars.first?.hoursPerDay == 16)
        #expect(export.ledger.entry(field: "resource.project")?.kind == .derived)
    }

    // MARK: - 有损登记

    @Test("写不回去的登记为 dropped：基线 / 自定义域 / Kairo 独有状态 / 费率换算不了的投入")
    func recordsDroppedInformation() throws {
        var document = InteropDocument(
            metadata: InteropMetadata(
                title: "年度计划",
                author: "作者",
                plannedFinish: Self.date(2026, 12, 31),
                defaultCalendarID: "cal-a"
            ),
            calendars: [
                InteropCalendar(id: "cal-a", hoursPerDay: 16),
                InteropCalendar(id: "cal-b", hoursPerDay: 8)
            ]
        )
        document.tasks = [
            InteropTask(
                id: "t1",
                title: "被取消的任务",
                outlineLevel: 1,
                sequence: 1,
                durationSeconds: 28_800,
                effortHours: 8,
                actualStart: Self.date(2026, 3, 2),
                calendarID: "cal-b",
                attributes: ["kairo.status": "cancelled", "kairo.cancelReason": "预算取消", "Text1": "差异"]
            )
        ]
        document.resources = [
            InteropResource(id: "r1", name: "顾问", kind: .person, units: 2)
        ]
        document.baselines = [
            InteropBaseline(
                id: "0",
                name: "初始基线",
                entries: [InteropBaselineEntry(taskID: "t1", start: Self.date(2026, 3, 2), finish: Self.date(2026, 3, 3))]
            )
        ]
        document.customFields = [InteropCustomFieldDefinition(id: "188743731", fieldName: "Text1", alias: "差异")]

        let export = try adapter.export(document)
        let ledger = export.ledger

        #expect(ledger.entry(field: "baseline")?.kind == .dropped)
        #expect(ledger.entry(field: "customField")?.kind == .dropped)
        #expect(ledger.entry(field: "task.kairoOnly")?.count == 2)
        #expect(ledger.entry(field: "task.attribute")?.count == 1)
        #expect(ledger.entry(field: "task.actual")?.count == 1)
        #expect(ledger.entry(field: "task.calendar")?.count == 1)
        #expect(ledger.entry(field: "resource.units")?.count == 1)
        #expect(ledger.entry(field: "calendar.multi")?.count == 1)
        #expect(ledger.entry(field: "project.title")?.kind == .dropped)

        // Kairo 独有信息不进对方字段：Actual.xml 里没有它们。
        let archive = try ZipArchive(data: export.data)
        let xml = try #require(
            String(data: try archive.requiredData(named: "Actual.xml"), encoding: .utf8)
        )
        #expect(!xml.contains("cancelled"))
        #expect(!xml.contains("预算取消"))
        #expect(!xml.contains("kairo."))
    }

    // MARK: - 容器

    @Test("容器：zip 里有 __TOC.xml 与 Actual.xml，版本 3，同一输入两次字节相同")
    func container() throws {
        let document = featureDocument()
        let first = try adapter.write(document)
        let second = try adapter.write(document)
        #expect(first == second)

        let archive = try ZipArchive(data: first)
        #expect(archive.entryNames == ["__TOC.xml", "Actual.xml"])

        let toc = try #require(
            String(data: try archive.requiredData(named: "__TOC.xml"), encoding: .utf8)
        )
        #expect(toc.contains("file-format-version=\"3\""))
        #expect(toc.contains(OmniPlanReader.namespace))
        #expect(toc.contains("<scenario id="))
        #expect(toc.contains("name=\"Actual\" filename=\"Actual.xml\""))
        #expect(toc.contains("hours-per-day=\"16\""))
        // next-task-id 必须大于所有已用编号（格式自洽要求，11 §7）。
        let next = try #require(Self.firstInteger(after: "<next-task-id>", in: toc))
        let numericIDs = try adapter.read(first).tasks.compactMap { Int($0.id.drop(while: { $0 == "t" })) }
        #expect(next > (numericIDs.max() ?? 0))
    }

    @Test("能力声明：可以写；空文档写出来是空计划")
    func capAndEmptyDocument() throws {
        #expect(adapter.capabilities.canWrite)
        let data = try adapter.write(InteropDocument())
        #expect(adapter.sniff(data))
        #expect(try adapter.read(data).tasks.isEmpty)
    }

    // MARK: - 样本

    private func featureDocument() -> InteropDocument {
        let tasks: [InteropTask] = [
            InteropTask(
                id: "task-design",
                title: "设计",
                kind: .task,
                outlineLevel: 1,
                sequence: 1,
                durationSeconds: 57_600,
                effortHours: 16,
                progress: 0.5,
                constraint: .startNoEarlierThan(Self.date(2026, 3, 2))
            ),
            InteropTask(
                id: "task-deliver",
                title: "交付",
                kind: .group,
                outlineLevel: 1,
                sequence: 2
            ),
            InteropTask(
                id: "task-implement",
                title: "实现",
                kind: .task,
                outlineLevel: 2,
                parentID: "task-deliver",
                sequence: 3,
                durationSeconds: 115_200,
                effortHours: 32,
                dependencies: [
                    InteropDependency(predecessorID: "task-design", type: .startToStart, lagSeconds: -3600)
                ]
            ),
            InteropTask(
                id: "task-accept",
                title: "验收",
                kind: .milestone,
                outlineLevel: 2,
                parentID: "task-deliver",
                sequence: 4,
                durationSeconds: 0,
                dependencies: [
                    InteropDependency(predecessorID: "task-implement", type: .finishToFinish, lagSeconds: 7200)
                ]
            ),
            InteropTask(
                id: "task-wrap",
                title: "收尾",
                kind: .task,
                outlineLevel: 2,
                parentID: "task-deliver",
                sequence: 5,
                durationSeconds: 7_200,
                effortHours: 2,
                dependencies: [
                    InteropDependency(predecessorID: "task-accept", type: .startToFinish, lagSeconds: 1800)
                ]
            ),
            InteropTask(
                id: "task-retro",
                title: "复盘",
                kind: .task,
                outlineLevel: 3,
                parentID: "task-wrap",
                sequence: 6,
                durationSeconds: 7_200,
                effortHours: 2,
                dependencies: [InteropDependency(predecessorID: "task-wrap")]
            )
        ]
        return InteropDocument(
            metadata: InteropMetadata(
                plannedStart: Self.date(2026, 3, 2),
                defaultCalendarID: "kairo-calendar"
            ),
            tasks: tasks,
            resources: [
                InteropResource(id: "res-team", name: "团队", kind: .person),
                InteropResource(id: "res-device", name: "设备", kind: .material)
            ],
            calendars: [
                InteropCalendar(
                    id: "kairo-calendar",
                    workingWeekdays: Set(2...6),
                    hoursPerDay: 16,
                    exceptions: [
                        InteropCalendarException(date: Self.date(2026, 2, 28), isWorking: false),
                        InteropCalendarException(date: Self.date(2026, 3, 1), isWorking: true)
                    ]
                )
            ],
            assignments: [
                InteropAssignment(taskID: "task-design", resourceID: "res-team", units: 0.5),
                InteropAssignment(taskID: "task-implement", resourceID: "res-device")
            ]
        )
    }

    private static func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components) ?? Date(timeIntervalSince1970: 0)
    }

    private static func firstInteger(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let tail = text[range.upperBound...].prefix(while: { $0.isNumber })
        return Int(tail)
    }
}

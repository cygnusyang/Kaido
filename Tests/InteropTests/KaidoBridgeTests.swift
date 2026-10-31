import Foundation
import Testing
import KaidoCore
import KaidoInterop

/// IR → Kaido 桥接（14-interop-architecture §2 硬规则 2）：换算只此一处。
///
/// 用例全部用手写的 IR，不经过任何 XML：这样桥接的正确性与具体格式解耦，
/// 后续接 OmniPlan 时同一批断言继续有效。
@Suite("IR → Kaido 桥接")
struct KaidoBridgeTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, hour: Int = 8) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))
            ?? Date(timeIntervalSince1970: 0)
    }

    private func makeDocument() -> InteropDocument {
        let start = date(2026, 1, 5)
        let finish = date(2026, 1, 6, hour: 17)
        let workCalendar = InteropCalendar(
            id: "1",
            name: "标准",
            workingWeekdays: [2, 3, 4, 5, 6],
            hoursPerDay: 8,
            exceptions: [
                InteropCalendarException(date: date(2026, 1, 1, hour: 0), isWorking: false, note: "元旦")
            ]
        )
        let tasks = [
            InteropTask(id: "1", title: "阶段一", kind: .group, outlineLevel: 0, sequence: 0),
            InteropTask(
                id: "2",
                title: "设计",
                outlineLevel: 1,
                sequence: 1,
                plannedStart: start,
                plannedFinish: finish,
                durationSeconds: 24 * 3_600,
                effortHours: 24,
                progress: 0.4,
                actualStart: start,
                constraint: .startNoEarlierThan(start),
                attributes: ["Text1": "差异 2 天"]
            ),
            InteropTask(
                id: "3",
                title: "评审",
                kind: .milestone,
                outlineLevel: 1,
                sequence: 2,
                plannedStart: finish,
                plannedFinish: finish,
                durationSeconds: 0
            ),
            InteropTask(
                id: "4",
                title: "开发",
                outlineLevel: 1,
                sequence: 3,
                durationSeconds: 8 * 3_600,
                dependencies: [
                    InteropDependency(predecessorID: "2", type: .finishToStart, lagSeconds: 28_800)
                ]
            )
        ]
        return InteropDocument(
            metadata: InteropMetadata(
                title: "桥接样本",
                createdAt: date(2026, 1, 1, hour: 9),
                lastSavedAt: date(2026, 1, 2, hour: 9),
                plannedStart: start,
                plannedFinish: finish,
                defaultCalendarID: "1"
            ),
            tasks: tasks,
            resources: [
                InteropResource(id: "1", name: "", kind: .person, units: 1),
                InteropResource(id: "2", name: "张三", kind: .person, units: 0.5)
            ],
            calendars: [workCalendar],
            assignments: [
                InteropAssignment(taskID: "2", resourceID: "2", units: 0.5),
                InteropAssignment(taskID: "3", resourceID: "99", units: 1)
            ],
            baselines: [
                InteropBaseline(
                    id: "0",
                    entries: [InteropBaselineEntry(taskID: "2", start: start, finish: finish)]
                )
            ],
            customFields: [InteropCustomFieldDefinition(id: "188743731", fieldName: "Text1", alias: "差异时间")]
        )
    }

    @Test("工期按来源工作日历换算成工作日数")
    func durationConversion() {
        let result = KaidoBridge().makeProject(from: makeDocument())
        let design = result.project.tasks.first { $0.title == "设计" }
        let development = result.project.tasks.first { $0.title == "开发" }
        let review = result.project.tasks.first { $0.title == "评审" }
        let phase = result.project.tasks.first { $0.title == "阶段一" }
        #expect(design?.durationDays == 3)
        #expect(development?.durationDays == 1)
        #expect(review?.durationDays == 0)
        #expect(phase?.durationDays == nil)
        #expect(design?.effortHours == 24)
    }

    @Test("前导时间从秒换算成工作日天")
    func lagConversion() throws {
        let result = KaidoBridge().makeProject(from: makeDocument())
        let development = try #require(result.project.tasks.first { $0.title == "开发" })
        #expect(development.dependencies.count == 1)
        #expect(development.dependencies.first?.lagDays == 1)
        #expect(development.dependencies.first?.type == .fs)
    }

    @Test("父子关系与种类")
    func hierarchy() {
        let result = KaidoBridge().makeProject(from: makeDocument())
        let phase = result.project.tasks.first { $0.title == "阶段一" }
        let design = result.project.tasks.first { $0.title == "设计" }
        #expect(phase?.kind == .group)
        #expect(design?.kind == .task)
        #expect(design?.parentID == phase?.id)
        #expect(result.project.tasks.first { $0.title == "评审" }?.kind == .milestone)
    }

    @Test("项目日历与例外日落进 Kaido 工作日历")
    func calendarBridge() throws {
        let result = KaidoBridge().makeProject(from: makeDocument())
        let bridged = try #require(result.project.calendar)
        #expect(bridged.workingWeekdays == Set([2, 3, 4, 5, 6]))
        #expect(bridged.hoursPerDay == 8)
        #expect(bridged.exceptions.count == 1)
        #expect(bridged.exceptions.first?.note == "元旦")
    }

    @Test("约束、进度与状态")
    func constraintAndStatus() throws {
        let document = makeDocument()
        let result = KaidoBridge().makeProject(from: document)
        let design = try #require(result.project.tasks.first { $0.title == "设计" })
        guard case .startNoEarlierThan(let expected)? = document.tasks.first(where: { $0.id == "2" })?.constraint else {
            Issue.record("样本应带开始不早于时限")
            return
        }
        #expect(design.constraint == .startNoEarlierThan(expected))
        #expect(design.status == .inProgress)
        #expect(design.progress == 0.4)
        #expect(design.actualStart != nil)
    }

    @Test("资源、分配与基线落地")
    func resourcesAndBaselines() throws {
        let result = KaidoBridge().makeProject(from: makeDocument())
        #expect(result.project.resources.count == 2)
        #expect(result.project.resources.contains { $0.name == "未命名资源" })
        let design = try #require(result.project.tasks.first { $0.title == "设计" })
        #expect(design.assignments.count == 1)
        #expect(design.assignments.first?.units == 0.5)
        let baseline = try #require(result.project.baselines.first)
        #expect(baseline.name == "基线 1")
        #expect(baseline.entries.count == 1)
        #expect(baseline.entries.first?.progress == 0)
    }

    @Test("有损登记覆盖来源侧与 Kaido 侧")
    func ledger() throws {
        let result = KaidoBridge().makeProject(from: makeDocument())
        let constraint = try #require(result.ledger.entry(field: "constraint"))
        #expect(constraint.kind == .degraded)
        #expect(constraint.count == 1)
        #expect(constraint.samples.first?.contains("开始不早于") == true)

        let calendar = try #require(result.ledger.entry(field: "calendar.workingWeekdays"))
        #expect(calendar.kind == .converted)
        #expect(calendar.count == 4)

        let customField = try #require(result.ledger.entry(field: "customField"))
        #expect(customField.kind == .dropped)
        #expect(customField.count == 1)

        #expect(result.ledger.entry(field: "taskID")?.count == 4)
        #expect(result.ledger.entry(field: "assignment")?.count == 1)
        #expect(result.ledger.entry(field: "resource.name")?.count == 1)
        #expect(result.ledger.entry(field: "baseline.progress")?.count == 1)
        #expect(result.ledger.entry(field: "baseline.createdAt")?.count == 1)
        #expect(!result.ledger.plainText.isEmpty)
    }

    @Test("来源侧登记与桥接侧登记合并，不重复计数")
    func ledgerMerging() throws {
        var document = makeDocument()
        document.ledger.record(field: "deadline", kind: .dropped, count: 2, detail: "Deadline 丢弃")
        document.ledger.record(field: "deadline", kind: .dropped, count: 3, detail: "Deadline 丢弃")
        let result = KaidoBridge().makeProject(from: document)
        let merged = try #require(result.ledger.entry(field: "deadline"))
        #expect(merged.count == 5)
    }

    @Test("空文档不崩、给出可用的空项目")
    func emptyDocument() {
        let result = KaidoBridge().makeProject(from: InteropDocument())
        #expect(result.project.tasks.isEmpty)
        #expect(result.project.resources.isEmpty)
        #expect(result.project.baselines.isEmpty)
        #expect(result.project.metadata.title == "未命名项目")
        #expect(result.project.calendar == nil)
        #expect(result.ledger.isEmpty)
    }

    @Test("全周 7 天日历不登记换算（与 Kaido 默认等价）")
    func defaultCalendarNeedsNoLedger() {
        var document = makeDocument()
        document.calendars = [InteropCalendar(id: "1", name: "全周", workingWeekdays: InteropCalendar.allWeekdays)]
        let result = KaidoBridge().makeProject(from: document)
        #expect(result.ledger.entry(field: "calendar.workingWeekdays") == nil)
    }
}

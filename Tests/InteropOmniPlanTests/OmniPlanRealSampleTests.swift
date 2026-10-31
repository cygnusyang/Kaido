import Foundation
import Testing
import KaidoCore
import KaidoInterop
import InteropOmniPlan

/// 真实样本验收（docs/features/11-interop-omniplan.md §5 的 PoC 数字）。
///
/// 样本是用户的真实计划，**不进仓库**：默认读 \`/tmp/omniplan-sample.oplx\`，
/// 可用环境变量 \`KAIDO_OMNIPLAN_SAMPLE\` 指向别处；文件不存在时用例自动跳过。
@Suite("OmniPlan 真实样本（Cygnus 个人任务）")
struct OmniPlanRealSampleTests {
    private static let samplePath = ProcessInfo.processInfo.environment["KAIDO_OMNIPLAN_SAMPLE"]
        ?? "/tmp/omniplan-sample.oplx"

    private static var sampleAvailable: Bool {
        FileManager.default.fileExists(atPath: samplePath)
    }

    private func loadDocument() throws -> InteropDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.samplePath))
        return try OmniPlanAdapter().read(data)
    }

    @Test("规模与 11 号文档 §5 对齐：26 任务 / 层级 4 / 4 资源 / 0 依赖", .enabled(if: sampleAvailable))
    func shape() throws {
        let document = try loadDocument()
        #expect(document.tasks.count == 26)
        #expect(document.tasks.filter { $0.kind == .group }.count == 10)
        #expect(document.tasks.filter { $0.kind == .milestone }.count == 1)
        #expect(document.tasks.filter { $0.kind == .task }.count == 15)
        #expect(document.tasks.map(\.outlineLevel).max() == 4)
        #expect(document.resources.count == 4)
        #expect(document.assignments.isEmpty)
        #expect(document.tasks.flatMap { $0.dependencies }.isEmpty)
        #expect(document.baselines.isEmpty)
        // 纯大纲：只有约束与工时，没有依赖。
        #expect(document.tasks.filter { $0.constraint != nil }.count == 25)
    }

    @Test("工时：15 支任务合计 1 411 200 秒，换算基准是 hours-per-day=16", .enabled(if: sampleAvailable))
    func effort() throws {
        let document = try loadDocument()
        let seconds = document.tasks.compactMap(\.durationSeconds).reduce(0, +)
        #expect(seconds == 1_411_200)

        let calendar = try #require(document.calendars.first)
        #expect(calendar.hoursPerDay == 16)
        #expect(calendar.workingWeekdays == Set(1...7))
        #expect(calendar.exceptions.isEmpty)

        let entry = try #require(document.ledger.entry(field: "calendar.hoursPerDay"))
        #expect(entry.kind == .converted)
        #expect(entry.samples == ["hours-per-day=16"])
    }

    @Test("有损登记：资源种类降级、资源日历与备注丢弃、锁定日期降级", .enabled(if: sampleAvailable))
    func ledger() throws {
        let document = try loadDocument()
        // Project / Equipment / Group 三种资源类型 IR 表达不了。
        #expect(document.ledger.entry(field: "resource.kind")?.count == 3)
        // 会议室与「设备和材料」各有自己的作息表，Kaido 没有资源日历。
        #expect(document.ledger.entry(field: "resource.calendar")?.count == 2)
        #expect(document.ledger.entry(field: "resource.notes")?.count == 2)
        #expect(document.ledger.entry(field: "constraint.locked")?.count == 1)
        // 会议室的 efficiency=0 在 Kaido 没有落点。
        #expect(document.ledger.entry(field: "resource.efficiency")?.count == 1)
        // 不制造假的丢失项：没有基线 scenario、没有成本、没有孤儿任务。
        #expect(document.ledger.entry(field: "baseline") == nil)
        #expect(document.ledger.entry(field: "cost") == nil)
        #expect(document.ledger.entry(field: "task.orphan") == nil)
    }

    @Test("桥接后：26 个 Kaido 任务、16h/日 工期、全周 7 天日历", .enabled(if: sampleAvailable))
    func bridgedProject() throws {
        let result = KaidoBridge().makeProject(from: try loadDocument())
        #expect(result.project.tasks.count == 26)
        #expect(result.project.tasks.filter { $0.kind == .group }.count == 10)

        let calendar = try #require(result.project.calendar)
        #expect(calendar.hoursPerDay == 16)
        #expect(calendar.workingWeekdays == WorkCalendar.allWeekdays)

        // 28800 s ÷ (16 h × 3600) = 0.5 工作日；1008000 s = 17.5 工作日。
        let halfDay = try #require(result.project.tasks.first { $0.title == "MBA中期" })
        #expect(halfDay.durationDays == 0.5)
        let opening = try #require(result.project.tasks.first { $0.title == "MBA开题" })
        #expect(opening.durationDays == 17.5)
        #expect(opening.effortHours == 280)

        // 大纲根节点没有标题，桥接层给占位名并登记。
        #expect(result.project.tasks.contains { $0.title.hasPrefix("未命名任务") })
        #expect(result.ledger.entry(field: "task.title")?.count == 1)
    }

    @Test("预检报告可直接给人看", .enabled(if: sampleAvailable))
    func preflight() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.samplePath))
        let report = try OmniPlanAdapter().preflight(data)
        #expect(report.formatVersion == "file-format-version 3")
        #expect(report.summary.contains("26 任务"))
        #expect(report.summary.contains("10 汇总"))
        #expect(report.summary.contains("1 里程碑"))
        #expect(!report.ledger.isEmpty)

        // 完整台账 = 适配器层 + 桥接追加：少了任何一侧都会低报损失。
        let document = try OmniPlanAdapter().read(data)
        #expect(report.irLedger == document.ledger)
        #expect(report.ledger.entries.count >= document.ledger.entries.count)
    }
}

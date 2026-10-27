import Foundation
import Testing
import KairoCore
import KairoInterop
import InteropMSPDI

/// 真实样本验收（docs/features/15-mpp-sample-analysis.md §2）。
///
/// 样本是客户真实计划，**不进仓库**：默认读 `/tmp/plb2012.xml`，
/// 可用环境变量 `KAIRO_MSPDI_SAMPLE` 指向别处；文件不存在时用例自动跳过。
@Suite("MSPDI 真实样本（PLB2012）")
struct MSPDIRealSampleTests {
    private static let samplePath = ProcessInfo.processInfo.environment["KAIRO_MSPDI_SAMPLE"]
        ?? "/tmp/plb2012.xml"

    private static var sampleAvailable: Bool {
        FileManager.default.fileExists(atPath: samplePath)
    }

    private func loadDocument() throws -> InteropDocument {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.samplePath))
        return try MSPDIAdapter().read(data)
    }

    @Test("规模与 15-mpp-sample-analysis §2 对齐", .enabled(if: sampleAvailable))
    func shape() throws {
        let document = try loadDocument()
        #expect(document.tasks.count == 187)
        #expect(document.tasks.filter { $0.kind == .group }.count == 37)
        #expect(document.tasks.filter { $0.kind == .milestone }.count == 2)
        #expect(document.tasks.flatMap { $0.dependencies }.count == 126)
        #expect(document.tasks.flatMap { $0.dependencies }.allSatisfy { $0.type == .finishToStart })
        #expect(document.calendars.count == 3)
        #expect(document.baselines.count == 4)
        #expect(document.resources.count == 1)
        #expect(document.assignments.count == 166)
        #expect(document.customFields.count == 4)
        #expect(document.metadata.title.hasPrefix("PLB2011"))
    }

    @Test("基线：4 条编号、478 条任务级记录", .enabled(if: sampleAvailable))
    func baselines() throws {
        let document = try loadDocument()
        #expect(document.baselines.map(\.id) == ["0", "1", "2", "3"])
        #expect(document.baselines.reduce(0) { $0 + $1.entries.count } == 478)
    }

    @Test("截止期与工时字段全空，不制造假的损失", .enabled(if: sampleAvailable))
    func noPhantomLoss() throws {
        let document = try loadDocument()
        #expect(document.ledger.entry(field: "deadline") == nil)
        #expect(document.ledger.entry(field: "cost") == nil)
        // 分配级基线（346 条）确实没有落点，必须登记。
        #expect(document.ledger.entry(field: "baseline.assignment")?.count == 346)
    }

    @Test("预检报告可直接给人看", .enabled(if: sampleAvailable))
    func preflight() throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: Self.samplePath))
        let report = try MSPDIAdapter().preflight(data)
        #expect(report.formatVersion == "SaveVersion 14")
        #expect(report.summary.contains("187 任务"))
        #expect(report.summary.contains("37 汇总"))
        #expect(report.summary.contains("2 里程碑"))
    }

    @Test("桥接后的有损登记：硬约束、日历换算、自定义域", .enabled(if: sampleAvailable))
    func bridgeLedger() throws {
        let result = KairoBridge().makeProject(from: try loadDocument())

        let constraint = try #require(result.ledger.entry(field: "constraint"))
        #expect(constraint.kind == .degraded)
        #expect(constraint.count == 97)
        #expect(constraint.samples.contains { $0.contains("开始不早于") || $0.contains("结束不早于") })

        let calendar = try #require(result.ledger.entry(field: "calendar.workingWeekdays"))
        #expect(calendar.kind == .converted)
        #expect(calendar.count == 187)
        #expect(calendar.samples.first == "周一至周五")

        // 166 条分配全部指向 Project 的「未分配」占位资源，Kairo 无处落地。
        #expect(result.ledger.entry(field: "assignment")?.count == 166)
        #expect(result.ledger.entry(field: "resource.name")?.count == 1)
        #expect(result.ledger.entry(field: "baseline.progress")?.count == 478)

        let customField = try #require(result.ledger.entry(field: "customField"))
        #expect(customField.kind == .dropped)
        #expect(customField.count == 4)
        #expect(customField.samples.count == 3)
        #expect(customField.samples.contains("Text1=差异时间"))
    }

    @Test("桥接后的项目形态", .enabled(if: sampleAvailable))
    func bridgedProject() throws {
        let result = KairoBridge().makeProject(from: try loadDocument())
        #expect(result.project.tasks.count == 187)
        #expect(result.project.tasks.flatMap { $0.dependencies }.count == 126)
        #expect(result.project.baselines.count == 4)

        let bridged = try #require(result.project.calendar)
        #expect(bridged.workingWeekdays == Set([2, 3, 4, 5, 6]))
        #expect(bridged.hoursPerDay == 8)
        // 春节 31 天 + 五一 5 天 + 调休上班 1 天。
        #expect(bridged.exceptions.count == 37)
        #expect(bridged.exceptions.filter { $0.isWorking }.count == 1)
    }
}

import Foundation
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

// v0.15 项目页「与基线对比」区块（docs/features/09-baseline-version-plan.md §4）。
//
// 视图不可直接断言文案，故区块的行集抽成纯函数 BaselineSummaryRows：
// 行集为空 ⇒ 视图整段不显示；数值格式（正号、占位符）在这里锁死。

@Suite("与基线对比区块（v0.15）")
@MainActor
struct BaselineSummaryRowsTests {
    private func makeSummary(
        finishVariance: Int? = nil,
        lateTaskCount: Int = 0,
        overdueOpenCount: Int = 0,
        tasksWithoutBaseline: Int = 0,
        predictedTaskCount: Int = 0,
        orphanCount: Int = 0
    ) -> ProjectBaselineSummary {
        ProjectBaselineSummary(
            baselineID: UUID(),
            name: "基线 1",
            createdAt: Date(timeIntervalSince1970: 1_760_000_000),
            finishVariance: finishVariance,
            lateTaskCount: lateTaskCount,
            overdueOpenCount: overdueOpenCount,
            tasksWithoutBaseline: tasksWithoutBaseline,
            predictedTaskCount: predictedTaskCount,
            orphanCount: orphanCount
        )
    }

    private func value(_ rows: [BaselineSummaryRows.Row], _ key: String) -> String? {
        rows.first { $0.labelKey == key }?.value
    }

    // MARK: - 显隐

    /// 未选基线：行集为空 → 视图不渲染该段，也不渲染任何占位行。
    @Test func rowsAreEmptyWithoutSummary() {
        #expect(BaselineSummaryRows.rows(for: nil).isEmpty)
    }

    /// 选中基线：每项都有一行，键唯一（同一段里不重复）。
    @Test func rowsCoverEveryFieldOnce() {
        let rows = BaselineSummaryRows.rows(for: makeSummary(finishVariance: 4))
        #expect(rows.count == 8)
        #expect(Set(rows.map(\.id)).count == rows.count)
        let expected = [
            "inspector.baseline.panel.name",
            "inspector.baseline.summary.created",
            "inspector.baseline.panel.finish_variance",
            "inspector.baseline.panel.late",
            "inspector.baseline.panel.overdue_open",
            "inspector.baseline.panel.without_entry",
            "inspector.baseline.panel.predicted",
            "inspector.baseline.panel.orphans",
        ]
        #expect(rows.map(\.labelKey) == expected)
    }

    // MARK: - 数值格式

    /// 结束偏差带符号：正 = 晚（补 +），负 = 提前（自带 -）。
    @Test func finishVarianceCarriesSign() {
        #expect(value(BaselineSummaryRows.rows(for: makeSummary(finishVariance: 4)),
                      "inspector.baseline.panel.finish_variance") == "+4")
        #expect(value(BaselineSummaryRows.rows(for: makeSummary(finishVariance: -2)),
                      "inspector.baseline.panel.finish_variance") == "-2")
        #expect(value(BaselineSummaryRows.rows(for: makeSummary(finishVariance: 0)),
                      "inspector.baseline.panel.finish_variance") == "0")
    }

    /// 空值走既有占位符，不写 0（0 是「准时」）。
    @Test func missingFinishVarianceUsesPlaceholder() {
        let rows = BaselineSummaryRows.rows(for: makeSummary(finishVariance: nil))
        #expect(value(rows, "inspector.baseline.panel.finish_variance") == Display.placeholder)
        #expect(value(rows, "inspector.baseline.panel.finish_variance") != "0")
    }

    /// 计数字段照原值呈现；名字与创建时间同样来自快照。
    @Test func countsAndIdentityComeFromSnapshot() {
        let summary = makeSummary(
            finishVariance: 3,
            lateTaskCount: 2,
            overdueOpenCount: 5,
            tasksWithoutBaseline: 1,
            predictedTaskCount: 4,
            orphanCount: 6
        )
        let rows = BaselineSummaryRows.rows(for: summary)
        #expect(value(rows, "inspector.baseline.panel.name") == "基线 1")
        #expect(value(rows, "inspector.baseline.summary.created") == Display.date(summary.createdAt))
        #expect(value(rows, "inspector.baseline.panel.late") == "2")
        #expect(value(rows, "inspector.baseline.panel.overdue_open") == "5")
        #expect(value(rows, "inspector.baseline.panel.without_entry") == "1")
        #expect(value(rows, "inspector.baseline.panel.predicted") == "4")
        #expect(value(rows, "inspector.baseline.panel.orphans") == "6")
    }

    /// 每个标签键都在 Catalog 里且有中英译文（键写错会在界面回落英文）。
    @Test func everyLabelKeyExistsInCatalog() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // AppTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // 仓库根
        let url = root.appendingPathComponent("Apps/macos/Resources/Localizable.xcstrings")
        let data = try Data(contentsOf: url)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let strings = try #require(object["strings"] as? [String: Any])

        for row in BaselineSummaryRows.rows(for: makeSummary(finishVariance: 1)) {
            let entry = try #require(strings[row.labelKey] as? [String: Any], "缺少键：\(row.labelKey)")
            let localizations = try #require(entry["localizations"] as? [String: Any])
            for language in ["en", "zh-Hans"] {
                let unit = try #require(
                    (localizations[language] as? [String: Any])?["stringUnit"] as? [String: Any],
                    "缺少 \(language) 译文：\(row.labelKey)"
                )
                #expect((unit["value"] as? String)?.isEmpty == false)
            }
        }
    }

    // MARK: - 接线（Store → 快照 → 行集）

    /// 新建基线即选中 → 区块出现；切回未选 → 区块整段消失。
    @Test func sectionFollowsBaselineSelection() throws {
        let suite = "kaido.v015.summary.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        store.dispatch(.select(nil))
        store.dispatch(.setBaseline(nil))
        guard case .project(let before) = store.snapshot.inspector.content else {
            Issue.record("取消选择后应显示项目页")
            return
        }
        #expect(before.baselineSummary == nil)
        #expect(BaselineSummaryRows.rows(for: before.baselineSummary).isEmpty)

        store.dispatch(.createBaseline(nil))
        guard case .project(let after) = store.snapshot.inspector.content else {
            Issue.record("取消选择后应显示项目页")
            return
        }
        let summary = try #require(after.baselineSummary)
        #expect(summary.name == store.baselines.first?.name)
        #expect(!BaselineSummaryRows.rows(for: after.baselineSummary).isEmpty)

        store.dispatch(.setBaseline(nil))
        guard case .project(let cleared) = store.snapshot.inspector.content else {
            Issue.record("取消选择后应显示项目页")
            return
        }
        #expect(cleared.baselineSummary == nil)
        #expect(BaselineSummaryRows.rows(for: cleared.baselineSummary).isEmpty)
    }
}

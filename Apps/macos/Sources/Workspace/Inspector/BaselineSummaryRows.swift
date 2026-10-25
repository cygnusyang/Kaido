import Foundation
import KairoPresentation

// MARK: - 与基线对比

/// 项目页「与基线对比」区块的行集（v0.15 / 09 §4）。
///
/// 抽成纯函数是为了让「整段显隐」与「数值格式」可单测：视图只做排版，
/// 判断依据只有一处——行集为空即整段不显示（未选基线时 summary 为 nil）。
/// value 已完成格式化（符号、占位符），标签交给 I18n.t 渲染。
enum BaselineSummaryRows {
    struct Row: Identifiable, Hashable, Sendable {
        /// i18n 键同时作为行身份：同一键在同一段里只出现一次。
        var id: String { labelKey }
        var labelKey: String
        var labelFallback: String
        var value: String
    }

    /// 未选基线（nil）返回空数组，调用方据此整段不显示；**不返回占位行**。
    static func rows(for summary: ProjectBaselineSummary?) -> [Row] {
        guard let summary else { return [] }
        return [
            Row(
                labelKey: "inspector.baseline.panel.name",
                labelFallback: "Comparing",
                value: summary.name
            ),
            Row(
                labelKey: "inspector.baseline.summary.created",
                labelFallback: "Created",
                value: Display.date(summary.createdAt)
            ),
            Row(
                labelKey: "inspector.baseline.panel.finish_variance",
                labelFallback: "Project finish variance",
                // 正 = 晚、负 = 提前、nil = 无数据（占位符），三者互不冒充。
                value: Display.varianceDays(summary.finishVariance)
            ),
            Row(
                labelKey: "inspector.baseline.panel.late",
                labelFallback: "Finished later",
                value: "\(summary.lateTaskCount)"
            ),
            Row(
                labelKey: "inspector.baseline.panel.overdue_open",
                labelFallback: "Overdue open",
                value: "\(summary.overdueOpenCount)"
            ),
            Row(
                labelKey: "inspector.baseline.panel.without_entry",
                labelFallback: "Added after baseline",
                value: "\(summary.tasksWithoutBaseline)"
            ),
            Row(
                labelKey: "inspector.baseline.panel.predicted",
                labelFallback: "Predicted (no actual finish)",
                value: "\(summary.predictedTaskCount)"
            ),
            Row(
                labelKey: "inspector.baseline.panel.orphans",
                labelFallback: "Deleted baseline tasks",
                value: "\(summary.orphanCount)"
            ),
        ]
    }
}

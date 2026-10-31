import Foundation
import ZenoPresentation

// MARK: - 挣值块

/// 项目页挣值块的行集（v1.3 / docs/features/17-evm-status-date.md §3、§5）。
///
/// 抽成纯函数是为了让「显示不显示数字」可单测：视图只排版，判断依据只有这里。
/// 三条硬规则：
/// - SPI 无定义（ΣPV = 0）→ 占位符 + 原因，**绝不写 0**；
/// - 没有计划价值时 SV 同样不给数字（拿 0 当读数会被读成「正好按计划」）；
/// - CPI / CV 恒为禁用态（`value` 恒为 nil）：没有费率与实际成本，不给任何数字。
enum EarnedValueRows {

    /// 一行读数。`value` 为 nil = 该行不给数字（禁用态），视图显示占位符并置灰。
    struct Row: Identifiable, Hashable, Sendable {
        /// i18n 键同时作为行身份：同一键在同一段里只出现一次。
        var id: String { labelKey }
        var labelKey: String
        var labelFallback: String
        var value: String?
        var isDisabled: Bool
        /// 行下说明（占位原因 / 可复现性提示）；nil = 不显示。
        var noteKey: String?
        var noteFallback: String?

        init(
            labelKey: String,
            labelFallback: String,
            value: String? = nil,
            isDisabled: Bool = false,
            noteKey: String? = nil,
            noteFallback: String? = nil
        ) {
            self.labelKey = labelKey
            self.labelFallback = labelFallback
            self.value = value
            self.isDisabled = isDisabled
            self.noteKey = noteKey
            self.noteFallback = noteFallback
        }
    }

    /// 一段只在块内出现的说明文字（成本禁用原因、已知局限）。
    struct Note: Identifiable, Hashable, Sendable {
        var id: String { key }
        var key: String
        var fallback: String
    }

    /// 数据日期 + SPI + SV。数据日期行同时承担「可复现 / 不可复现」的提示。
    static func rows(for summary: EarnedValueSummary) -> [Row] {
        let hasPlannedValue = summary.plannedValue > 0
        return [
            Row(
                labelKey: "inspector.evm.status_date",
                labelFallback: "Status date",
                value: Display.date(summary.statusDate),
                noteKey: summary.isStatusDateFixed
                    ? "inspector.evm.status_date.fixed"
                    : "inspector.evm.status_date.unfixed",
                noteFallback: summary.isStatusDateFixed
                    ? "Fixed: every look uses this date, so the report is reproducible."
                    : "Not fixed: computed against today, so the same report differs tomorrow."
            ),
            Row(
                labelKey: "inspector.evm.spi",
                labelFallback: "SPI",
                value: Display.performanceIndex(summary.schedulePerformanceIndex),
                noteKey: summary.schedulePerformanceIndex == nil
                    ? "inspector.evm.spi.no_planned_value"
                    : nil,
                noteFallback: summary.schedulePerformanceIndex == nil
                    ? "No planned value yet (status date is before planned start)."
                    : nil
            ),
            Row(
                labelKey: "inspector.evm.sv",
                labelFallback: "SV (hours)",
                // 没有计划价值时 SV 也没有参照物：给占位符，避免 0 被读成「正好按计划」。
                value: Display.varianceHours(hasPlannedValue ? summary.scheduleVariance : nil),
                isDisabled: !hasPlannedValue
            ),
        ]
    }

    /// 成本绩效两行：本版没有费率与实际成本，恒为禁用态且不给任何数字。
    ///
    /// 保留行本身（而不是整段隐藏）是刻意的：用户找 CPI 时应当看到「为什么没有」，
    /// 而不是以为这功能藏在别处。
    static func costRows() -> [Row] {
        [
            Row(labelKey: "inspector.evm.cpi", labelFallback: "CPI", isDisabled: true),
            Row(labelKey: "inspector.evm.cv", labelFallback: "CV", isDisabled: true),
        ]
    }

    /// 成本绩效禁用原因（说明为什么一行数字都没有）。
    static let costDisabledNote = Note(
        key: "inspector.evm.cost.disabled",
        fallback: "Cost and rates are not enabled, so cost performance cannot be computed."
    )

    /// §5 的两句已知局限：必须与读数一并显示，不许藏。
    static let limitations: [Note] = [
        Note(
            key: "inspector.evm.limit.spi_end",
            fallback: "SPI converges to 1 at the end of a project; use it for the trend while work is in progress."
        ),
        Note(
            key: "inspector.evm.limit.effort_profile",
            fallback: "In hours terms, an early SPI runs high when the workload is front-loaded."
        ),
    ]
}

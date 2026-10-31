import Foundation
import KaidoCore

/// 项目页挣值块（v1.3 / 17-evm-status-date §3、§5）。
///
/// 只搬运 `EarnedValueReport` 的读数，不做二次计算——同一份报表在检查器与 CLI/MCP
/// 上必须是同一口径（ADR-013）。单位是**小时**：本版只做工时口径，没有费率也没有实际成本。
///
/// `schedulePerformanceIndex` 为 `nil` 表示**还没有任何计划工作量到期**（ΣPV = 0），
/// 视图必须显示占位符：写成 0 会被读成「完全没进度」，写成 ∞ 会被读成「无限超前」。
public struct EarnedValueSummary: Hashable, Sendable {
    /// 本次观察时点（已归一到当日 00:00）。
    public var statusDate: Date
    /// 观察时点是否由用户固定。`false` = 每次按当天算，报告不可复现。
    public var isStatusDateFixed: Bool
    /// ΣPV（小时）。
    public var plannedValue: Double
    /// ΣEV（小时）。
    public var earnedValue: Double
    /// 进度偏差 SV = ΣEV − ΣPV（小时）；正数 = 比计划提前。
    public var scheduleVariance: Double
    /// 进度绩效指数 SPI = ΣEV / ΣPV；ΣPV = 0 时为 `nil`。
    public var schedulePerformanceIndex: Double?
    /// 未参与计算的任务数（已取消 / 群组 / 父任务 / 无有效排期）。
    public var excludedTaskCount: Int

    public init(
        statusDate: Date,
        isStatusDateFixed: Bool,
        plannedValue: Double,
        earnedValue: Double,
        scheduleVariance: Double,
        schedulePerformanceIndex: Double?,
        excludedTaskCount: Int = 0
    ) {
        self.statusDate = statusDate
        self.isStatusDateFixed = isStatusDateFixed
        self.plannedValue = plannedValue
        self.earnedValue = earnedValue
        self.scheduleVariance = scheduleVariance
        self.schedulePerformanceIndex = schedulePerformanceIndex
        self.excludedTaskCount = excludedTaskCount
    }

    /// 从计算层报表收口：字段一一对应，不改口径。
    public init(report: EarnedValueReport) {
        self.init(
            statusDate: report.statusDate,
            isStatusDateFixed: report.isStatusDateFixed,
            plannedValue: report.plannedValue,
            earnedValue: report.earnedValue,
            scheduleVariance: report.scheduleVariance,
            schedulePerformanceIndex: report.schedulePerformanceIndex,
            excludedTaskCount: report.excludedTaskCount
        )
    }
}

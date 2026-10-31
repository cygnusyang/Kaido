import Foundation
import ZenoCore

/// 顺延留痕行（F-22-06 / D3）：`CalendarAdjustment` 的展示投影。
///
/// 只带数据、不带文案——与 `ViolationItem` 同一策略（ADR-013）：快照跨 UI / CLI / MCP 复用，
/// 把整句文案塞进快照会把接口层的语言策略绑死在呈现层。视图按 Catalog 组装
/// 「已从 X 顺延到 Y（原因）」。
public struct CalendarAdjustmentRow: Identifiable, Hashable, Sendable {
    /// 稳定标识：同一任务可能同时有「开始日」与「约束日」两条留痕，
    /// 三要素（类型 + 原值 + 结果）全带上才不会在 `ForEach` 里撞 id。
    public var id: String
    /// 顺延原因（非工作日 / 工作日历不可用而退化）。
    public var kind: CalendarAdjustment.Kind
    /// 用户给出的原始日期。
    public var requested: Date
    /// 实际参与排期的日期。
    public var adjusted: Date

    public init(kind: CalendarAdjustment.Kind, requested: Date, adjusted: Date) {
        self.kind = kind
        self.requested = requested
        self.adjusted = adjusted
        self.id = "\(kind.rawValue)|\(requested.timeIntervalSince1970)|\(adjusted.timeIntervalSince1970)"
    }

    /// 按任务过滤并保序：引擎按任务顺序输出，同一任务内按发现顺序。
    ///
    /// `taskID == nil` 的是**项目级**说明（工作周为空已退化为全周），不属于任何任务，
    /// 这里自然过滤掉——它属于项目页，不该出现在任务检查器里。
    public static func rows(
        from adjustments: [CalendarAdjustment],
        taskID: UUID
    ) -> [CalendarAdjustmentRow] {
        adjustments
            .filter { $0.taskID == taskID }
            .map {
                CalendarAdjustmentRow(
                    kind: $0.kind,
                    requested: $0.requested,
                    adjusted: $0.adjusted
                )
            }
    }
}

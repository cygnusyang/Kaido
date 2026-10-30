import Foundation
import KairoCore

/// 窗口外任务覆盖度（D-040 / D-043）。
///
/// 启动窗口锚今天：项目整体在过去、或大量任务落在当前窗口之外时，画布一片空白，
/// 用户无从判断「条去哪了」。本类型把「有多少条看不见、在窗口哪一侧」算成两个
/// 字节级的值，供视图给出提示与「适合项目」入口。
///
/// **口径必须来自排期区间，不能拿画布上的条反推**：`GanttLayout.make` 会把完全落在
/// 窗口外的条整条丢掉（`guard finish > windowStart, start < windowEnd`），拿布局结果
/// 统计恒为 0（v1.4.0 实测：4 条任务、窗口只含 1 条时仍报 0）。因此统计只吃
/// `ScheduleResult` + 窗口区间，与布局各算各的、互为补集。
public struct GanttWindowCoverage: Hashable, Sendable {
    /// 外溢方向：条相对可见窗口的位置。
    public enum Side: Hashable, Sendable {
        /// 外溢条全部在窗口左侧（任务早于窗口起点）。
        case before
        /// 外溢条全部在窗口右侧（任务晚于窗口终点）。
        case after
        /// 两侧各有外溢条。
        ///
        /// 同时是「没有外溢条」时的取值：`offWindowCount == 0` 时方向无从谈起，
        /// 这里取一个确定值而不是 `Optional`，让快照保持 `Hashable` 且调用方无需解包；
        /// 视图按 `offWindowCount > 0` 决定是否展示，不读该值。
        case both
    }

    /// 完全落在可见窗口之外的条数。
    public let offWindowCount: Int
    /// 外溢方向（`offWindowCount == 0` 时为 `.both`，见上）。
    public let side: Side

    public init(offWindowCount: Int, side: Side) {
        self.offWindowCount = offWindowCount
        self.side = side
    }

    /// 「没有窗口外任务」：视图不展示提示时的取值。
    public static let none = GanttWindowCoverage(offWindowCount: 0, side: .both)

    /// 按排期区间统计窗口外条数。
    ///
    /// - Parameters:
    ///   - schedule: 当前排期结果（`unscheduledTaskIDs` 里的任务不参与统计）。
    ///   - windowStart: 可见窗口起点（含）。
    ///   - windowEnd: 可见窗口终点（不含）。
    ///   - visibleTaskIDs: 可见行集合；提供时只统计这些行（筛选下的口径与大纲/
    ///     画布一致），为 nil 时不限。
    /// - Returns: 外溢条数与方向。
    ///
    /// **边界取等**：`finish <= windowStart` 算左侧外溢、`start >= windowEnd` 算右侧
    /// 外溢——左边缘正好压在窗口起点、右边缘正好压在窗口终点的条一个像素也画不出来，
    /// 算「在窗口内」会让提示在真正空白的画面上消失。
    public static func compute(
        schedule: ScheduleResult?,
        windowStart: Date,
        windowEnd: Date,
        visibleTaskIDs: Set<UUID>? = nil
    ) -> Self {
        guard let schedule else { return .none }
        let unscheduledIDs = Set(schedule.unscheduledTaskIDs)
        var before = 0
        var after = 0
        for entry in schedule.tasks where !unscheduledIDs.contains(entry.taskID) {
            if let visibleTaskIDs, !visibleTaskIDs.contains(entry.taskID) { continue }
            if entry.scheduledFinish <= windowStart {
                before += 1
            } else if entry.scheduledStart >= windowEnd {
                after += 1
            }
        }
        let side: Side
        if before > 0 && after > 0 {
            side = .both
        } else if before > 0 {
            side = .before
        } else if after > 0 {
            side = .after
        } else {
            side = .both
        }
        return Self(offWindowCount: before + after, side: side)
    }
}

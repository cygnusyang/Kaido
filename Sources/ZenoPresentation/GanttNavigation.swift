import Foundation
import ZenoCore

/// 排期整体落在可见窗口的哪一侧（D-054）。
///
/// 与「今天在窗口哪一侧」（`TodaySide`）分开：那个是时间基准的方向，
/// 这个是**排期区间**的方向——用户在排期之外时，箭头要指向排期，而不是指向今天。
public enum OffScheduleSide: String, Codable, Hashable, Sendable {
    /// 排期整体晚于窗口（窗口停在排期之前，需要往后看）。
    case ahead
    /// 排期整体早于窗口（窗口滑过了排期，需要往回看）。
    case behind
}

/// 画布右上角的导航入口（D-054）。
///
/// 只表达「为什么需要入口 + 点它做什么」，不含文案与颜色：视图按 case 取词条、
/// 按 `action` 派发。两个 case 互斥，优先级由 `GanttSchedulePlacement.navigation`
/// 统一裁定（排期之外 > 有外溢条），视图不自己再判一遍。
public enum GanttNavigation: Hashable, Sendable {
    /// 窗口与排期区间**不相交**：整块画布都是空的，入口把窗口搬回排期。
    case offSchedule(OffScheduleSide)
    /// 窗口与排期相交但仍有条完全在窗口外：入口铺满整个项目。
    case offWindow

    /// 点击入口应派发的动作。
    public var action: WorkspaceAction {
        switch self {
        case .offSchedule: return .returnToSchedule
        case .offWindow: return .setFitZoom(true)
        }
    }
}

/// 窗口与排期区间的几何关系（D-054，纯函数、无 AppKit）。
///
/// **口径来自排期结果，不拿画布上的条反推**：`GanttLayout` 会把完全落在窗口外的条
/// 整条丢掉，用它统计只会得到「一条都不在窗口外」。这与 `GanttWindowCoverage`
/// 同源，边界也同一口径——左右边缘正好压在窗口端点上的条一个像素也画不出来，
/// 算「相交」会让入口在真正空白的画面上消失。
public enum GanttSchedulePlacement {
    /// 已排期任务的时间跨度：`[min scheduledStart, max scheduledFinish]`。
    ///
    /// 只吃排期条目：`unscheduledTaskIDs` 里的任务没有日期可言，参与取最值会把
    /// 区间撑到无意义的方向。**不含** `projectStart` / `projectEnd` 锚点——锚点
    /// 代表项目计划的边框，用户说的「任务排期的周期」是任务本身的首尾。
    ///
    /// - Parameter schedule: 当前排期结果；nil 或一条已排期任务都没有时返回 nil。
    /// - Returns: 任务跨度；`duration` 可能为 0（单点里程碑），不会是负值。
    public static func taskRange(of schedule: ScheduleResult?) -> DateInterval? {
        guard let schedule else { return nil }
        let unscheduled = Set(schedule.unscheduledTaskIDs)
        var start: Date?
        var end: Date?
        for entry in schedule.tasks where !unscheduled.contains(entry.taskID) {
            start = start.map { min($0, entry.scheduledStart) } ?? entry.scheduledStart
            end = end.map { max($0, entry.scheduledFinish) } ?? entry.scheduledFinish
        }
        guard let start, let end else { return nil }
        // 排期结果若给出 finish < start（数据损坏），按单点处理，不让区间倒挂。
        return DateInterval(start: start, end: max(start, end))
    }

    /// 窗口与排期区间不相交时，排期在窗口的哪一侧。
    ///
    /// - Parameters:
    ///   - windowStart: 可见窗口起点（含）。
    ///   - windowEnd: 可见窗口终点（不含）。
    ///   - schedule: 当前排期结果（`unscheduledTaskIDs` 不参与）。
    /// - Returns: `.ahead` = 排期整体晚于窗口；`.behind` = 排期整体早于窗口；
    ///   相交（或没有排期）时 nil，视图据此不展示入口。
    ///
    /// **边界取等**：`windowEnd == schedule.start` 算「窗口停在排期之前」
    /// （半开区间里排期首日恰好被排除在窗口外），`windowStart == schedule.end`
    /// 同理算「已滑过排期」。与 `GanttWindowCoverage.compute` 的取等一致。
    public static func offScheduleSide(
        windowStart: Date,
        windowEnd: Date,
        schedule: ScheduleResult?
    ) -> OffScheduleSide? {
        guard let range = taskRange(of: schedule) else { return nil }
        if windowEnd <= range.start { return .ahead }
        if windowStart >= range.end { return .behind }
        return nil
    }

    /// 「回到排期」的目标窗口起点。
    ///
    /// - `.ahead`：窗口落在排期之前 ⇒ 起点取排期首日的零点，排期从窗口左边缘开始。
    /// - `.behind`：窗口滑过了排期 ⇒ 起点取「排期终点减窗口时长」的零点，
    ///   让排期终点贴着窗口右边缘；再夹到不早于排期首日零点，短排期时窗口最多
    ///   对齐到排期起点，不会把整个排期推到窗口右缘之外。
    ///
    /// 只算**起点**：窗口宽度属于用户的缩放选择，回到排期不该顺手改它。
    ///
    /// - Parameters:
    ///   - windowStart: 当前可见窗口起点。
    ///   - windowEnd: 当前可见窗口终点。
    ///   - schedule: 排期区间（`taskRange(of:)` 的结果）。
    ///   - side: 排期在窗口的哪一侧（`offScheduleSide` 的结果）。
    ///   - calendar: 日界与零点的来源。
    /// - Returns: 目标窗口起点（已归一到当日零点）。
    public static func returnStart(
        windowStart: Date,
        windowEnd: Date,
        schedule: DateInterval,
        side: OffScheduleSide,
        calendar: Calendar
    ) -> Date {
        let scheduleDayStart = calendar.startOfDay(for: schedule.start)
        switch side {
        case .ahead:
            return scheduleDayStart
        case .behind:
            // 窗口时长按真实秒差取（亚日精度的窗口也一样）：落点必须让排期终点
            // 落在窗口内，而不是「相差几天」的近似。
            //
            // **取整口径（产品裁定）**：落点一律归一到当日零点，所以右缘可能差不足一天的
            // 小数（起点被 floor 后会整体前移）。判据因此是
            // `windowStart + span >= schedule.end − 1 天`，不是严格 `>=`。
            // 不要为了严格大于改成 ceil 或让起点不归零：窗口起点不落在日界上会让
            // 日刻度与拖拽预览的相位全部错位，代价远大于一天的边缘余量。
            let span = max(windowEnd.timeIntervalSince(windowStart), 0)
            let candidate = calendar.startOfDay(
                for: schedule.end.addingTimeInterval(-span)
            )
            return max(candidate, scheduleDayStart)
        }
    }

    /// 画布导航入口的裁定（D-054）：先看窗口是否整个离开排期，再看有没有外溢条。
    ///
    /// 排期之外优先于「还有 N 条在窗口外」：前者画布是全空的，只说「还有几条」
    /// 解决不了「一条都看不见」，且两个入口同时出现会互相竞争注意力。
    ///
    /// - Parameters:
    ///   - windowStart: 可见窗口起点（含）。
    ///   - windowEnd: 可见窗口终点（不含）。
    ///   - schedule: 当前排期结果。
    ///   - offWindowCount: 完全落在窗口外的条数（`GanttWindowCoverage.offWindowCount`）。
    /// - Returns: 需要展示的入口；窗口与排期相交且无外溢条时为 nil。
    public static func navigation(
        windowStart: Date,
        windowEnd: Date,
        schedule: ScheduleResult?,
        offWindowCount: Int
    ) -> GanttNavigation? {
        if let side = offScheduleSide(
            windowStart: windowStart,
            windowEnd: windowEnd,
            schedule: schedule
        ) {
            return .offSchedule(side)
        }
        return offWindowCount > 0 ? .offWindow : nil
    }
}

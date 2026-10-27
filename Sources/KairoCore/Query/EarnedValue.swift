import Foundation

/// 单任务的挣值分解（17-evm-status-date §4）。
///
/// 口径是**工时**：`effortHours` 是权重，`plannedValue` / `earnedValue` 的单位都是小时。
/// 数值是「到数据日期为止」的累计量，不是增量——同一任务只出现一行。
///
/// 只收录**参与计算**的任务：已排期、未取消、且是叶子（非群组、无子项）。
/// 群组与父任务的时间窗来自子树聚合，把它们的投入也算一遍就是重复计工作量。
public struct EarnedValueTask: Codable, Hashable, Sendable {
    public var taskID: UUID
    /// 计划开始（排期结果的半开区间左端）。
    public var plannedStart: Date
    /// 计划结束（排期结果的半开区间右端；里程碑与开始同日）。
    public var plannedFinish: Date
    /// 参与计算的工作量（小时）：优先 `effortHours`，缺失时按工期折算。
    public var effortHours: Double
    /// `effortHours` 是否为估算值（任务没填投入，按 `durationDays × hoursPerDay` 折算）。
    public var isEffortEstimated: Bool
    /// 到数据日期为止按计划应完成的工作量（小时）。
    public var plannedValue: Double
    /// 计入挣值的进度（0...1）。
    ///
    /// 三条口径按顺序生效：实际结束不晚于数据日期 → 1（忽略 `progress`）；
    /// 实际结束晚于数据日期 → 0（追溯历史时点，之后才完成的工作不能计入）；
    /// 无实际结束 → 取任务 `progress`。
    public var effectiveProgress: Double
    /// 已完成的工作量（小时）= `effortHours × effectiveProgress`。
    public var earnedValue: Double

    public init(
        taskID: UUID,
        plannedStart: Date,
        plannedFinish: Date,
        effortHours: Double,
        isEffortEstimated: Bool,
        plannedValue: Double,
        effectiveProgress: Double,
        earnedValue: Double
    ) {
        self.taskID = taskID
        self.plannedStart = plannedStart
        self.plannedFinish = plannedFinish
        self.effortHours = effortHours
        self.isEffortEstimated = isEffortEstimated
        self.plannedValue = plannedValue
        self.effectiveProgress = effectiveProgress
        self.earnedValue = earnedValue
    }
}

/// 一次挣值计算的完整结果（17-evm-status-date §4）。
///
/// 只做**工时**口径：PV / EV / SV 的单位是小时，SPI 是无量纲比值。
/// **不提供 CV / CPI**：Kairo 没有费率也没有实际成本，凭工时捏一个成本指数只会误导。
///
/// 已知局限（§5，呈现层必须一并展示，不许藏）：
/// - 项目末期 `plannedValue` 会被追平，SPI 必然回归 1，它只适合看进行中的趋势；
/// - 工作量分布前重后轻时，早期 SPI 会偏高。
public struct EarnedValueReport: Codable, Hashable, Sendable {
    /// 实际使用的观察时点（已按 `calendar` 归一到当日 00:00）。
    public var statusDate: Date
    /// 观察时点是否来自用户固定值。
    ///
    /// `false` = 本次取的是「今天」：同一份报告明天再算会变，界面须明示不可复现。
    public var isStatusDateFixed: Bool
    /// 参与计算的任务（已排期、未取消的叶子任务；顺序同传入的任务列表）。
    public var tasks: [EarnedValueTask]
    /// 未参与计算的任务数：已取消 / 群组 / 父任务 / 无有效排期。
    public var excludedTaskCount: Int
    /// ΣPV（小时）。
    public var plannedValue: Double
    /// ΣEV（小时）。
    public var earnedValue: Double
    /// 进度偏差 SV = ΣEV − ΣPV（小时）；正数 = 比计划提前。
    public var scheduleVariance: Double
    /// 进度绩效指数 SPI = ΣEV / ΣPV。
    ///
    /// **ΣPV = 0 时为 `nil`**（还没有任何计划工作量被「到期」，比值无定义）：
    /// 返回 0 或 ∞ 都会让界面把「无数据」画成「进度为零」或「无限超前」。
    public var schedulePerformanceIndex: Double?

    public init(
        statusDate: Date,
        isStatusDateFixed: Bool,
        tasks: [EarnedValueTask],
        excludedTaskCount: Int = 0,
        plannedValue: Double,
        earnedValue: Double,
        scheduleVariance: Double,
        schedulePerformanceIndex: Double?
    ) {
        self.statusDate = statusDate
        self.isStatusDateFixed = isStatusDateFixed
        self.tasks = tasks
        self.excludedTaskCount = excludedTaskCount
        self.plannedValue = plannedValue
        self.earnedValue = earnedValue
        self.scheduleVariance = scheduleVariance
        self.schedulePerformanceIndex = schedulePerformanceIndex
    }

    /// 投入靠工期折算的任务 ID（呈现层据此给这些行标「估算」）。
    public var estimatedEffortTaskIDs: [UUID] {
        tasks.filter { $0.isEffortEstimated }.map(\.taskID)
    }

    /// 单任务的挣值分解；任务未参与计算（取消 / 群组 / 未排期）时返回 `nil`。
    public func task(_ taskID: UUID) -> EarnedValueTask? {
        tasks.first { $0.taskID == taskID }
    }
}

/// 挣值引擎（ADR-007：纯函数，无 I/O；时钟由 `now` 注入）。
///
/// 计算口径见 17-evm-status-date §4：
/// ```
/// PV_i = effort_i × clamp((statusDate − plannedStart_i) / (plannedFinish_i − plannedStart_i), 0, 1)
/// EV_i = effort_i × effectiveProgress_i
/// SV   = ΣEV − ΣPV
/// SPI  = ΣEV / ΣPV            // ΣPV = 0 → nil
/// ```
/// 工期与已过时间都按**工作日**计量（与排期引擎同一日历口径）：五天工作周下
/// 「过了 2 个工作日」是 `workDaysBetween`，不是日历天数差，否则周末会把 PV 推快。
public enum EarnedValueEngine {
    /// 计算到 `statusDate` 为止的挣值。
    ///
    /// - Parameters:
    ///   - schedule: 当前排期结果（只认未进入 `unscheduledTaskIDs` 的条目）。
    ///   - tasks: 全量任务；顺序即报告行顺序。
    ///   - statusDate: 数据日期；`nil` = 取 `now`（当日零点，报告不可复现）。
    ///   - workCalendar: 项目工作日历；`nil` = 全周 7 天、每工作日 8 小时。
    ///   - calendar: 日算术用日历（DST 安全，禁止秒除）。
    ///   - now: 「今天」的唯一时钟来源；仅在 `statusDate == nil` 时使用。
    public static func report(
        schedule: ScheduleResult,
        tasks: [TaskItem],
        statusDate: Date?,
        workCalendar: WorkCalendar? = nil,
        calendar: Calendar = Calendar(identifier: .gregorian),
        now: Date = Date()
    ) -> EarnedValueReport {
        let calendarValue = workCalendar ?? WorkCalendar()
        let observation = CalendarDayMath.startOfDay(statusDate ?? now, calendar: calendar)
        let unscheduled = Set(schedule.unscheduledTaskIDs)
        // 排期索引：同 ID 重复条目取第一条（与 BaselineEngine.scheduleIndex 同策略）。
        var scheduleByID: [UUID: ScheduledTask] = [:]
        scheduleByID.reserveCapacity(schedule.tasks.count)
        for entry in schedule.tasks where !unscheduled.contains(entry.taskID) {
            if scheduleByID[entry.taskID] == nil { scheduleByID[entry.taskID] = entry }
        }
        // 叶子判据与 ProjectSummary 同口径：群组与有子项的任务只是结构行，不重复计工作量。
        let parentIDs = Set(tasks.compactMap(\.parentID))

        var rows: [EarnedValueTask] = []
        rows.reserveCapacity(tasks.count)
        var totalPlanned = 0.0
        var totalEarned = 0.0
        var excluded = 0

        for task in tasks {
            guard task.status != .cancelled,
                  task.kind != .group,
                  !parentIDs.contains(task.id),
                  let scheduled = scheduleByID[task.id]
            else {
                excluded += 1
                continue
            }

            let (effort, isEstimated) = effortHours(
                for: task, scheduled: scheduled, calendarValue: calendarValue
            )
            let planned = plannedValue(
                effort: effort,
                scheduled: scheduled,
                observation: observation,
                calendarValue: calendarValue,
                calendar: calendar
            )
            let progress = effectiveProgress(for: task, observation: observation, calendar: calendar)

            rows.append(EarnedValueTask(
                taskID: task.id,
                plannedStart: scheduled.scheduledStart,
                plannedFinish: scheduled.scheduledFinish,
                effortHours: effort,
                isEffortEstimated: isEstimated,
                plannedValue: planned,
                effectiveProgress: progress,
                earnedValue: effort * progress
            ))
            totalPlanned += planned
            totalEarned += effort * progress
        }

        return EarnedValueReport(
            statusDate: observation,
            isStatusDateFixed: statusDate != nil,
            tasks: rows,
            excludedTaskCount: excluded,
            plannedValue: totalPlanned,
            earnedValue: totalEarned,
            scheduleVariance: totalEarned - totalPlanned,
            // ΣPV = 0：没有任何计划工作量到期，比值无定义（§4：返回 nil，不返回 0 / ∞）。
            schedulePerformanceIndex: totalPlanned > 0 ? totalEarned / totalPlanned : nil
        )
    }

    // MARK: - 单任务口径

    /// 任务工作量（小时）：`effortHours` 优先；缺失时按 `工期 × 每工作日工时` 折算并标记估算。
    ///
    /// 负值与非有限值按 0 处理（手改文件可以写出任何数，脏投入不得让 PV 变成负数或 NaN）。
    private static func effortHours(
        for task: TaskItem,
        scheduled: ScheduledTask,
        calendarValue: WorkCalendar
    ) -> (hours: Double, isEstimated: Bool) {
        if let given = task.effortHours, given.isFinite {
            return (max(given, 0), false)
        }
        let duration = scheduled.durationDays.isFinite ? max(scheduled.durationDays, 0) : 0
        return (duration * calendarValue.effectiveHoursPerDay, true)
    }

    /// PV_i：按**工作日**插值；零工期（里程碑）不插值，只看到期与否。
    private static func plannedValue(
        effort: Double,
        scheduled: ScheduledTask,
        observation: Date,
        calendarValue: WorkCalendar,
        calendar: Calendar
    ) -> Double {
        let span = calendarValue.workDaysBetween(
            scheduled.scheduledStart, scheduled.scheduledFinish, calendar: calendar
        )
        guard span > 0 else {
            return isOnOrBefore(scheduled.scheduledFinish, observation, calendar: calendar) ? effort : 0
        }
        let elapsed = calendarValue.workDaysBetween(
            scheduled.scheduledStart, observation, calendar: calendar
        )
        return effort * min(max(elapsed / span, 0), 1)
    }

    /// effectiveProgress_i（§4 的两条关键规则）。
    ///
    /// 日期比较按**整日**：数据日期是当日 00:00，完成时刻带时分，
    /// 直接比时刻会把「当天完成」误判成「之后才完成」（EV 归零）。
    private static func effectiveProgress(
        for task: TaskItem,
        observation: Date,
        calendar: Calendar
    ) -> Double {
        if let finished = task.completedAt {
            return isOnOrBefore(finished, observation, calendar: calendar) ? 1 : 0
        }
        return min(max(task.progress, 0), 1)
    }

    /// `date` 所在的日历日是否不晚于 `observation` 所在的日历日。
    private static func isOnOrBefore(_ date: Date, _ observation: Date, calendar: Calendar) -> Bool {
        CalendarDayMath.dayOffset(from: date, to: observation, calendar: calendar) >= 0
    }
}

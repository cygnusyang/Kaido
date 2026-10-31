import Foundation

/// 单任务偏差（08-baselines §4 / §8）。
///
/// 符号约定：**偏差 = 后者 − 基线**，单位为日历天，正数 = 比承诺晚、负数 = 提前。
/// 空缺一律 `nil`，**不写 0**——0 表示「准时」，与「没有数据」语义不同，
/// 混用会让报表把「基线后新增 / 尚未开始」算成准时。
public struct TaskVariance: Hashable, Sendable {
    public var taskID: UUID
    /// 基线承诺开始（`B.start`）。
    public var baselineStart: Date?
    /// 基线承诺结束（`B.finish`，排他端点）。
    public var baselineFinish: Date?
    /// 计划开始偏差：`P.start − B.start`（预测层，主指标口径）。
    public var planStartVariance: Int?
    /// 计划结束偏差：`P.finish − B.finish`（预测层，大纲主指标）。
    public var planFinishVariance: Int?
    /// 实际开始偏差：`A.start − B.start`；无实际开始即 `nil`（不拿 plan 冒充 actual）。
    public var actualStartVariance: Int?
    /// 实际结束偏差：`A.finish − B.finish`；未完成即 `nil`。
    public var actualFinishVariance: Int?
    /// 逾期天数：`max(0, dayOffset(B.finish → today))`，仅未完成任务有值；已完成即 `nil`。
    public var overdueDays: Int?
    /// 是否存在基线条目（`false` = 基线之后新增）。
    public var hasBaseline: Bool
    /// 该任务的偏差当前来自预测层（缺实际结束），项目摘要用它标「含预测项」。
    ///
    /// 回落只发生在**汇总口径**，任务级实际偏差仍为 `nil`：`isForecast` 是
    /// 「这一行只有预测可比」的可见标记，不是把 plan 当成 actual。
    public var isForecast: Bool
    /// 工期偏差 = `(P.finish − P.start) − (B.finish − B.start)`。
    ///
    /// **【Kaido 扩展】**：OmniPlan 只有 Planned Start / End 与两个 Variance，没有工期偏差列；
    /// 本字段为一期引擎的派生量，v0.13 没有 UI 列消费它，仅 CLI/MCP 与后续版本可用。
    public var durationVariance: Int?

    public init(
        taskID: UUID,
        baselineStart: Date? = nil,
        baselineFinish: Date? = nil,
        planStartVariance: Int? = nil,
        planFinishVariance: Int? = nil,
        actualStartVariance: Int? = nil,
        actualFinishVariance: Int? = nil,
        overdueDays: Int? = nil,
        hasBaseline: Bool = true,
        isForecast: Bool = false,
        durationVariance: Int? = nil
    ) {
        self.taskID = taskID
        self.baselineStart = baselineStart
        self.baselineFinish = baselineFinish
        self.planStartVariance = planStartVariance
        self.planFinishVariance = planFinishVariance
        self.actualStartVariance = actualStartVariance
        self.actualFinishVariance = actualFinishVariance
        self.overdueDays = overdueDays
        self.hasBaseline = hasBaseline
        self.isForecast = isForecast
        self.durationVariance = durationVariance
    }
}

/// 一次偏差计算的完整结果（08-baselines §4.4 / §8）。
///
/// 任何偏差输出都必须携带 `baselineID` / `baselineName` / `baselineCreatedAt`（§4.5）：
/// 切换对比基线会让所有数值整体变化，不带标识的报表跨版本不可比。
public struct BaselineVarianceReport: Hashable, Sendable {
    public var baselineID: UUID
    public var baselineName: String
    public var baselineCreatedAt: Date
    /// 现存任务的全部偏差（键 = 任务 ID）。
    ///
    /// 含基线后新增的任务（`hasBaseline == false`，偏差全为 nil）；
    /// 已删除的任务**不在此表**，只出现在 `orphans`。
    public var tasks: [UUID: TaskVariance]
    /// 条目在、任务已删（§5）：不消失，由基线面板呈现。
    public var orphans: [BaselineEntry]
    /// 项目结束偏差 = 最晚 `P.finish` − 最晚 `B.finish`（已排除孤儿）；无数据即 `nil`。
    public var projectFinishVariance: Int?
    /// 已实际完成且晚于基线结束的任务数。
    public var lateTaskCount: Int
    /// 未完成且已过基线结束日的任务数。
    public var overdueOpenCount: Int
    /// 基线之后新增的任务数（无基线条目）。
    public var tasksWithoutBaseline: Int
    /// 缺实际结束的已基线任务数：项目摘要按 plan 参与汇总时必须标注的「预测项」个数。
    public var predictedTaskCount: Int

    public init(
        baselineID: UUID,
        baselineName: String,
        baselineCreatedAt: Date,
        tasks: [UUID: TaskVariance],
        orphans: [BaselineEntry],
        projectFinishVariance: Int? = nil,
        lateTaskCount: Int = 0,
        overdueOpenCount: Int = 0,
        tasksWithoutBaseline: Int = 0,
        predictedTaskCount: Int = 0
    ) {
        self.baselineID = baselineID
        self.baselineName = baselineName
        self.baselineCreatedAt = baselineCreatedAt
        self.tasks = tasks
        self.orphans = orphans
        self.projectFinishVariance = projectFinishVariance
        self.lateTaskCount = lateTaskCount
        self.overdueOpenCount = overdueOpenCount
        self.tasksWithoutBaseline = tasksWithoutBaseline
        self.predictedTaskCount = predictedTaskCount
    }

    /// 单任务偏差；任务不存在（已删除或不在项目里）时返回 `nil`。
    /// 基线后新增的任务返回 `hasBaseline == false` 的条目（不是 nil）。
    public func variance(for taskID: UUID) -> TaskVariance? {
        tasks[taskID]
    }
}

/// 基线引擎（ADR-007：纯函数，无 I/O、无全局时钟）。
///
/// - `snapshot` 把「当前排期结果」冻成基线：只收已排期任务，群组取自身聚合值；
/// - `variance` 用固定公式把计划层与实际层分别同基线比较，绝不回落、绝不臆造。
public enum BaselineEngine {
    /// 默认基线名：`基线 N · yyyy-MM-dd`（N 为创建序号，日期取快照当天）。
    ///
    /// 日期按 `calendar` 的时区渲染，与「快照当天」的判定口径一致。
    public static func defaultName(
        index: Int,
        date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> String {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        return "基线 \(index) · \(formatter.string(from: date))"
    }

    /// 对当前排期拍一次快照。
    ///
    /// - Parameters:
    ///   - tasks: 全量任务（顺序即大纲顺序，决定条目顺序）。
    ///   - schedules: 有效排期表（键 = 任务 ID）；未排期任务不在表中，因此**不入条目**——
    ///     没有时间可比较，入表只会制造 0 偏差假象（§3）。
    ///   - name: 基线名（默认名由 `defaultName(index:date:calendar:)` 生成，序号由调用方给）。
    ///   - anchor: 快照时的排期锚点（D-029 口径），用于解释偏差来源。
    ///   - now: 快照时刻（`createdAt`）；测试一律注入，不读墙钟。
    public static func snapshot(
        tasks: [TaskItem],
        schedules: [UUID: ScheduledTask],
        name: String,
        anchor: Date?,
        now: Date
    ) -> Baseline {
        var entries: [BaselineEntry] = []
        entries.reserveCapacity(schedules.count)
        for task in tasks {
            guard let schedule = schedules[task.id] else { continue }
            entries.append(BaselineEntry(
                taskID: task.id,
                start: schedule.scheduledStart,
                finish: schedule.scheduledFinish,
                progress: task.progress,
                isMilestone: task.kind == .milestone
            ))
        }
        return Baseline(name: name, createdAt: now, anchor: anchor, entries: entries)
    }

    /// 计算某个基线对当前项目的偏差。
    ///
    /// - Parameters:
    ///   - baseline: 被比较的基线（只读）。
    ///   - tasks: 当前全量任务。
    ///   - schedules: 当前有效排期表（键 = 任务 ID）；缺失任务视为「当前无预测」。
    ///   - now: 「今天」（逾期天数与既定口径的唯一时钟来源）。
    ///   - calendar: 日算术用日历（DST 安全，禁止秒除）。
    public static func variance(
        baseline: Baseline,
        tasks: [TaskItem],
        schedules: [UUID: ScheduledTask],
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> BaselineVarianceReport {
        let taskByID = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var variances: [UUID: TaskVariance] = [:]
        variances.reserveCapacity(tasks.count)
        // 基线后新增的任务也进报告（`hasBaseline == false`，全部偏差为 nil）：
        // 大纲/检查器按任务 ID 取值时必须能区分「准时」与「无基线数据」，
        // 缺键会让调用方退回「不显示」而不是显示「基线之后新增」。
        let baselinedTaskIDs = Set(baseline.entries.map(\.taskID))
        for task in tasks where !baselinedTaskIDs.contains(task.id) {
            variances[task.id] = TaskVariance(taskID: task.id, hasBaseline: false)
        }
        var orphans: [BaselineEntry] = []
        // 项目级最晚结束：只统计任务仍在的条目（孤儿不进项目偏差，§5）。
        var latestBaselineFinish: Date?
        var latestPlanFinish: Date?

        for entry in baseline.entries {
            guard let task = taskByID[entry.taskID] else {
                orphans.append(entry)
                continue
            }
            let schedule = schedules[entry.taskID]
            let planStartVariance = schedule.map {
                CalendarDayMath.dayOffset(from: entry.start, to: $0.scheduledStart, calendar: calendar)
            }
            let planFinishVariance = schedule.map {
                CalendarDayMath.dayOffset(from: entry.finish, to: $0.scheduledFinish, calendar: calendar)
            }
            // 实际层为空即 nil：不回落成 0，也不拿 plan 冒充 actual（§4.3）。
            let actualStartVariance = task.actualStart.map {
                CalendarDayMath.dayOffset(from: entry.start, to: $0, calendar: calendar)
            }
            let actualFinishVariance = task.completedAt.map {
                CalendarDayMath.dayOffset(from: entry.finish, to: $0, calendar: calendar)
            }
            let overdueDays: Int? = task.status == .done
                ? nil
                : max(0, CalendarDayMath.dayOffset(from: entry.finish, to: now, calendar: calendar))
            // 【Kaido 扩展】工期偏差：两侧各按排他端点求工期后相减。
            let durationVariance: Int? = schedule.map {
                CalendarDayMath.dayOffset(from: $0.scheduledStart, to: $0.scheduledFinish, calendar: calendar)
                    - CalendarDayMath.dayOffset(from: entry.start, to: entry.finish, calendar: calendar)
            }

            variances[entry.taskID] = TaskVariance(
                taskID: entry.taskID,
                baselineStart: entry.start,
                baselineFinish: entry.finish,
                planStartVariance: planStartVariance,
                planFinishVariance: planFinishVariance,
                actualStartVariance: actualStartVariance,
                actualFinishVariance: actualFinishVariance,
                overdueDays: overdueDays,
                hasBaseline: true,
                isForecast: task.completedAt == nil,
                durationVariance: durationVariance
            )

            if latestBaselineFinish.map({ entry.finish > $0 }) ?? true {
                latestBaselineFinish = entry.finish
            }
            if let finish = schedule?.scheduledFinish,
               latestPlanFinish.map({ finish > $0 }) ?? true {
                latestPlanFinish = finish
            }
        }

        let projectFinishVariance: Int? = {
            guard let latestBaselineFinish, let latestPlanFinish else { return nil }
            return CalendarDayMath.dayOffset(from: latestBaselineFinish, to: latestPlanFinish, calendar: calendar)
        }()

        let lateTaskCount = baseline.entries.filter { entry in
            guard let task = taskByID[entry.taskID], let completedAt = task.completedAt else { return false }
            return CalendarDayMath.dayOffset(from: entry.finish, to: completedAt, calendar: calendar) > 0
        }.count

        let overdueOpenCount = baseline.entries.filter { entry in
            guard let task = taskByID[entry.taskID], task.status != .done else { return false }
            return CalendarDayMath.dayOffset(from: entry.finish, to: now, calendar: calendar) > 0
        }.count

        let tasksWithoutBaseline = tasks.reduce(0) { count, task in
            baselinedTaskIDs.contains(task.id) ? count : count + 1
        }
        let predictedTaskCount = variances.values.reduce(0) { $0 + ($1.isForecast ? 1 : 0) }

        return BaselineVarianceReport(
            baselineID: baseline.id,
            baselineName: baseline.name,
            baselineCreatedAt: baseline.createdAt,
            tasks: variances,
            orphans: orphans,
            projectFinishVariance: projectFinishVariance,
            lateTaskCount: lateTaskCount,
            overdueOpenCount: overdueOpenCount,
            tasksWithoutBaseline: tasksWithoutBaseline,
            predictedTaskCount: predictedTaskCount
        )
    }

    /// 由 `ScheduleResult` 建排期索引：排除无法排期任务，供快照与偏差共用同一张表。
    public static func scheduleIndex(from result: ScheduleResult) -> [UUID: ScheduledTask] {
        let unscheduled = Set(result.unscheduledTaskIDs)
        var index: [UUID: ScheduledTask] = [:]
        index.reserveCapacity(result.tasks.count)
        for task in result.tasks where !unscheduled.contains(task.taskID) {
            index[task.taskID] = task
        }
        return index
    }
}

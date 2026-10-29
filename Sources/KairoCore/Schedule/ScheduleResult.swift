import Foundation

/// 调度锚定方向（F-20-02 项目时间线：固定开始向前排 / 固定结束向后排）。
/// 方向记录项目级锚定意图；每任务的 ASAP/ALAP（`schedulingPolicy`）在锚定窗口内选定安排。
public enum ScheduleDirection: String, Codable, Hashable, Sendable {
    case forward
    case backward
}

/// 单任务调度结果（US-E2-02 / F-22-04）。
/// 记录最早/最晚可行窗口与选定安排；调度结果是独立于任务原始字段的另一张表
/// （TaskItem 的 startDate/dueDate 是用户输入意图，不被本结果改写）。
public struct ScheduledTask: Codable, Hashable, Sendable {
    public var taskID: UUID
    /// 参与排期的持续时间（天；里程碑为 0）。
    public var durationDays: Double
    /// 最早开始/结束（前向传播，ASAP 窗口）。
    public var earliestStart: Date
    public var earliestFinish: Date
    /// 最晚开始/结束（后向传播，ALAP 窗口）。
    public var latestStart: Date
    public var latestFinish: Date
    /// 选定安排：ASAP→最早，ALAP→最晚。
    public var scheduledStart: Date
    public var scheduledFinish: Date
    /// 总宽延（天）= 最晚开始 − 最早开始（US-E2-03 / F-21-01）。
    public var totalSlackDays: Double
    /// 自由宽延（天）= 不推迟任何后继的最早安排的最大推迟量。
    public var freeSlackDays: Double

    public init(
        taskID: UUID,
        durationDays: Double,
        earliestStart: Date,
        earliestFinish: Date,
        latestStart: Date,
        latestFinish: Date,
        scheduledStart: Date,
        scheduledFinish: Date,
        totalSlackDays: Double,
        freeSlackDays: Double
    ) {
        self.taskID = taskID
        self.durationDays = durationDays
        self.earliestStart = earliestStart
        self.earliestFinish = earliestFinish
        self.latestStart = latestStart
        self.latestFinish = latestFinish
        self.scheduledStart = scheduledStart
        self.scheduledFinish = scheduledFinish
        self.totalSlackDays = totalSlackDays
        self.freeSlackDays = freeSlackDays
    }
}

/// 一次排期里发生的「日期吸附」（F-22-06 / D3）。
///
/// 用户输入的约束日 / 开始日落在非工作日时，排期不拒绝、也不静默：日期向后滚到下一个
/// 工作日继续排，同时在这里留一条记录。呈现层据此产出 info 级违例「已从 X 顺延到 Y」，
/// 因此它是排期结果的一部分，而不是引擎内部的临时变量。
public struct CalendarAdjustment: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        /// 输入日期落在非工作日，已顺延到后一个工作日。
        case nonWorkingDay
        /// 日历本身不可用（`workingWeekdays` 为空），已退化为全周 7 天。
        case invalidWeekdays
    }

    /// 涉及任务；项目级（`invalidWeekdays`）为 nil。
    public var taskID: UUID?
    public var kind: Kind
    /// 用户给出的原始日期。
    public var requested: Date
    /// 实际参与排期的日期。
    public var adjusted: Date

    public init(taskID: UUID?, kind: Kind, requested: Date, adjusted: Date) {
        self.taskID = taskID
        self.kind = kind
        self.requested = requested
        self.adjusted = adjusted
    }
}

/// 一次排期计算的完整结果（ADR-007 纯函数输出，可序列化给 MCP/CLI）。
public struct ScheduleResult: Codable, Hashable, Sendable {
    public var tasks: [ScheduledTask]
    public var projectStart: Date?
    public var projectEnd: Date?
    public var direction: ScheduleDirection
    /// 处于相关性环中的任务 ID（F-30-08）；环上任务不参与拓扑传播。
    public var cycleTaskIDs: [UUID]
    /// `projectStart` 是否由任务数据推导（ADR-013 / D-003）；显式设置时为 false。
    public var projectStartDerived: Bool
    /// 推导来源（项目开始日期 / 最早任务 / 项目创建日期 / 今天），决定界面提示措辞。
    public var projectStartSource: ScheduleAnchor.Source
    /// 无法排期的任务 ID（依赖环、空群组）；其 `tasks` 条目不代表有效安排。
    public var unscheduledTaskIDs: [UUID]
    /// 本次排期发生的日期吸附（F-22-06 / D3）；空 = 没有输入落在非工作日。
    public var calendarAdjustments: [CalendarAdjustment]
    /// 手动排期冲突：任务 ID → 依赖要求的「最早开始」（晚于用户钉死的日期）。
    /// nil / 空 = 无冲突。供 `ViolationEngine` 转成 `manualStartConflict` 违例。
    public var manualConflicts: [UUID: Date]?

    public init(
        tasks: [ScheduledTask],
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection = .forward,
        cycleTaskIDs: [UUID] = [],
        projectStartDerived: Bool = false,
        projectStartSource: ScheduleAnchor.Source = .projectStart,
        unscheduledTaskIDs: [UUID] = [],
        calendarAdjustments: [CalendarAdjustment] = [],
        manualConflicts: [UUID: Date]? = nil
    ) {
        self.tasks = tasks
        self.projectStart = projectStart
        self.projectEnd = projectEnd
        self.direction = direction
        self.cycleTaskIDs = cycleTaskIDs
        self.projectStartDerived = projectStartDerived
        self.projectStartSource = projectStartSource
        self.unscheduledTaskIDs = unscheduledTaskIDs
        self.calendarAdjustments = calendarAdjustments
        self.manualConflicts = manualConflicts
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case tasks, projectStart, projectEnd, direction, cycleTaskIDs
        case projectStartDerived, projectStartSource, unscheduledTaskIDs
        case calendarAdjustments, manualConflicts
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tasks = try c.decode([ScheduledTask].self, forKey: .tasks)
        projectStart = try c.decodeIfPresent(Date.self, forKey: .projectStart)
        projectEnd = try c.decodeIfPresent(Date.self, forKey: .projectEnd)
        direction = try c.decodeIfPresent(ScheduleDirection.self, forKey: .direction) ?? .forward
        cycleTaskIDs = try c.decodeIfPresent([UUID].self, forKey: .cycleTaskIDs) ?? []
        // 新增字段缺失给默认值（旧数据前向兼容）。
        projectStartDerived = try c.decodeIfPresent(Bool.self, forKey: .projectStartDerived) ?? false
        // 旧数据没有来源字段：推导过的一律按「最早任务」措辞回落（与当时唯一实现一致）。
        projectStartSource = try c.decodeIfPresent(
            ScheduleAnchor.Source.self, forKey: .projectStartSource
        ) ?? (projectStartDerived ? .earliestTaskStart : .projectStart)
        unscheduledTaskIDs = try c.decodeIfPresent([UUID].self, forKey: .unscheduledTaskIDs) ?? []
        manualConflicts = try c.decodeIfPresent([UUID: Date].self, forKey: .manualConflicts)
        calendarAdjustments = try c.decodeIfPresent(
            [CalendarAdjustment].self, forKey: .calendarAdjustments
        ) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(tasks, forKey: .tasks)
        try c.encodeIfPresent(projectStart, forKey: .projectStart)
        try c.encodeIfPresent(projectEnd, forKey: .projectEnd)
        try c.encode(direction, forKey: .direction)
        try c.encode(cycleTaskIDs, forKey: .cycleTaskIDs)
        try c.encode(projectStartDerived, forKey: .projectStartDerived)
        try c.encode(projectStartSource, forKey: .projectStartSource)
        try c.encode(unscheduledTaskIDs, forKey: .unscheduledTaskIDs)
        if let manualConflicts, !manualConflicts.isEmpty {
            try c.encode(manualConflicts, forKey: .manualConflicts)
        }
        if !calendarAdjustments.isEmpty {
            try c.encode(calendarAdjustments, forKey: .calendarAdjustments)
        }
    }

    /// 任务是否具有有效安排：存在调度条目且不在 `unscheduledTaskIDs` 中。
    public func hasSchedule(for id: UUID) -> Bool {
        scheduled(id) != nil && !unscheduledTaskIDs.contains(id)
    }

    /// 按任务 ID 取调度结果。
    public func scheduled(_ id: UUID) -> ScheduledTask? {
        tasks.first { $0.taskID == id }
    }
}

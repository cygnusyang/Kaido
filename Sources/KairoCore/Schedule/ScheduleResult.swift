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

/// 一次排期计算的完整结果（ADR-007 纯函数输出，可序列化给 MCP/CLI）。
public struct ScheduleResult: Codable, Hashable, Sendable {
    public var tasks: [ScheduledTask]
    public var projectStart: Date?
    public var projectEnd: Date?
    public var direction: ScheduleDirection
    /// 处于相关性环中的任务 ID（F-30-08）；环上任务不参与拓扑传播。
    public var cycleTaskIDs: [UUID]

    public init(
        tasks: [ScheduledTask],
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection = .forward,
        cycleTaskIDs: [UUID] = []
    ) {
        self.tasks = tasks
        self.projectStart = projectStart
        self.projectEnd = projectEnd
        self.direction = direction
        self.cycleTaskIDs = cycleTaskIDs
    }

    /// 按任务 ID 取调度结果。
    public func scheduled(_ id: UUID) -> ScheduledTask? {
        tasks.first { $0.taskID == id }
    }
}

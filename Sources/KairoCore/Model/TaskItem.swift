import Foundation

/// Task status in a Kairo project.
///
/// `cancelled` 是「决定不做」的终态（v0.16）：任务留在项目里可追溯，但不占排期、
/// 不进进度分母、不产生违例。用 `blocked` 冒充会让逾期与关键路径一直报错，
/// 所以它是独立取值而不是 blocked 的修饰。新用例一律追加在末尾——`allCases` 顺序
/// 就是界面状态菜单顺序。
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending, inProgress = "in_progress", done, blocked
    /// 已取消（终态）：任务不再推进；取消原因见 `TaskItem.cancelReason`。
    case cancelled
}

/// Priority of a task.
public enum TaskPriority: String, Codable, CaseIterable, Sendable {
    case low, normal, high, critical
}

/// A single task node in a Kairo project. Value type; identity via `id`.
public struct TaskItem: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var notes: String
    public var startDate: Date?
    public var dueDate: Date?
    public var priority: TaskPriority
    public var status: TaskStatus
    public var tags: [String]
    public var assignee: String?
    /// 任务种类：任务 / 群组 / 里程碑（默认 .task）。
    public var kind: TaskKind
    /// 层级树父引用（nil = 顶层任务）。
    public var parentID: UUID?
    /// 投入（小时）。
    public var effortHours: Double?
    /// 持续时间（天）。
    public var durationDays: Double?
    /// 相关性：本任务依赖的前驱任务（类型 + 前导时间）。
    public var dependencies: [TaskDependency]
    /// 0...1 completion fraction.
    public var progress: Double
    /// 时限（F-22-04 / F-30）：对开始/结束日期的单向约束；nil = 无时限。
    public var constraint: SchedulingConstraint?
    /// 调度策略（F-22-04 ASAP/ALAP）：默认尽可能早。
    public var schedulingPolicy: SchedulingPolicy
    /// 实际结束（v0.12 / 07-actual-dates §2）：状态置 done 时记录，可人工修正。
    /// 复用 US-E3-01 的字段与磁盘键 `completedAt`，不另设 `actualFinish`。
    public var completedAt: Date?
    /// 实际开始（v0.12 / 07-actual-dates §2）：首次开工时刻，只增不清（人工可清除）。
    /// 群组行不表达实际，恒为 nil。
    public var actualStart: Date?
    /// 资源分配（F-22-08 / ADR-009）：任务↔资源分配列表；供投入↔持续时间换算。
    public var assignments: [TaskAssignment]
    /// 取消原因（v0.16）：仅在 `status == .cancelled` 时非 nil，离开该状态即清空。
    /// 「决定不做」必须留理由，否则终态无法回溯是谁、为什么砍掉。
    public var cancelReason: String?

    public init(
        id: UUID = UUID(),
        title: String,
        notes: String = "",
        startDate: Date? = nil,
        dueDate: Date? = nil,
        priority: TaskPriority = .normal,
        status: TaskStatus = .pending,
        tags: [String] = [],
        assignee: String? = nil,
        kind: TaskKind = .task,
        parentID: UUID? = nil,
        effortHours: Double? = nil,
        durationDays: Double? = nil,
        dependencies: [TaskDependency] = [],
        progress: Double = 0,
        constraint: SchedulingConstraint? = nil,
        schedulingPolicy: SchedulingPolicy = .asap,
        completedAt: Date? = nil,
        assignments: [TaskAssignment] = [],
        actualStart: Date? = nil,
        cancelReason: String? = nil
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.startDate = startDate
        self.dueDate = dueDate
        self.priority = priority
        self.status = status
        self.tags = tags
        self.assignee = assignee
        self.kind = kind
        self.parentID = parentID
        self.effortHours = effortHours
        self.durationDays = durationDays
        self.dependencies = dependencies
        self.progress = min(max(progress, 0), 1)
        self.constraint = constraint
        self.schedulingPolicy = schedulingPolicy
        self.completedAt = completedAt
        self.assignments = assignments
        self.actualStart = actualStart
        self.cancelReason = cancelReason
    }

    /// 逾期判据：有截止日期、且既未完成也未取消。
    /// 已取消的任务决定不做，不存在「赶不上」的语义（v0.16）。
    public var isOverdue: Bool {
        guard let due = dueDate, status != .done, status != .cancelled else { return false }
        return due < Date()
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, startDate, dueDate, priority, status, tags, assignee
        case kind, parentID, effortHours, durationDays, dependencies, progress
        case constraint, schedulingPolicy, completedAt, assignments, actualStart
        case cancelReason
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        notes = try c.decodeIfPresent(String.self, forKey: .notes) ?? ""
        startDate = try c.decodeIfPresent(Date.self, forKey: .startDate)
        dueDate = try c.decodeIfPresent(Date.self, forKey: .dueDate)
        priority = try c.decodeIfPresent(TaskPriority.self, forKey: .priority) ?? .normal
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .pending
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        assignee = try c.decodeIfPresent(String.self, forKey: .assignee)
        // 新增字段缺失给默认值（旧数据前向兼容）。
        kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind) ?? .task
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        effortHours = try c.decodeIfPresent(Double.self, forKey: .effortHours)
        durationDays = try c.decodeIfPresent(Double.self, forKey: .durationDays)
        // 旧数据 dependencies 为 [UUID]：按 FS、无前导时间迁移（US-E2-01）。
        if let deps = try? c.decode([TaskDependency].self, forKey: .dependencies) {
            dependencies = deps
        } else if let legacy = try? c.decode([UUID].self, forKey: .dependencies) {
            dependencies = legacy.map { TaskDependency(predecessorID: $0) }
        } else {
            dependencies = []
        }
        progress = min(max(try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0, 0), 1)
        // 新增字段缺失给默认值（ADR-011 前向兼容 / ADR-012 自定义解码）。
        constraint = try c.decodeIfPresent(SchedulingConstraint.self, forKey: .constraint)
        schedulingPolicy = try c.decodeIfPresent(SchedulingPolicy.self, forKey: .schedulingPolicy) ?? .asap
        completedAt = try c.decodeIfPresent(Date.self, forKey: .completedAt)
        assignments = try c.decodeIfPresent([TaskAssignment].self, forKey: .assignments) ?? []
        // v0.12 新增：旧文件缺键 → nil，格式版本不变（ADR-011）。
        actualStart = try c.decodeIfPresent(Date.self, forKey: .actualStart)
        // v0.16 新增：同上，不升 formatVersion。
        cancelReason = try c.decodeIfPresent(String.self, forKey: .cancelReason)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(notes, forKey: .notes)
        try c.encodeIfPresent(startDate, forKey: .startDate)
        try c.encodeIfPresent(dueDate, forKey: .dueDate)
        try c.encode(priority, forKey: .priority)
        try c.encode(status, forKey: .status)
        try c.encode(tags, forKey: .tags)
        try c.encodeIfPresent(assignee, forKey: .assignee)
        try c.encode(kind, forKey: .kind)
        try c.encodeIfPresent(parentID, forKey: .parentID)
        try c.encodeIfPresent(effortHours, forKey: .effortHours)
        try c.encodeIfPresent(durationDays, forKey: .durationDays)
        try c.encode(dependencies, forKey: .dependencies)
        try c.encode(progress, forKey: .progress)
        try c.encodeIfPresent(constraint, forKey: .constraint)
        try c.encode(schedulingPolicy, forKey: .schedulingPolicy)
        try c.encodeIfPresent(completedAt, forKey: .completedAt)
        try c.encode(assignments, forKey: .assignments)
        try c.encodeIfPresent(actualStart, forKey: .actualStart)
        try c.encodeIfPresent(cancelReason, forKey: .cancelReason)
    }
}

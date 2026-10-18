import Foundation

/// Task status in a Kairo project.
public enum TaskStatus: String, Codable, CaseIterable, Sendable {
    case pending, inProgress = "in_progress", done, blocked
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
    /// 完成时间（US-E3-01 状态回写：状态置 done 时记录）。
    public var completedAt: Date?
    /// 资源分配（F-22-08 / ADR-009）：任务↔资源分配列表；供投入↔持续时间换算。
    public var assignments: [TaskAssignment]

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
        assignments: [TaskAssignment] = []
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
    }

    public var isOverdue: Bool {
        guard let due = dueDate, status != .done else { return false }
        return due < Date()
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case id, title, notes, startDate, dueDate, priority, status, tags, assignee
        case kind, parentID, effortHours, durationDays, dependencies, progress
        case constraint, schedulingPolicy, completedAt, assignments
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
    }
}

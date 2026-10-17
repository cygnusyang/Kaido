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
    /// IDs of tasks that must complete before this one starts.
    public var dependencies: [UUID]
    /// 0...1 completion fraction.
    public var progress: Double

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
        dependencies: [UUID] = [],
        progress: Double = 0
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
        self.dependencies = dependencies
        self.progress = min(max(progress, 0), 1)
    }

    public var isOverdue: Bool {
        guard let due = dueDate, status != .done else { return false }
        return due < Date()
    }
}

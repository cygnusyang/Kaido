import Foundation

/// 项目元数据（标题 / 时间戳；.kairo 格式 project 段）。
public struct ProjectMetadata: Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// 项目时间线（F-20-02）：排期与违例的默认边界；未设则由显式参数或任务数据推导。
    public var projectStart: Date?
    public var projectEnd: Date?
    /// 项目排期方向（ADR-011 / ADR-013）：默认向前排；旧文件缺省为 forward。
    public var direction: ScheduleDirection

    public init(
        id: UUID = UUID(),
        title: String = "未命名项目",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection = .forward
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectStart = projectStart
        self.projectEnd = projectEnd
        self.direction = direction
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, projectStart, projectEnd, direction
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        projectStart = try c.decodeIfPresent(Date.self, forKey: .projectStart)
        projectEnd = try c.decodeIfPresent(Date.self, forKey: .projectEnd)
        // 新增字段缺失给默认值（旧数据前向兼容）。
        direction = try c.decodeIfPresent(ScheduleDirection.self, forKey: .direction) ?? .forward
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(projectStart, forKey: .projectStart)
        try c.encodeIfPresent(projectEnd, forKey: .projectEnd)
        try c.encode(direction, forKey: .direction)
    }
}

/// A Kairo project: a flat, ordered task list plus CRUD and filtering.
/// Task order in `tasks` is the outline order shown in the main window.
///
/// 纯逻辑模型（ADR-004）：不依赖 AppKit/SwiftUI/Combine，可跨平台编译。
/// SwiftUI 的变更通知由应用层 `ProjectStore` 门面承担。
public final class Project {
    public var metadata: ProjectMetadata
    public var tasks: [TaskItem] = []
    /// 资源清单（F-23-01）：供资源 CRUD 与投入↔持续时间换算。
    public var resources: [Resource] = []

    public init(metadata: ProjectMetadata = ProjectMetadata()) {
        self.metadata = metadata
    }

    /// Fast lookup by task id.
    public var tasksByID: [UUID: TaskItem] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    public func add(_ task: TaskItem) {
        tasks.append(task)
    }

    /// 在指定任务之后插入（Return 新建同级任务，US-E4-03）。
    public func insert(_ task: TaskItem, after siblingID: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == siblingID }) {
            tasks.insert(task, at: index + 1)
        } else {
            tasks.append(task)
        }
    }

    /// 用新的大纲顺序替换任务列表（缩进/出缩进后调用）。
    public func replaceTasks(_ newTasks: [TaskItem]) {
        tasks = newTasks
    }

    public func update(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
    }

    public func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    /// Tasks satisfying every clause; an empty clause list returns all tasks.
    public func filteredTasks(clauses: [FilterClause]) -> [TaskItem] {
        AIFilterTranslator.apply(clauses: clauses, to: tasks)
    }
}

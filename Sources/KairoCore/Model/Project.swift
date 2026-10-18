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

    public init(
        id: UUID = UUID(),
        title: String = "未命名项目",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectStart: Date? = nil,
        projectEnd: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectStart = projectStart
        self.projectEnd = projectEnd
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

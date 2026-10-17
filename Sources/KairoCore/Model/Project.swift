import Foundation

/// A Kairo project: a flat, ordered task list plus CRUD and filtering.
/// Task order in `tasks` is the outline order shown in the main window.
///
/// 纯逻辑模型（ADR-004）：不依赖 AppKit/SwiftUI/Combine，可跨平台编译。
/// SwiftUI 的变更通知由应用层 `ProjectStore` 门面承担。
public final class Project {
    public var tasks: [TaskItem] = []

    public init() {}

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

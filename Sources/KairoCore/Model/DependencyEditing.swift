import Foundation

/// 相关性编辑（F-30-08 / ADR-013）：四型 CRUD、环校验、重复归一、悬空清理。
///
/// 输入与输出均为任务数组的值副本；错误返回 `Result`，调用方保持原状。
/// 重复归一：同一前驱只保留一条依赖，重复添加用新类型与前导时间覆盖。
public enum DependencyEditing {
    public enum EditError: Error, Equatable, Sendable {
        case taskNotFound
        case predecessorNotFound
        case selfDependency
        case cycle
    }

    /// 为任务添加依赖。前驱不存在、自依赖或成环时返回错误。
    public static func add(
        _ dependency: TaskDependency,
        to taskID: UUID,
        in tasks: [TaskItem]
    ) -> Result<[TaskItem], EditError> {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return .failure(.taskNotFound)
        }
        guard dependency.predecessorID != taskID else {
            return .failure(.selfDependency)
        }
        guard tasks.contains(where: { $0.id == dependency.predecessorID }) else {
            return .failure(.predecessorNotFound)
        }
        if reaches(from: dependency.predecessorID, target: taskID, in: tasks) {
            return .failure(.cycle)
        }
        var updated = tasks
        updated[index].dependencies.removeAll { $0.predecessorID == dependency.predecessorID }
        updated[index].dependencies.append(dependency)
        return .success(updated)
    }

    /// 删除任务的一条依赖；依赖不存在时原样返回。
    public static func remove(
        predecessorID: UUID,
        from taskID: UUID,
        in tasks: [TaskItem]
    ) -> Result<[TaskItem], EditError> {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else {
            return .failure(.taskNotFound)
        }
        var updated = tasks
        updated[index].dependencies.removeAll { $0.predecessorID == predecessorID }
        return .success(updated)
    }

    /// 删除任务后清理指向它的悬空依赖。
    public static func removingDanglingReferences(
        to removedIDs: Set<UUID>,
        in tasks: [TaskItem]
    ) -> [TaskItem] {
        tasks.map { task in
            guard task.dependencies.contains(where: { removedIDs.contains($0.predecessorID) }) else {
                return task
            }
            var updated = task
            updated.dependencies.removeAll { removedIDs.contains($0.predecessorID) }
            return updated
        }
    }

    /// 从 `start` 沿前驱边能否到达 `target`；用于判定新增依赖是否成环。
    /// 图可能存在既有环，用 visited 截断。
    private static func reaches(from start: UUID, target: UUID, in tasks: [TaskItem]) -> Bool {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var visited: Set<UUID> = []
        var stack = [start]
        while let current = stack.popLast() {
            if current == target { return true }
            guard visited.insert(current).inserted, let task = byID[current] else { continue }
            stack.append(contentsOf: task.dependencies.map(\.predecessorID))
        }
        return false
    }
}

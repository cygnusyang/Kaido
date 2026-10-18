import Foundation

/// 大纲层级编辑（US-E4-03 / F-14-02）：缩进、出缩进、新建同级的父级判定。
///
/// 输入与输出均为「大纲顺序」的扁平任务数组；操作不可行时返回 nil（调用方保持原状）。
/// 纯函数（ADR-004），可在无 UI 环境下单测。
public enum OutlineEditor {
    /// Tab：把任务缩进为**上一同级任务**的子任务。
    /// 没有上一同级任务时不可缩进（返回 nil）。
    public static func indent(_ taskID: UUID, in tasks: [TaskItem]) -> [TaskItem]? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        let parentID = tasks[index].parentID
        guard let previous = tasks[..<index].last(where: { $0.parentID == parentID }) else { return nil }
        var updated = tasks
        updated[index].parentID = previous.id
        return updated
    }

    /// Shift-Tab：任务上移一级，成为父任务的同级；其子树随行，
    /// 并排在父任务子树之后（保持可读的大纲顺序）。已是顶层时返回 nil。
    public static func outdent(_ taskID: UUID, in tasks: [TaskItem]) -> [TaskItem]? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }) else { return nil }
        guard let parentID = tasks[index].parentID else { return nil }
        guard let parent = tasks.first(where: { $0.id == parentID }) else { return nil }

        var updated = tasks
        updated[index].parentID = parent.parentID

        // 剩余的父任务子树（不含被移出的子树）末尾之后插入被移出的子树。
        let movedIDs = subtreeIDs(of: taskID, in: tasks)
        let moved = updated.filter { movedIDs.contains($0.id) }
        var rest = updated.filter { !movedIDs.contains($0.id) }
        let parentSubtree = subtreeIDs(of: parentID, in: rest)
        let insertAt: Int
        if let last = rest.lastIndex(where: { parentSubtree.contains($0.id) }) {
            insertAt = last + 1
        } else if let parentIndex = rest.firstIndex(where: { $0.id == parentID }) {
            insertAt = parentIndex + 1
        } else {
            return nil
        }
        rest.insert(contentsOf: moved, at: insertAt)
        return rest
    }

    /// Return：新任务应挂到的父级。选中群组时新任务成为其子项；
    /// 选中普通任务时新任务与其同级（同 parentID）。
    public static func siblingParent(for taskID: UUID, in tasks: [TaskItem]) -> UUID? {
        guard let task = tasks.first(where: { $0.id == taskID }) else { return nil }
        return task.kind == .group ? task.id : task.parentID
    }

    /// 任务自身与全部后代的 ID（防御性截断环）。
    public static func subtreeIDs(of taskID: UUID, in tasks: [TaskItem]) -> Set<UUID> {
        var childrenByParent: [UUID: [UUID]] = [:]
        for task in tasks {
            if let parent = task.parentID {
                childrenByParent[parent, default: []].append(task.id)
            }
        }
        var result: Set<UUID> = [taskID]
        var stack = [taskID]
        var hops = 0
        while let current = stack.popLast(), hops <= tasks.count {
            hops += 1
            for childID in childrenByParent[current] ?? [] where result.insert(childID).inserted {
                stack.append(childID)
            }
        }
        return result
    }
}

import Foundation

/// 单行拖拽重排（F-14-02 / ADR-013）：目标父级与索引计算。
///
/// 输入与输出均为大纲顺序的扁平任务数组；子树随根任务整体移动。
/// `index` 指移除被移动子树后、目标父级直接子项中的最终位置（0 起）。
public enum OutlineMoving {
    public enum MoveError: Error, Equatable, Sendable {
        case taskNotFound
        case targetNotFound
        case moveIntoSubtree
    }

    public static func move(
        _ taskID: UUID,
        toParent parentID: UUID?,
        at index: Int,
        in tasks: [TaskItem]
    ) -> Result<[TaskItem], MoveError> {
        guard let root = tasks.first(where: { $0.id == taskID }) else {
            return .failure(.taskNotFound)
        }
        if let parentID, !tasks.contains(where: { $0.id == parentID }) {
            return .failure(.targetNotFound)
        }
        let movingIDs = OutlineEditor.subtreeIDs(of: taskID, in: tasks)
        if let parentID, movingIDs.contains(parentID) {
            return .failure(.moveIntoSubtree)
        }

        var updated = tasks.filter { !movingIDs.contains($0.id) }
        var moved = tasks.filter { movingIDs.contains($0.id) }
        guard let movedRootIndex = moved.firstIndex(where: { $0.id == root.id }) else {
            return .failure(.taskNotFound)
        }
        moved[movedRootIndex].parentID = parentID

        let insertAt: Int
        if let parentID {
            guard let parentPosition = updated.firstIndex(where: { $0.id == parentID }) else {
                return .failure(.targetNotFound)
            }
            let children = updated.filter { $0.parentID == parentID }.map(\.id)
            let clamped = max(0, min(index, children.count))
            if clamped < children.count {
                guard let position = updated.firstIndex(where: { $0.id == children[clamped] }) else {
                    return .failure(.targetNotFound)
                }
                insertAt = position
            } else if let lastChild = children.last {
                let subtree = OutlineEditor.subtreeIDs(of: lastChild, in: updated)
                insertAt = (updated.lastIndex(where: { subtree.contains($0.id) }) ?? parentPosition) + 1
            } else {
                insertAt = parentPosition + 1
            }
        } else {
            let rootIDs = Set(updated.filter { task in
                task.parentID == nil || !updated.contains(where: { $0.id == task.parentID })
            }.map(\.id))
            let roots = updated.filter { rootIDs.contains($0.id) }.map(\.id)
            let clamped = max(0, min(index, roots.count))
            if clamped < roots.count {
                insertAt = updated.firstIndex(where: { $0.id == roots[clamped] }) ?? updated.count
            } else if let lastRoot = roots.last {
                let subtree = OutlineEditor.subtreeIDs(of: lastRoot, in: updated)
                insertAt = (updated.lastIndex(where: { subtree.contains($0.id) }) ?? updated.count - 1) + 1
            } else {
                insertAt = updated.count
            }
        }

        updated.insert(contentsOf: moved, at: insertAt)
        return .success(updated)
    }
}

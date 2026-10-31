import Foundation
import Testing
@testable import KaidoCore

// 相关性编辑（F-30-08）：四型、重复归一、自依赖与成环拒绝、悬空清理。

struct DependencyEditingTests {
    @Test func addsAllFourTypes() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B")
        let tasks = [a, b]

        for type in TaskDependency.DependencyType.allCases {
            let result = DependencyEditing.add(
                TaskDependency(predecessorID: a.id, type: type, lagDays: 1.5),
                to: b.id,
                in: tasks
            )
            guard case .success(let updated) = result else {
                Issue.record("添加 \(type) 失败")
                continue
            }
            #expect(updated[1].dependencies == [
                TaskDependency(predecessorID: a.id, type: type, lagDays: 1.5)
            ])
        }
    }

    @Test func duplicatePredecessorIsNormalized() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B", dependencies: [TaskDependency(predecessorID: a.id)])
        let tasks = [a, b]

        guard case .success(let updated) = DependencyEditing.add(
            TaskDependency(predecessorID: a.id, type: .ss, lagDays: 2),
            to: b.id,
            in: tasks
        ) else {
            Issue.record("应成功")
            return
        }

        #expect(updated[1].dependencies.count == 1)
        #expect(updated[1].dependencies[0].type == .ss)
        #expect(updated[1].dependencies[0].lagDays == 2)
    }

    @Test func rejectsSelfDependency() {
        let a = TaskItem(title: "A")

        let result = DependencyEditing.add(
            TaskDependency(predecessorID: a.id), to: a.id, in: [a]
        )

        #expect(result == .failure(.selfDependency))
    }

    @Test func rejectsUnknownPredecessor() {
        let a = TaskItem(title: "A")

        let result = DependencyEditing.add(
            TaskDependency(predecessorID: UUID()), to: a.id, in: [a]
        )

        #expect(result == .failure(.predecessorNotFound))
    }

    @Test func rejectsCycle() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B", dependencies: [TaskDependency(predecessorID: a.id)])
        // A 依赖 B 会形成 A → B → A。
        let result = DependencyEditing.add(
            TaskDependency(predecessorID: b.id), to: a.id, in: [a, b]
        )

        #expect(result == .failure(.cycle))
    }

    @Test func rejectsLongerCycle() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B", dependencies: [TaskDependency(predecessorID: a.id)])
        let c = TaskItem(title: "C", dependencies: [TaskDependency(predecessorID: b.id)])

        let result = DependencyEditing.add(
            TaskDependency(predecessorID: c.id), to: a.id, in: [a, b, c]
        )

        #expect(result == .failure(.cycle))
    }

    @Test func removesDependency() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B", dependencies: [TaskDependency(predecessorID: a.id)])
        let c = TaskItem(title: "C", dependencies: [TaskDependency(predecessorID: a.id)])

        guard case .success(let updated) = DependencyEditing.remove(
            predecessorID: a.id, from: b.id, in: [a, b, c]
        ) else {
            Issue.record("应成功")
            return
        }

        #expect(updated[1].dependencies.isEmpty)
        #expect(updated[2].dependencies.count == 1)
    }

    @Test func cleansDanglingReferencesAfterDelete() {
        let a = TaskItem(title: "A")
        let b = TaskItem(title: "B", dependencies: [TaskDependency(predecessorID: a.id)])
        let c = TaskItem(title: "C", dependencies: [
            TaskDependency(predecessorID: a.id),
            TaskDependency(predecessorID: b.id)
        ])

        let updated = DependencyEditing.removingDanglingReferences(
            to: [a.id], in: [b, c]
        )

        #expect(updated[0].dependencies.isEmpty)
        #expect(updated[1].dependencies.map(\.predecessorID) == [b.id])
    }
}

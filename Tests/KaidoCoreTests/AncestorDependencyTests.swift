import Foundation
import Testing
@testable import KaidoCore

/// 祖先依赖（群组依赖自己的祖先群组）的回归用例（v1.3.6 现场）。
///
/// 现象：`docs/roadmap/Kaido.kaido` 里「v1.2 维护」是「v1.2 互操作」的子群组，
/// 同时又依赖「v1.2 互操作」——依赖展开到叶子时把依赖者自己的兄弟子树卷进来，
/// 拓扑序排不出这些任务，它们既不进前向传播也不被判环，最终被 epoch 兜底成
/// 1970-01-01，表现为「任务在甘特上凭空消失」。
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: .init(year: y, month: m, day: d))! }
private let start = day(2026, 10, 26)

@Suite("祖先依赖不得落到 epoch")
struct AncestorDependencyTests {
    /// 子群组依赖自己的父群组：不得出现 1970 排期，且必须被判为环（可见告警）。
    @Test func groupDependingOnItsOwnAncestorIsReportedAsCycle() throws {
        let groupA = UUID(), groupB = UUID(), a1 = UUID(), a2 = UUID(), b1 = UUID(), b2 = UUID()
        let tasks = [
            TaskItem(id: groupA, title: "阶段 A", kind: .group),
            TaskItem(id: a1, title: "A1", kind: .task, parentID: groupA, durationDays: 2),
            TaskItem(id: a2, title: "A2", kind: .task, parentID: groupA, durationDays: 2,
                     dependencies: [TaskDependency(predecessorID: a1, type: .fs, lagDays: 0)]),
            // B 在 A 内部，却依赖 A：伪环的典型形状。
            TaskItem(id: groupB, title: "阶段 B", kind: .group, parentID: groupA,
                     dependencies: [TaskDependency(predecessorID: groupA, type: .fs, lagDays: 0)]),
            TaskItem(id: b1, title: "B1", kind: .task, parentID: groupB, durationDays: 2),
            TaskItem(id: b2, title: "B2", kind: .task, parentID: groupB, durationDays: 2),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: start, calendar: utc)

        let epoch = tasks.filter { task in
            result.tasks.first { $0.taskID == task.id }
                .map { $0.scheduledStart < start } ?? false
        }
        #expect(epoch.isEmpty, "任何任务都不得排到项目开始之前（epoch 兜底），实际：\(epoch.map(\.title))")
        #expect(!result.cycleTaskIDs.isEmpty, "祖先依赖必须被识别为环，否则既不排期也不告警")
        #expect(result.cycleTaskIDs.contains(groupB))
    }

    /// 对照：不依赖祖先时，同样的层级结构正常排期。
    @Test func sameShapeWithoutAncestorDependencySchedulesNormally() throws {
        let groupA = UUID(), groupB = UUID(), a1 = UUID(), b1 = UUID()
        let tasks = [
            TaskItem(id: groupA, title: "阶段 A", kind: .group),
            TaskItem(id: a1, title: "A1", kind: .task, parentID: groupA, durationDays: 2),
            TaskItem(id: groupB, title: "阶段 B", kind: .group, parentID: groupA),
            TaskItem(id: b1, title: "B1", kind: .task, parentID: groupB, durationDays: 2),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: start, calendar: utc)
        #expect(result.cycleTaskIDs.isEmpty)
        let scheduled = try #require(result.tasks.first { $0.taskID == b1 })
        #expect(scheduled.scheduledStart >= start)
    }
}

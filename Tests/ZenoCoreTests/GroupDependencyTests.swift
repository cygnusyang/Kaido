import Foundation
import Testing
@testable import ZenoCore

/// 群组依赖下推（issue #16）：群组作为阶段门，依赖必须对子树叶子生效，
/// 且群组自身的排期等于子树聚合（不再恒为 1 天）。
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let d0 = day(2026, 11, 2)

private func item(
    _ title: String,
    id: UUID,
    kind: TaskKind = .task,
    duration: Double? = nil,
    parent: UUID? = nil,
    deps: [TaskDependency] = []
) -> TaskItem {
    TaskItem(
        id: id, title: title, kind: kind, parentID: parent,
        durationDays: duration, dependencies: deps
    )
}

private func fs(_ id: UUID) -> TaskDependency {
    TaskDependency(predecessorID: id, type: .fs, lagDays: 0)
}

private func scheduled(_ result: ScheduleResult, _ id: UUID) -> ScheduledTask? {
    result.tasks.first { $0.taskID == id }
}

@Suite("群组依赖下推（#16）")
struct GroupDependencyTests {

    /// 群组 B 依赖群组 A ⇒ B 的叶子最早开始 ≥ A 的叶子完成。
    @Test func groupDependencyDelaysDescendants() throws {
        let groupA = UUID(), groupB = UUID()
        let a1 = UUID(), b1 = UUID()
        let tasks = [
            item("阶段 A", id: groupA, kind: .group),
            item("A1", id: a1, duration: 2, parent: groupA),
            item("阶段 B", id: groupB, kind: .group, deps: [fs(groupA)]),
            item("B1", id: b1, duration: 2, parent: groupB),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        let a = try #require(scheduled(result, a1))
        let b = try #require(scheduled(result, b1))
        #expect(b.scheduledStart >= a.scheduledFinish, "群组依赖未下推：B1 与 A1 并行")
        #expect(result.cycleTaskIDs.isEmpty)
    }

    /// 两级祖先：孙任务的阶段依赖同样生效。
    @Test func grandparentDependencyPropagates() throws {
        let outer = UUID(), inner = UUID(), gated = UUID()
        let deep = UUID(), other = UUID()
        let tasks = [
            item("外层阶段", id: outer, kind: .group, deps: [fs(gated)]),
            item("内层阶段", id: inner, kind: .group, parent: outer),
            item("深层任务", id: deep, duration: 1, parent: inner),
            item("前驱任务", id: gated, duration: 3),
            item("并行任务", id: other, duration: 1),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        let g = try #require(scheduled(result, gated))
        let d = try #require(scheduled(result, deep))
        let o = try #require(scheduled(result, other))
        #expect(d.scheduledStart >= g.scheduledFinish, "两级祖先依赖未传播到孙任务")
        #expect(o.scheduledStart < g.scheduledFinish, "无关任务不应被推迟")
    }

    /// 群组依赖成环：进 cycleTaskIDs 且计算不挂死。
    @Test func groupDependencyCycleIsDetected() throws {
        let groupA = UUID(), groupB = UUID()
        let a1 = UUID(), b1 = UUID()
        let tasks = [
            item("阶段 A", id: groupA, kind: .group, deps: [fs(groupB)]),
            item("A1", id: a1, duration: 1, parent: groupA),
            item("阶段 B", id: groupB, kind: .group, deps: [fs(a1)]),
            item("B1", id: b1, duration: 1, parent: groupB),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        #expect(!result.cycleTaskIDs.isEmpty, "群组依赖成环未被检出")
        #expect(result.cycleTaskIDs.contains(a1) || result.cycleTaskIDs.contains(b1))
    }

    /// 群组跨度 = 子树聚合（不再恒为 1 天）。
    @Test func groupWindowEqualsSubtreeSpan() throws {
        let group = UUID()
        let t1 = UUID(), t2 = UUID()
        let tasks = [
            item("阶段", id: group, kind: .group),
            item("T1", id: t1, duration: 2, parent: group),
            item("T2", id: t2, duration: 3, parent: group, deps: [fs(t1)]),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        let g = try #require(scheduled(result, group))
        let first = try #require(scheduled(result, t1))
        let last = try #require(scheduled(result, t2))
        #expect(g.scheduledStart == first.scheduledStart)
        #expect(g.scheduledFinish == last.scheduledFinish)
        #expect(g.durationDays == 5, "群组跨度应为子树合计 5 天，实际 \(g.durationDays)")
    }

    /// 无群组依赖时行为与改动前一致（回归守卫）。
    @Test func plainLeafDependenciesUnchanged() throws {
        let a = UUID(), b = UUID()
        let tasks = [
            item("A", id: a, duration: 2),
            item("B", id: b, duration: 1, deps: [fs(a)]),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        let sa = try #require(scheduled(result, a))
        let sb = try #require(scheduled(result, b))
        #expect(sa.scheduledStart == d0)
        #expect(sb.scheduledStart == sa.scheduledFinish)
    }

    /// 群组依赖必须等**整棵子树**结束（不是部分）：前一阶段内部串行时，
    /// 下游任务不得在阶段中途启动（v0.14.2 首版只顺延了一部分的回归守卫）。
    @Test func groupDependencyWaitsForWholeSubtree() throws {
        let groupA = UUID(), groupB = UUID()
        let a1 = UUID(), a2 = UUID(), b1 = UUID()
        let tasks = [
            item("阶段 A", id: groupA, kind: .group),
            item("A1", id: a1, duration: 2, parent: groupA),
            item("A2", id: a2, duration: 3, parent: groupA, deps: [fs(a1)]),
            item("阶段 B", id: groupB, kind: .group, deps: [fs(groupA)]),
            item("B1", id: b1, duration: 1, parent: groupB),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: d0, calendar: utc)
        let lastA = try #require(scheduled(result, a2))
        let b = try #require(scheduled(result, b1))
        #expect(b.scheduledStart >= lastA.scheduledFinish, "B1 必须在阶段 A 整棵子树完成后才启动")
    }
}

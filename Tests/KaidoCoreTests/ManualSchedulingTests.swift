import Foundation
import Testing
@testable import KaidoCore

/// 自动 / 手动排期（v1.3.6）：手动任务的 startDate 是权威，依赖只能提冲突、不能改写日期；
/// 后继仍按手动任务的结束日继续链下去。
private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private func day(_ y: Int, _ m: Int, _ d: Int) -> Date { utc.date(from: .init(year: y, month: m, day: d))! }
private let anchor = day(2025, 3, 3)

private func makeTask(
    _ title: String, id: UUID, duration: Double? = 2, startDate: Date? = nil,
    mode: TaskSchedulingMode = .auto, deps: [TaskDependency] = []
) -> TaskItem {
    TaskItem(id: id, title: title, startDate: startDate, durationDays: duration,
             dependencies: deps, schedulingMode: mode)
}

@Suite("自动/手动排期")
struct ManualSchedulingTests {
    /// 手动任务被前驱挤到更晚：日期不动，冲突被记录。
    @Test func manualTaskKeepsPinnedStartEvenWhenPredecessorPushes() throws {
        let pred = UUID(), pinned = UUID()
        let tasks = [
            makeTask("前驱", id: pred, duration: 5),
            makeTask("手动", id: pinned, startDate: anchor, mode: .manual,
                     deps: [TaskDependency(predecessorID: pred, type: .fs, lagDays: 0)]),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: anchor, calendar: utc)
        let scheduled = try #require(result.tasks.first { $0.taskID == pinned })
        #expect(scheduled.scheduledStart == anchor, "手动任务不得被前驱后移")
        let conflicts = try #require(result.manualConflicts)
        #expect(conflicts[pinned] != nil, "应记录依赖要求更晚的冲突")

        let violations = ViolationEngine.check(result: result, tasks: tasks, calendar: utc)
        #expect(violations.contains { if case .manualStartConflict = $0.reason { return true } else { return false } })
    }

    /// 后继仍按手动任务的结束日链下去。
    @Test func successorChainsFromManualFinish() throws {
        let manual = UUID(), next = UUID()
        let tasks = [
            makeTask("手动", id: manual, startDate: anchor, mode: .manual),
            makeTask("后继", id: next, duration: 1,
                     deps: [TaskDependency(predecessorID: manual, type: .fs, lagDays: 0)]),
        ]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: anchor, calendar: utc)
        let m = try #require(result.tasks.first { $0.taskID == manual })
        let s = try #require(result.tasks.first { $0.taskID == next })
        #expect(s.scheduledStart == m.scheduledFinish)
        #expect(result.manualConflicts == nil, "无冲突时不应产生记录")
    }

    /// 无 startDate 的手动任务退化为自动行为（不制造空窗）。
    @Test func manualWithoutStartDateFallsBackToAuto() throws {
        let id = UUID()
        let tasks = [makeTask("手动无日期", id: id, mode: .manual)]
        let result = ScheduleEngine.compute(tasks: tasks, projectStart: anchor, calendar: utc)
        let scheduled = try #require(result.tasks.first { $0.taskID == id })
        #expect(scheduled.scheduledStart == anchor)
        #expect(result.manualConflicts == nil)
    }
}

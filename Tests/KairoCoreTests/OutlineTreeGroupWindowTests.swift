import Foundation
import Testing

@testable import KairoCore

// 群组窗口口径统一（组 A / issue 组）：大纲行的群组窗口必须与排期结果同源。
//
// 两份实现曾分裂在两处：
//   1. 工期单位：大纲用自然日差，排期引擎用工作日（7 天日历下相等，5 天工作日历下不等）；
//   2. 环上子任务：排期引擎仍为其给出兜底窗口并计入群组聚合，大纲却按
//      `unscheduledTaskIDs` 把它们当无排期，群组窗口因此比甘特更窄、更晚。

private let gwGroupTitle = "阶段"
private let gwChildTitle = "子任务"
private let gwSiblingTitle = "跟随任务"

private let gwUTC: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func gwDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    gwUTC.date(from: DateComponents(year: y, month: m, day: d))!
}

private func gwEntry(_ schedule: ScheduleResult, _ id: UUID) -> ScheduledTask? {
    schedule.tasks.first { $0.taskID == id }
}

private func gwCalendarDays(from start: Date, to finish: Date) -> Double {
    Double(gwUTC.dateComponents(
        [.day], from: gwUTC.startOfDay(for: start), to: gwUTC.startOfDay(for: finish)
    ).day ?? 0)
}

private func gwGroupRow(
    tasks: [TaskItem], schedule: ScheduleResult, groupID: UUID
) throws -> OutlineRow {
    let tree = OutlineTree(tasks: tasks, schedule: schedule, expanded: [], calendar: gwUTC)
    return try #require(tree.rows.first { $0.id == groupID })
}

struct OutlineTreeGroupWindowTests {
    /// 5 天工作日历下群组工期必须与排期条目一致（自然日 7 天 ≠ 工作日 5 天）。
    @Test func OutlineTreeGroupDurationMatchesSchedule() throws {
        let group = TaskItem(title: gwGroupTitle, kind: .group)
        let child = TaskItem(title: gwChildTitle, parentID: group.id, durationDays: 5)
        let schedule = ScheduleEngine.compute(
            tasks: [group, child],
            projectStart: gwDay(2026, 9, 1),
            calendar: gwUTC,
            workCalendar: WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)
        )
        let entry = try #require(gwEntry(schedule, group.id))
        // 前置：夹具确实落在「自然日 ≠ 工作日」的区间，否则本用例证明不了任何事。
        let calendarDays = gwCalendarDays(from: entry.scheduledStart, to: entry.scheduledFinish)
        #expect(calendarDays > entry.durationDays)

        let row = try gwGroupRow(tasks: [group, child], schedule: schedule, groupID: group.id)

        #expect(row.aggregateStart == entry.scheduledStart)
        #expect(row.aggregateFinish == entry.scheduledFinish)
        #expect(row.aggregateDurationDays == entry.durationDays)
    }

    /// 环上子任务仍有兜底窗口并计入群组聚合：大纲群组窗口必须等于排期条目。
    @Test func OutlineTreeGroupIncludesCyclicChildWindow() throws {
        let group = TaskItem(title: gwGroupTitle, kind: .group)
        var a = TaskItem(title: gwChildTitle, parentID: group.id, durationDays: 3)
        let b = TaskItem(
            title: gwSiblingTitle, parentID: group.id, durationDays: 2,
            dependencies: [TaskDependency(predecessorID: a.id)]
        )
        a.dependencies = [TaskDependency(predecessorID: b.id)]
        let tasks = [group, a, b]

        let schedule = ScheduleEngine.compute(
            tasks: tasks, projectStart: gwDay(2026, 9, 1), calendar: gwUTC
        )
        #expect(Set(schedule.cycleTaskIDs) == [a.id, b.id])
        let entry = try #require(gwEntry(schedule, group.id))

        let row = try gwGroupRow(tasks: tasks, schedule: schedule, groupID: group.id)

        #expect(row.aggregateStart == entry.scheduledStart)
        #expect(row.aggregateFinish == entry.scheduledFinish)
        #expect(row.aggregateDurationDays == entry.durationDays)
    }

    /// 空群组没有可聚合窗口：即便排期表里有一条占位条目，也不得在纲里出窗口。
    @Test func OutlineTreeEmptyGroupHasNoWindow() throws {
        let empty = TaskItem(title: gwGroupTitle, kind: .group)
        let schedule = ScheduleEngine.compute(
            tasks: [empty], projectStart: gwDay(2026, 9, 1), calendar: gwUTC
        )

        let row = try gwGroupRow(tasks: [empty], schedule: schedule, groupID: empty.id)

        #expect(row.aggregateStart == nil)
        #expect(row.aggregateFinish == nil)
        #expect(row.aggregateDurationDays == nil)
    }

    /// 子任务全取消的群组同样没有窗口：已取消任务不占工期，也不该把群组顶出一个跨度。
    @Test func OutlineTreeAllCancelledGroupHasNoWindow() throws {
        let group = TaskItem(title: gwGroupTitle, kind: .group)
        let dropped = TaskItem(
            title: gwChildTitle, status: .cancelled, parentID: group.id, durationDays: 3
        )
        let tasks = [group, dropped]
        let schedule = ScheduleEngine.compute(
            tasks: tasks, projectStart: gwDay(2026, 9, 1), calendar: gwUTC
        )

        let row = try gwGroupRow(tasks: tasks, schedule: schedule, groupID: group.id)

        #expect(row.aggregateStart == nil)
        #expect(row.aggregateFinish == nil)
        #expect(row.aggregateDurationDays == nil)
    }
}

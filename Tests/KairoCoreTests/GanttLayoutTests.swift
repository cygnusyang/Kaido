import Foundation
import Testing
@testable import KairoCore

// 甘特布局纯函数测试（US-E4-04 / F-14-01 / F-14-13 / F-14-14）。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

/// 2026-11-02 为周一。
private let monday = day(2026, 11, 2)

private func scheduled(
    _ task: TaskItem,
    start: Date,
    days: Double,
    slack: Double = 0
) -> ScheduledTask {
    let finish = start.addingTimeInterval(days * 86_400)
    return ScheduledTask(
        taskID: task.id,
        durationDays: days,
        earliestStart: start,
        earliestFinish: finish,
        latestStart: start.addingTimeInterval(slack * 86_400),
        latestFinish: finish.addingTimeInterval(slack * 86_400),
        scheduledStart: start,
        scheduledFinish: finish,
        totalSlackDays: slack,
        freeSlackDays: slack
    )
}

private func result(
    _ items: [ScheduledTask],
    projectStart: Date? = nil,
    projectEnd: Date? = nil
) -> ScheduleResult {
    ScheduleResult(tasks: items, projectStart: projectStart, projectEnd: projectEnd)
}

struct GanttLayoutTests {
    @Test func contentRangeCoversProjectAndTaskBounds() throws {
        let task = TaskItem(title: "任务")
        let schedule = result(
            [scheduled(task, start: day(2026, 11, 3), days: 2)],
            projectStart: day(2026, 11, 2),
            projectEnd: day(2026, 11, 20)
        )
        let range = try #require(
            GanttLayoutEngine.contentRange(tasks: [task], schedule: schedule, calendar: utc)
        )
        #expect(range.start == monday)
        #expect(range.end == day(2026, 11, 20))
    }

    @Test func contentRangeFallsBackToScheduledTasks() throws {
        let first = TaskItem(title: "一")
        let second = TaskItem(title: "二")
        let schedule = result([
            scheduled(first, start: day(2026, 11, 3), days: 2),
            scheduled(second, start: day(2026, 11, 10), days: 2)
        ])
        let range = try #require(
            GanttLayoutEngine.contentRange(tasks: [first, second], schedule: schedule, calendar: utc)
        )
        #expect(range.start == day(2026, 11, 3))
        #expect(range.end == day(2026, 11, 12))
    }

    @Test func barPositionFollowsScheduledDates() {
        let task = TaskItem(title: "任务")
        let layout = GanttLayoutEngine.make(
            tasks: [task],
            schedule: result([scheduled(task, start: day(2026, 11, 4), days: 3)]),
            calendar: utc,
            zoom: .day,
            viewWidth: 800,
            windowStart: monday
        )
        let bar = layout.bars.first
        #expect(bar?.x == 64)
        #expect(bar?.width == 96)
        #expect(bar?.isMilestone == false)
    }

    @Test func barsOutsideWindowAreExcluded() {
        let inside = TaskItem(title: "窗内")
        let outside = TaskItem(title: "窗外")
        let layout = GanttLayoutEngine.make(
            tasks: [inside, outside],
            schedule: result([
                scheduled(inside, start: day(2026, 11, 6), days: 1),
                scheduled(outside, start: day(2026, 11, 1), days: 1)
            ]),
            calendar: utc,
            zoom: .day,
            viewWidth: 5 * 32,
            windowStart: day(2026, 11, 5)
        )
        #expect(layout.bars.map(\.taskID) == [inside.id])
    }

    @Test func barsStartingBeforeWindowKeepNegativeX() {
        let task = TaskItem(title: "跨界")
        let layout = GanttLayoutEngine.make(
            tasks: [task],
            schedule: result([scheduled(task, start: day(2026, 11, 3), days: 4)]),
            calendar: utc,
            zoom: .day,
            viewWidth: 5 * 32,
            windowStart: day(2026, 11, 5)
        )
        let bar = layout.bars.first
        #expect(bar?.x == -64)
        #expect(bar?.width == 128)
    }

    @Test func milestoneHasZeroWidth() {
        let milestone = TaskItem(title: "里程碑", kind: .milestone)
        let layout = GanttLayoutEngine.make(
            tasks: [milestone],
            schedule: result([scheduled(milestone, start: day(2026, 11, 4), days: 0)]),
            calendar: utc,
            zoom: .day,
            viewWidth: 400,
            windowStart: monday
        )
        let bar = layout.bars.first
        #expect(bar?.isMilestone == true)
        #expect(bar?.width == 0)
    }

    @Test func weekendBandsShadeSaturdayAndSunday() {
        // 2026-11-02 周一起七天窗口；日档位 32 点/天 → 周六索引 5、周日索引 6。
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .day,
            viewWidth: 7 * 32,
            windowStart: monday
        )
        #expect(layout.bands.map(\.x) == [160, 192])
        #expect(layout.bands.allSatisfy { $0.width == 32 })
    }

    @Test func zoomChangesDayWidth() {
        #expect(GanttZoom.day.dayWidth == 32)
        #expect(GanttZoom.week.dayWidth == 12)
        #expect(GanttZoom.month.dayWidth == 5)
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .month,
            viewWidth: 400,
            windowStart: monday
        )
        #expect(layout.dayWidth == 5)
    }

    @Test func dayZoomTicksIncludeMonthStart() {
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .day,
            viewWidth: 5 * 32,
            windowStart: day(2026, 11, 28)
        )
        #expect(layout.ticks.count == 5)
        let majors = layout.ticks.filter(\.isMajor)
        #expect(majors.count == 1)
        #expect(majors.first?.date == day(2026, 12, 1))
        #expect(majors.first?.label == "12月")
        #expect(majors.first?.x == 96)
    }

    @Test func monthZoomTicksAtMonthStart() {
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .month,
            viewWidth: 60 * 5,
            windowStart: day(2026, 11, 1)
        )
        #expect(layout.ticks.map(\.label) == ["11月", "12月"])
        #expect(layout.ticks.map(\.x) == [0, 30 * 5])
    }

    @Test func windowEndFollowsViewWidth() {
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .day,
            viewWidth: 320,
            windowStart: monday
        )
        #expect(layout.windowEnd == day(2026, 11, 12))
    }

    @Test func progressAndCriticalFlagsComeFromTasks() {
        let critical = TaskItem(title: "关键", progress: 0.5)
        let slack = TaskItem(title: "有余量")
        let layout = GanttLayoutEngine.make(
            tasks: [critical, slack],
            schedule: result([
                scheduled(critical, start: monday, days: 2, slack: 0),
                scheduled(slack, start: monday, days: 2, slack: 3)
            ]),
            calendar: utc,
            zoom: .day,
            viewWidth: 400,
            windowStart: monday
        )
        #expect(layout.bars.first?.progress == 0.5)
        #expect(layout.bars.first?.isCritical == true)
        #expect(layout.bars.last?.isCritical == false)
    }

    @Test func dayWidthOverrideWinsOverZoom() {
        let layout = GanttLayoutEngine.make(
            tasks: [],
            schedule: nil,
            calendar: utc,
            zoom: .month,
            viewWidth: 400,
            windowStart: monday,
            dayWidthOverride: 10
        )
        #expect(layout.dayWidth == 10)
        #expect(layout.windowEnd == monday.addingTimeInterval(40 * 86_400))
    }

    @Test func fitDayWidthSpreadsContentAcrossView() {
        let range = DateInterval(start: monday, end: day(2026, 11, 12))
        let width = GanttLayoutEngine.fitDayWidth(
            contentRange: range,
            viewWidth: 320,
            calendar: utc
        )
        #expect(width == 32)
    }
}

import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// D-040 / D-043 窗口覆盖度：按**排期区间**统计（不能用被窗口过滤过的画布条反推）。
// 边界取等：左边缘正好压在窗口起点 / 右边缘正好压在窗口终点的条都算窗口外。

private let coverageCalendar: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func coverageDay(_ day: Int) -> Date {
    coverageCalendar.date(from: DateComponents(year: 2026, month: 9, day: day))!
}

private func coverageEntry(_ id: UUID, start: Int, finish: Int) -> ScheduledTask {
    ScheduledTask(
        taskID: id,
        durationDays: coverageCalendar.dateComponents(
            [.day], from: coverageDay(start), to: coverageDay(finish)
        ).day.map(Double.init) ?? 0,
        earliestStart: coverageDay(start),
        earliestFinish: coverageDay(finish),
        latestStart: coverageDay(start),
        latestFinish: coverageDay(finish),
        scheduledStart: coverageDay(start),
        scheduledFinish: coverageDay(finish),
        totalSlackDays: 0,
        freeSlackDays: 0
    )
}

private func coverageSchedule(_ entries: [ScheduledTask], unscheduled: [UUID] = []) -> ScheduleResult {
    ScheduleResult(
        tasks: entries,
        projectStart: coverageDay(1),
        projectEnd: coverageDay(30),
        direction: .forward,
        cycleTaskIDs: [],
        projectStartDerived: false,
        unscheduledTaskIDs: unscheduled
    )
}

@Suite struct GanttWindowCoverageTests {
    private let windowStart = coverageDay(10)
    private let windowEnd = coverageDay(17)

    @Test("左侧外溢 + 右侧外溢 ⇒ 计数与 side == .both")
    func bothSides() {
        let a = UUID(), b = UUID(), c = UUID(), d = UUID()
        let schedule = coverageSchedule([
            coverageEntry(a, start: 1, finish: 3),    // 完全在左
            coverageEntry(b, start: 9, finish: 12),   // 跨窗口
            coverageEntry(c, start: 20, finish: 22),  // 完全在右
            coverageEntry(d, start: 31, finish: 31),  // 完全在右（零时长）
        ])
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage.offWindowCount == 3)
        #expect(coverage.side == .both)
    }

    @Test("只有左侧外溢 ⇒ side == .before")
    func onlyBefore() {
        let a = UUID(), b = UUID()
        let schedule = coverageSchedule([
            coverageEntry(a, start: 1, finish: 3),
            coverageEntry(b, start: 10, finish: 12),
        ])
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage.offWindowCount == 1)
        #expect(coverage.side == .before)
    }

    @Test("只有右侧外溢 ⇒ side == .after")
    func onlyAfter() {
        let a = UUID(), b = UUID()
        let schedule = coverageSchedule([
            coverageEntry(a, start: 11, finish: 12),
            coverageEntry(b, start: 20, finish: 22),
        ])
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage.offWindowCount == 1)
        #expect(coverage.side == .after)
    }

    @Test("全部在窗口内 ⇒ 0 且 side 是确定值")
    func noneOffWindow() {
        let schedule = coverageSchedule([coverageEntry(UUID(), start: 11, finish: 13)])
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage == GanttWindowCoverage.none)
        #expect(coverage.offWindowCount == 0)
        #expect(coverage.side == .both)
    }

    @Test("边界取等：右边缘压窗口起点 / 左边缘压窗口终点都算窗口外")
    func boundaryTouchingCountsAsOutside() {
        let left = UUID(), right = UUID()
        let schedule = coverageSchedule([
            coverageEntry(left, start: 8, finish: 10),   // finish == windowStart
            coverageEntry(right, start: 17, finish: 19), // start == windowEnd
        ])
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage.offWindowCount == 2)
        #expect(coverage.side == .both)
    }

    @Test("未排期任务不参与统计")
    func unscheduledIsIgnored() {
        let scheduled = UUID(), cancelled = UUID()
        let schedule = coverageSchedule(
            [coverageEntry(scheduled, start: 11, finish: 12), coverageEntry(cancelled, start: 1, finish: 2)],
            unscheduled: [cancelled]
        )
        let coverage = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(coverage.offWindowCount == 0, "unscheduled 的条目不算「窗口外」")
    }

    /// 筛选激活时只数可见行：与大纲/画布同一可见集，避免「无需看的行」也算进提示。
    @Test("给定可见行集合时只统计可见行")
    func visibleTaskIDsFilter() {
        let visible = UUID(), hidden = UUID()
        let schedule = coverageSchedule([
            coverageEntry(visible, start: 1, finish: 3),
            coverageEntry(hidden, start: 20, finish: 22),
        ])
        let all = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd
        )
        #expect(all.offWindowCount == 2)
        let filtered = GanttWindowCoverage.compute(
            schedule: schedule, windowStart: windowStart, windowEnd: windowEnd,
            visibleTaskIDs: [visible]
        )
        #expect(filtered.offWindowCount == 1)
        #expect(filtered.side == .before)
    }

    @Test("无排期结果 ⇒ 计数 0")
    func nilSchedule() {
        #expect(GanttWindowCoverage.compute(schedule: nil, windowStart: windowStart, windowEnd: windowEnd) == .none)
    }
}

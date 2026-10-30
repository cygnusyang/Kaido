import Foundation
import Testing
import KairoCore
import KairoPresentation

// D-054 呈现层几何判据：「窗口离开排期」怎么判、落点怎么算、入口优先级谁高。
//
// 用户口径（2026-10-30）：「在任何时候，只要当前的窗口不在任务规划的区间内，在那一行上面
// 就应该有一个按钮，可以快速回到任务排期的周期里面。」
//
// 这里只钉纯几何（`GanttSchedulePlacement`）与入口枚举，不含视图：位置与点击由
// AppTests/ReturnToScheduleEntryTests 钉。状态层「信号是否存在」由
// OffScheduleWindowTests 钉——三个文件各管一段，互不代劳。

@Suite("排期区间导航（D-054）")
struct GanttNavigationTests {
    /// 排期夹具：2025-01-06 起三条 3 天任务，任务跨度 [01-06, 01-11)。
    private func tasks() -> [TaskItem] {
        [6, 7, 8].map { day in
            TaskItem(
                title: "任务 \(day)",
                startDate: makeDate(2025, 1, day),
                durationDays: 3
            )
        }
    }

    private func schedule() -> ScheduleResult {
        makeSchedule(
            tasks(),
            projectStart: makeDate(2025, 1, 6),
            now: makeDate(2025, 3, 10)
        )
    }

    /// 排期区间 = 已排期任务的首尾，不含项目锚点；`unscheduledTaskIDs` 不参与。
    @Test func taskRangeCoversScheduledTasksOnly() throws {
        let range = try #require(GanttSchedulePlacement.taskRange(of: schedule()))
        #expect(range.start == makeDate(2025, 1, 6), "跨度起点应为最早的 scheduledStart，实测 \(range.start)")
        #expect(range.end == makeDate(2025, 1, 11), "跨度终点应为最晚的 scheduledFinish，实测 \(range.end)")

        // 锚点远在任务跨度之外（项目 2024-12-01 开始、2026 年结束），且有一条无排期任务：
        // 区间必须仍是任务的首尾——把锚点算进来，用户「回到排期」会落到没有任何条的空白处。
        let anchorID = UUID()
        let unscheduledID = UUID()
        let pinned = ScheduleResult(
            tasks: schedule().tasks + [
                ScheduledTask(
                    taskID: unscheduledID,
                    durationDays: 30,
                    earliestStart: makeDate(2024, 12, 1),
                    earliestFinish: makeDate(2024, 12, 31),
                    latestStart: makeDate(2024, 12, 1),
                    latestFinish: makeDate(2024, 12, 31),
                    scheduledStart: makeDate(2024, 12, 1),
                    scheduledFinish: makeDate(2024, 12, 31),
                    totalSlackDays: 0,
                    freeSlackDays: 0
                )
            ],
            projectStart: makeDate(2024, 12, 1),
            projectEnd: makeDate(2026, 12, 31),
            unscheduledTaskIDs: [unscheduledID, anchorID]
        )
        let pinnedRange = try #require(GanttSchedulePlacement.taskRange(of: pinned))
        #expect(pinnedRange.start == makeDate(2025, 1, 6), "项目锚点与无排期任务不该撑开区间，实测 \(pinnedRange.start)")
        #expect(pinnedRange.end == makeDate(2025, 1, 11), "项目锚点与无排期任务不该撑开区间，实测 \(pinnedRange.end)")

        #expect(GanttSchedulePlacement.taskRange(of: nil) == nil, "无排期时区间为 nil")
        let empty = ScheduleResult(tasks: [])
        #expect(GanttSchedulePlacement.taskRange(of: empty) == nil, "一条已排期任务都没有时区间为 nil")
    }

    // MARK: - 侧别：边界取等

    /// 边界取等：窗口终点正好压在排期首日 ⇒ 排期整体在窗口之后（半开区间里首日被排除）。
    @Test func windowEndAtScheduleStartIsAhead() {
        let side = GanttSchedulePlacement.offScheduleSide(
            windowStart: makeDate(2025, 1, 3),
            windowEnd: makeDate(2025, 1, 6),
            schedule: schedule()
        )
        #expect(side == .ahead, "windowEnd == schedule.start 应判 .ahead，实测 \(String(describing: side))")
    }

    /// 边界取等：窗口起点正好压在排期终点（排他端点）⇒ 排期整体在窗口之前。
    @Test func windowStartAtScheduleEndIsBehind() {
        let side = GanttSchedulePlacement.offScheduleSide(
            windowStart: makeDate(2025, 1, 11),
            windowEnd: makeDate(2025, 1, 14),
            schedule: schedule()
        )
        #expect(side == .behind, "windowStart == schedule.end 应判 .behind，实测 \(String(describing: side))")
    }

    @Test func overlappingWindowHasNoSide() {
        // 压在一个端点上不相交的反面：起点在排期内部、终点在排期内。
        let partial = GanttSchedulePlacement.offScheduleSide(
            windowStart: makeDate(2025, 1, 7),
            windowEnd: makeDate(2025, 1, 10),
            schedule: schedule()
        )
        #expect(partial == nil, "窗口压在排期内部时应相交，实测 \(String(describing: partial))")

        let wide = GanttSchedulePlacement.offScheduleSide(
            windowStart: makeDate(2025, 1, 1),
            windowEnd: makeDate(2025, 2, 1),
            schedule: schedule()
        )
        #expect(wide == nil, "宽窗口盖住整个排期时应相交，实测 \(String(describing: wide))")

        let noSchedule = GanttSchedulePlacement.offScheduleSide(
            windowStart: makeDate(2025, 1, 1),
            windowEnd: makeDate(2025, 1, 2),
            schedule: nil
        )
        #expect(noSchedule == nil, "无排期时没有侧别可言")
    }

    // MARK: - 入口优先级

    /// 排期之外优先于「还有 N 条在窗口外」：画布全空时说「还有几条」解决不了问题。
    @Test func navigationPrefersOffScheduleOverOffWindow() {
        let offSchedule = GanttSchedulePlacement.navigation(
            windowStart: makeDate(2025, 6, 1),
            windowEnd: makeDate(2025, 6, 4),
            schedule: schedule(),
            offWindowCount: 3
        )
        #expect(offSchedule == .offSchedule(.behind), "窗口滑过排期时应给「回到排期」，实测 \(String(describing: offSchedule))")

        let ahead = GanttSchedulePlacement.navigation(
            windowStart: makeDate(2024, 12, 1),
            windowEnd: makeDate(2024, 12, 4),
            schedule: schedule(),
            offWindowCount: 1
        )
        #expect(ahead == .offSchedule(.ahead), "窗口停在排期之前时应给「回到排期」，实测 \(String(describing: ahead))")

        let offWindow = GanttSchedulePlacement.navigation(
            windowStart: makeDate(2025, 1, 7),
            windowEnd: makeDate(2025, 1, 10),
            schedule: schedule(),
            offWindowCount: 2
        )
        #expect(offWindow == .offWindow, "相交但有条在窗口外时应给「适合项目」，实测 \(String(describing: offWindow))")

        let nothing = GanttSchedulePlacement.navigation(
            windowStart: makeDate(2025, 1, 7),
            windowEnd: makeDate(2025, 1, 10),
            schedule: schedule(),
            offWindowCount: 0
        )
        #expect(nothing == nil, "相交且无外溢条时不该有入口，实测 \(String(describing: nothing))")
    }

    // MARK: - 落点

    /// `.ahead`：落点是排期首日的零点，窗口立刻与排期相交。
    @Test func returnStartForAheadLandsOnScheduleFirstDay() throws {
        let range = try #require(GanttSchedulePlacement.taskRange(of: schedule()))
        let windowStart = makeDate(2024, 12, 20)
        let windowEnd = makeDate(2024, 12, 23)
        let target = GanttSchedulePlacement.returnStart(
            windowStart: windowStart,
            windowEnd: windowEnd,
            schedule: range,
            side: .ahead,
            calendar: testCalendar
        )
        #expect(target == makeDate(2025, 1, 6), "落点应为排期首日零点，实测 \(target)")

        let side = GanttSchedulePlacement.offScheduleSide(
            windowStart: target,
            windowEnd: target.addingTimeInterval(windowEnd.timeIntervalSince(windowStart)),
            schedule: schedule()
        )
        #expect(side == nil, "落点窗口必须与排期相交，实测 \(String(describing: side))")
    }

    /// `.behind`：落点让排期终点贴着窗口右缘，且压不早于排期首日。
    @Test func returnStartForBehindLeavesScheduleInsideWindow() throws {
        let range = try #require(GanttSchedulePlacement.taskRange(of: schedule()))
        let windowStart = makeDate(2025, 6, 1)
        let windowEnd = makeDate(2025, 6, 4)
        let span = windowEnd.timeIntervalSince(windowStart)
        let target = GanttSchedulePlacement.returnStart(
            windowStart: windowStart,
            windowEnd: windowEnd,
            schedule: range,
            side: .behind,
            calendar: testCalendar
        )
        #expect(
            target.addingTimeInterval(span) >= range.end,
            "落点窗口右缘应盖住排期终点：target+\(span)s=\(target.addingTimeInterval(span))，排期终点=\(range.end)"
        )
        #expect(
            target >= testCalendar.startOfDay(for: range.start),
            "落点不该早于排期首日零点，实测 \(target)"
        )
        #expect(target == makeDate(2025, 1, 8), "三天窗口对着 [01-06, 01-11) 应落到 01-08 零点，实测 \(target)")

        let side = GanttSchedulePlacement.offScheduleSide(
            windowStart: target,
            windowEnd: target.addingTimeInterval(span),
            schedule: schedule()
        )
        #expect(side == nil, "落点窗口必须与排期相交，实测 \(String(describing: side))")
    }

    /// 排期比窗口还短：夹到排期首日零点，不把整个排期推到窗口右缘之外。
    @Test func returnStartClampsToScheduleStart() {
        let shortRange = DateInterval(start: makeDate(2025, 1, 6), end: makeDate(2025, 1, 8))
        let windowStart = makeDate(2025, 6, 1)
        let windowEnd = makeDate(2025, 6, 11) // 10 天窗口，远长于 2 天排期
        let target = GanttSchedulePlacement.returnStart(
            windowStart: windowStart,
            windowEnd: windowEnd,
            schedule: shortRange,
            side: .behind,
            calendar: testCalendar
        )
        #expect(target == makeDate(2025, 1, 6), "短排期应夹到排期首日零点，实测 \(target)")
        #expect(
            target.addingTimeInterval(windowEnd.timeIntervalSince(windowStart)) >= shortRange.end,
            "夹取后窗口仍应盖住排期终点"
        )
    }

    // MARK: - 动作映射

    @Test func actionMapping() {
        #expect(
            GanttNavigation.offSchedule(.ahead).action == .returnToSchedule,
            "排期之外的入口应派发回到排期"
        )
        #expect(
            GanttNavigation.offSchedule(.behind).action == .returnToSchedule,
            "排期之外的入口应派发回到排期（两侧同一个动作）"
        )
        #expect(
            GanttNavigation.offWindow.action == .setFitZoom(true),
            "还有条在窗口外时沿用小入口「适合项目」"
        )
    }
}

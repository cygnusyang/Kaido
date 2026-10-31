import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// D-054 快照层验收：视图只该读 `GanttSnapshot.navigation` / `.scheduleRange`，
// 不该在 SwiftUI 里重算「窗口是否离开排期」。
//
// 与 GanttNavigationTests.swift（纯几何：taskRange / offScheduleSide / returnStart / 优先级）
// 分工：那个文件测函数，这个文件测**快照真的把结果暴露给了视图**，且与 fit / 无排期两条
// 退化路径一致。视图层的位置与点击在 AppTests/ReturnToScheduleEntryTests。

@Suite("快照暴露排期导航（D-054）")
struct GanttNavigationSnapshotTests {
    /// 三条任务：2025-01-06 起，各 3 天（任务跨度 = [01-06, 01-11)）。
    private func tasks() -> [TaskItem] {
        [6, 7, 8].map { day in
            TaskItem(title: "任务 \(day)", startDate: makeDate(2025, 1, day), durationDays: 3)
        }
    }

    /// 期望的任务跨度：由排期条目自己推导（最早开始 … 最晚结束），不借被测函数。
    private func expectedRange(_ schedule: ScheduleResult) -> DateInterval {
        let unscheduled = Set(schedule.unscheduledTaskIDs)
        let entries = schedule.tasks.filter { !unscheduled.contains($0.taskID) }
        let start = entries.map(\.scheduledStart).min()!
        let end = entries.map(\.scheduledFinish).max()!
        return DateInterval(start: start, end: end)
    }

    private func snapshot(
        tasks items: [TaskItem],
        windowStart: Date?,
        canvasWidth: Double,
        mode: WindowWidthMode = .preset(.day)
    ) -> WorkspaceSnapshot {
        var view = WorkspaceViewState()
        view.widthMode = mode
        view.windowStart = windowStart
        return makeSnapshot(
            state: makeState(items, projectStart: makeDate(2025, 1, 6)),
            schedule: items.isEmpty
                ? nil
                : makeSchedule(items, projectStart: makeDate(2025, 1, 6), now: makeDate(2025, 3, 10)),
            viewState: view,
            viewport: WorkspaceViewport(canvasWidth: canvasWidth, canvasHeight: 400),
            now: makeDate(2025, 3, 10)
        )
    }

    // MARK: - 窗口离开排期：快照给出侧别

    /// 窗口滑过排期（用户「朝右滚到底」的形态）：快照必须自带 .offSchedule(.behind)。
    @Test func snapshotReportsBehindWhenWindowPassedSchedule() {
        let items = tasks()
        let schedule = makeSchedule(items, projectStart: makeDate(2025, 1, 6), now: makeDate(2025, 3, 10))
        let range = expectedRange(schedule)
        let gantt = snapshot(tasks: items, windowStart: makeDate(2025, 6, 1), canvasWidth: 96).gantt

        #expect(
            gantt.scheduleRange == range,
            "快照要暴露任务跨度：\(String(describing: gantt.scheduleRange)) vs \(range)"
        )
        #expect(
            gantt.navigation == .offSchedule(.behind),
            "窗口在排期之后，navigation 应为 .offSchedule(.behind)，实测 \(String(describing: gantt.navigation))"
        )
    }

    /// 窗口停在排期之前：.offSchedule(.ahead)。
    @Test func snapshotReportsAheadWhenWindowBeforeSchedule() {
        let gantt = snapshot(tasks: tasks(), windowStart: makeDate(2024, 12, 20), canvasWidth: 96).gantt
        #expect(
            gantt.navigation == .offSchedule(.ahead),
            "窗口在排期之前，navigation 应为 .offSchedule(.ahead)，实测 \(String(describing: gantt.navigation))"
        )
    }

    /// 排期之外优先于外溢计数：两个信号同时成立时，入口必须是「回到排期」。
    @Test func snapshotPrefersOffScheduleOverOffWindow() {
        let gantt = snapshot(tasks: tasks(), windowStart: makeDate(2024, 12, 20), canvasWidth: 96).gantt
        #expect(gantt.offWindow.offWindowCount > 0, "夹具前提：三条任务全在窗口外，外溢计数应 > 0")
        #expect(
            gantt.navigation == .offSchedule(.ahead),
            "排期之外与外溢同时成立时必须选「回到排期」，实测 \(String(describing: gantt.navigation))"
        )
    }

    // MARK: - 相交：只剩「部分外溢」一条入口

    /// 看得见任务、但仍有条在窗口外：.offWindow（铺满项目），不是「回到排期」。
    @Test func snapshotReportsOffWindowWhenPartiallyOverlapping() {
        // 两条相距很远的任务：窗口 [01-07, 01-10) 压住第一条，第二条（01-20）整条在窗口右侧。
        let items = [
            TaskItem(title: "早任务", startDate: makeDate(2025, 1, 6), durationDays: 3),
            TaskItem(title: "晚任务", startDate: makeDate(2025, 1, 20), durationDays: 3),
        ]
        let gantt = snapshot(tasks: items, windowStart: makeDate(2025, 1, 7), canvasWidth: 96).gantt

        #expect(gantt.offWindow.offWindowCount > 0, "夹具前提：晚任务应在窗口外，实测 \(gantt.offWindow.offWindowCount)")
        #expect(
            gantt.navigation == .offWindow,
            "相交但有条在外时导航应为 .offWindow，实测 \(String(describing: gantt.navigation))"
        )
    }

    /// 排期全在窗口内：没有入口。
    @Test func snapshotHasNoNavigationWhenScheduleFullyVisible() {
        let gantt = snapshot(tasks: tasks(), windowStart: makeDate(2025, 1, 5), canvasWidth: 800).gantt
        #expect(gantt.offWindow.offWindowCount == 0, "夹具前提：宽窗口应装下全部任务")
        #expect(
            gantt.navigation == nil,
            "排期全在窗口内时不该有入口，实测 \(String(describing: gantt.navigation))"
        )
    }

    // MARK: - 退化路径：fit / 无排期

    /// 适合项目：窗口必然覆盖内容，navigation 必须是 nil（否则入口常驻、点了也没变化）。
    @Test func snapshotHasNoNavigationUnderFit() {
        let gantt = snapshot(tasks: tasks(), windowStart: nil, canvasWidth: 800, mode: .fit(.day)).gantt
        #expect(
            gantt.navigation == nil,
            "fit 铺满排期时不该有入口，实测 \(String(describing: gantt.navigation))"
        )
    }

    /// 没有排期：scheduleRange 与 navigation 都必须是 nil（入口对着空区间常驻是死键）。
    @Test func snapshotHasNoNavigationWithoutSchedule() {
        let gantt = snapshot(tasks: [], windowStart: makeDate(2025, 6, 1), canvasWidth: 96).gantt
        #expect(gantt.scheduleRange == nil, "无排期时不该给出跨度，实测 \(String(describing: gantt.scheduleRange))")
        #expect(gantt.navigation == nil, "无排期时不该有入口，实测 \(String(describing: gantt.navigation))")
    }

    /// 全部任务未排期（被循环依赖卡住）：跨度与侧别都为 nil，不能把最早/最晚取到无穷。
    @Test func placementIsNilWhenEveryTaskIsUnscheduled() {
        let blocked = ScheduleResult(
            tasks: [],
            projectStart: makeDate(2025, 1, 6),
            projectEnd: makeDate(2025, 1, 20),
            direction: .forward,
            cycleTaskIDs: [],
            projectStartDerived: false,
            unscheduledTaskIDs: [UUID(), UUID()]
        )
        #expect(GanttSchedulePlacement.taskRange(of: blocked) == nil, "全部未排期时没有区间")
        #expect(
            GanttSchedulePlacement.offScheduleSide(
                windowStart: makeDate(2025, 6, 1),
                windowEnd: makeDate(2025, 6, 4),
                schedule: blocked
            ) == nil,
            "全部未排期时不该判出侧别"
        )
    }
}

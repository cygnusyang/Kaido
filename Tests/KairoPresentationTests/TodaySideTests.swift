import Foundation
import Testing
import KairoCore
import KairoPresentation

/// 「回到今天」的方向提示（v1.3.5）：今天在窗口哪一侧，决定箭头朝左还是朝右。
/// 判据只依赖快照，不依赖渲染——画布胶囊与状态栏按钮共用同一字段。
@Suite("今天方向提示")
struct TodaySideTests {
    private func fixture(
        projectStart: Date,
        windowStart: Date,
        now: Date
    ) -> WorkspaceSnapshot {
        let task = TaskItem(title: "锚点任务", durationDays: 3)
        let state = makeState([task], projectStart: projectStart)
        var view = WorkspaceViewState()
        view.zoom = .day
        view.usesFitZoom = false
        view.windowSpanDays = nil
        view.windowStart = windowStart
        return makeSnapshot(
            state: state,
            schedule: makeSchedule([task], projectStart: projectStart, now: now),
            viewState: view,
            now: now
        )
    }

    /// 往前翻得很远：今天在窗口右侧之外，应提示「今天 ▶」。
    @Test func todaySitsRightOfWindowWhenLookingIntoThePast() {
        let now = makeDate(2025, 3, 10)
        let snapshot = fixture(
            projectStart: makeDate(2025, 1, 6),
            windowStart: makeDate(2025, 1, 6),
            now: now
        )
        #expect(snapshot.gantt.todayOutOfRange)
        #expect(snapshot.gantt.todaySide == .right)
        #expect(snapshot.statusBar.todayVisible == false)
        #expect(snapshot.statusBar.todaySide == .right)
    }

    /// 往后翻得很远：今天在窗口左侧之外，应提示「◀ 今天」。
    @Test func todaySitsLeftOfWindowWhenLookingIntoTheFuture() {
        let now = makeDate(2025, 3, 10)
        let snapshot = fixture(
            projectStart: makeDate(2025, 1, 6),
            windowStart: makeDate(2025, 8, 1),
            now: now
        )
        #expect(snapshot.gantt.todayOutOfRange)
        #expect(snapshot.gantt.todaySide == .left)
        #expect(snapshot.statusBar.todaySide == .left)
    }

    /// 今天在窗口内：不出方向提示（胶囊不渲染、状态栏也不加箭头）。
    @Test func todaySideIsNoneWhenWindowCoversToday() {
        let now = makeDate(2025, 3, 10)
        let snapshot = fixture(
            projectStart: makeDate(2025, 1, 6),
            windowStart: makeDate(2025, 3, 7),
            now: now
        )
        #expect(snapshot.gantt.todayOutOfRange == false)
        #expect(snapshot.gantt.todaySide == .none)
        #expect(snapshot.statusBar.todaySide == .none)
    }

    /// 方向与平移方向一致：往回平移后 todaySide 变 .left，往前平移后变 .right。
    @Test func sideFlipsWithPanDirection() {
        let now = makeDate(2025, 3, 10)
        let past = fixture(projectStart: makeDate(2025, 1, 6), windowStart: makeDate(2025, 2, 1), now: now)
        let future = fixture(projectStart: makeDate(2025, 1, 6), windowStart: makeDate(2025, 4, 1), now: now)
        #expect(past.gantt.todaySide == .right)
        #expect(future.gantt.todaySide == .left)
    }
}

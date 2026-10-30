import Foundation
import Testing
import KairoCore
import KairoPresentation

/// 连续横向平移（v1.3.7 / D-049）。
///
/// 旧实现把窗口起点归一为整天，再用「攒满一天才提交」的累积器补位移，结果跨度模式
/// 一天 100~171pt：手指滑了 160pt 画面纹丝不动，然后整幅跳一格——用户感受是「不顺畅 /
/// 拖不动」。本套用例钉住新口径：
/// 1. 窗口起点可带亚日相位，条按像素连续位移；
/// 2. 日界（刻度 / 非工作带 / 今天线）仍贴真实午夜，不随相位漂移；
/// 3. 相位不为零时今天线不会被半开区间判定吞掉。
@Suite("连续横向平移")
struct GanttContinuousPanTests {
    /// 固定「今天」：UTC 当天 14:20（带时分量，证明日界走 startOfDay）。
    private var now: Date { makeDate(2026, 10, 29).addingTimeInterval(14 * 3600 + 20 * 60) }
    /// 画布 700pt / 跨度 7 天 ⇒ 日宽恰好 100pt，断言可以写整数。
    private let canvasWidth: Double = 700
    private var dayWidth: Double { canvasWidth / Double(WorkspaceViewState.defaultWindowSpanDays) }

    /// 一个从 10/29 零点起、持续 3 天的任务；窗口 = 7 天跨度 + 指定起点。
    private func gantt(windowStart: Date) -> GanttSnapshot {
        let taskStart = makeDate(2026, 10, 29)
        let task = TaskItem(title: "Task", startDate: taskStart, durationDays: 3)
        let state = makeState([task], projectStart: taskStart)
        let schedule = makeSchedule([task], projectStart: taskStart, now: now)
        var viewState = WorkspaceViewState()
        viewState.widthMode = .span(
            days: WorkspaceViewState.defaultWindowSpanDays,
            base: .week
        )
        viewState.windowStart = windowStart
        return makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: canvasWidth, canvasHeight: 600),
            now: now
        ).gantt
    }

    private func lowerTicks(_ gantt: GanttSnapshot) -> [GanttTick] {
        gantt.ticks.filter { !$0.isMajor }
    }

    @Test func wholeDayWindowStartKeepsPhaseZero() {
        let aligned = gantt(windowStart: makeDate(2026, 10, 29))
        #expect(aligned.dayOrigin == makeDate(2026, 10, 29))
        #expect(aligned.dayPhase == 0)
        #expect(aligned.bars.first?.x == 0, "起点正好在任务开始那天：条贴左缘")
    }

    /// 滑半天 ⇒ 条左移半个日宽（连续），日界不动。
    @Test func subDayWindowStartShiftsBarsContinuously() {
        let half = gantt(windowStart: makeDate(2026, 10, 29).addingTimeInterval(0.5 * 86_400))

        #expect(abs(half.dayPhase - 0.5) < 1e-9)
        #expect(half.dayOrigin == makeDate(2026, 10, 29), "日界仍是当天零点")
        let x = half.bars.first?.x ?? .nan
        #expect(abs(x + dayWidth / 2) < 1e-6, "条随窗口滑走半格：预期 -50pt，实际 \(x)")
    }

    /// 相位不为零时，刻度仍从真实午夜铺起（第一格落在负坐标 = 当天已滑出左缘）。
    @Test func dayTicksStayOnMidnightGrid() {
        let quarter = gantt(windowStart: makeDate(2026, 10, 29).addingTimeInterval(0.25 * 86_400))
        let ticks = lowerTicks(quarter)

        #expect(ticks.first?.date == makeDate(2026, 10, 29), "第一格仍是 10/29 的零点")
        let firstX = ticks.first?.x ?? .nan
        #expect(abs(firstX + dayWidth * 0.25) < 1e-6, "零点在左缘外 0.25 格：预期 -25pt，实际 \(firstX)")
        // 7 天窗口从 06:00 起 ⇒ 覆盖 8 个日界（10/29 … 11/5）。
        #expect(ticks.count == 8, "带相位的 7 天窗口应铺 8 个日界，实际 \(ticks.count)")
        for (index, tick) in ticks.enumerated().dropFirst() {
            #expect(abs((tick.x - ticks[0].x) - Double(index) * dayWidth) < 1e-6, "日界必须等距")
        }
    }

    /// 今天线：当天还在屏内就不能判成「今天在窗口外」，否则方向胶囊会误导。
    @Test func todayLineSurvivesItsMidnightLeavingTheLeftEdge() {
        let today = makeDate(2026, 10, 29)
        let ahead = gantt(windowStart: today.addingTimeInterval(0.5 * 86_400))

        #expect(ahead.dayPhase > 0)
        #expect(ahead.todayOutOfRange == false, "今天仍占窗口右半，不能被判成窗口外")
        #expect(ahead.todaySide == .none, "今天可见时不显示方向胶囊")
        let todayX = ahead.todayX ?? .nan
        #expect(abs(todayX + dayWidth / 2) < 1e-6, "今天线画在真实零点上（左缘外半格）")
    }

    /// 真正的窗口外仍要给出方向：整窗都在今天之前 ⇒ 今天在右侧。
    @Test func todayLineReportsOutOfRangeWhenTheWholeDayIsPast() {
        let today = makeDate(2026, 10, 29)
        let past = gantt(windowStart: today.addingTimeInterval(-10 * 86_400))

        #expect(past.todayOutOfRange)
        #expect(past.todayX == nil)
        #expect(past.todaySide == .right)
    }
}

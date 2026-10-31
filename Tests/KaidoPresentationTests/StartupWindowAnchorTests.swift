import Foundation
import Testing
import KaidoCore
import KaidoPresentation

/// 启动窗口在**呈现层**的锚点契约（不依赖应用层，直接构造 viewState）：
/// - `windowSpanDays != nil`：窗口锚定「今天」，与内容起点、档位都无关；
/// - `windowSpanDays == nil`：行为与本功能引入前逐位一致（内容起点 + 档位 / fit，A7 口径）。
///
/// 固定的 UTC 日历（`testCalendar`）保证不随本机时区与夏令时漂移。
@Suite("启动窗口锚点")
struct StartupWindowAnchorTests {
    /// 固定「今天」：UTC 当天 14:20 —— 带时分量，以证明锚点走 `startOfDay` 而不是原样时间。
    private var now: Date { makeDate(2026, 10, 29).addingTimeInterval(14 * 3600 + 20 * 60) }

    /// 内容起点在指定日期的一个 5 天任务（排期与项目起点同源，内容范围 = 该日期）。
    private func makeFixture(contentStart: Date) -> (ProjectState, ScheduleResult) {
        let task = TaskItem(title: "Legacy task", startDate: contentStart, durationDays: 5)
        let state = makeState([task], projectStart: contentStart)
        let schedule = makeSchedule([task], projectStart: contentStart, now: now)
        return (state, schedule)
    }

    private func lowerTicks(_ gantt: GanttSnapshot) -> [GanttTick] {
        gantt.ticks.filter { !$0.isMajor }
    }

    // MARK: - 跨度模式：锚定今天

    @Test func spanWindowAnchorsTodayIgnoringContentStart() {
        let contentStart = makeDate(2020, 3, 1)
        let (state, schedule) = makeFixture(contentStart: contentStart)
        var viewState = WorkspaceViewState()
        // 档位故意设成 month：跨度的日宽与刻度都只由「画布宽 / 跨度」决定。
        viewState.widthMode = .span(
            days: WorkspaceViewState.defaultWindowSpanDays,
            base: .month
        )

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: 518, canvasHeight: 600),
            now: now
        )
        let gantt = snapshot.gantt
        let today = testCalendar.startOfDay(for: now)

        #expect(gantt.windowStart == today, "跨度模式起点应为今天，而不是内容起点")
        let spanDays = WorkspaceViewState.defaultWindowSpanDays
        #expect(abs(gantt.windowEnd.timeIntervalSince(gantt.windowStart) - Double(spanDays) * 86_400) < 1)
        #expect(abs(gantt.dayWidth - 518.0 / Double(spanDays)) < 1e-9)
        #expect(gantt.tickGranularity == .day, "74 px/天 应推导出逐日刻度，而非沿用 month 档位")
        #expect(gantt.bars.isEmpty, "2020 的任务不落在今天起的默认跨度窗口内")
        #expect(lowerTicks(gantt).count == spanDays, "跨度窗口应有与天数相同数量的下层刻度")
        #expect(lowerTicks(gantt).first?.date == today)
        #expect(gantt.todayX == 0)
        #expect(gantt.todayOutOfRange == false)
    }

    // MARK: - 非跨度模式：既有语义不变

    @Test func nilSpanKeepsContentAnchoredWindow() {
        let contentStart = makeDate(2020, 3, 1)
        let (state, schedule) = makeFixture(contentStart: contentStart)

        let snapshot = makeSnapshot(state: state, schedule: schedule, now: now)
        let gantt = snapshot.gantt

        #expect(gantt.windowStart == testCalendar.startOfDay(for: contentStart), "非跨度模式仍锚定内容起点")
        #expect(gantt.todayOutOfRange, "今天远在窗口之外：既有语义")
        #expect(gantt.todayX == nil)
        #expect(gantt.bars.count == 1)
        // 非跨度路径的刻度粒度仍由档位决定（A7 门禁口径不变）。
        #expect(gantt.tickGranularity == gantt.zoom)
    }

    @Test func nilSpanKeepsTodayInsideWindowWhenContentCoversToday() {
        let today = testCalendar.startOfDay(for: now)
        let (state, schedule) = makeFixture(contentStart: today)
        var viewState = WorkspaceViewState()
        viewState.widthMode = .preset(.week)

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            now: now
        )
        let gantt = snapshot.gantt

        #expect(gantt.windowStart == today)
        #expect(gantt.todayOutOfRange == false)
        #expect(gantt.todayX == 0)
    }

    // MARK: - 契约：跨度天数只有一处定义

    /// 7 天只在 `WorkspaceViewState.defaultWindowSpanDays` 里写一次：
    /// 用例与实现都引用它，改跨度时改常量即可，不会出现"用例里还写着 7"的漂移。
    @Test func defaultSpanIsSevenDays() {
        #expect(WorkspaceViewState.defaultWindowSpanDays == 7)
    }

    // MARK: - H1：非 fit 路径的默认起点是今天

    /// 自定义日宽（非 fit）时窗口起点取今天，而不是内容起点。
    /// 与跨度无关：这条路径没有 span，起点由 `canFit ? 内容起点 : 今天` 决定。
    @Test func customDayWidthAnchorsTodayNotContentStart() {
        let (state, schedule) = makeFixture(contentStart: makeDate(2020, 3, 1))
        var viewState = WorkspaceViewState()
        viewState.widthMode = .custom(dayWidth: 20, base: .week)

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: 518, canvasHeight: 600),
            now: now
        )
        let gantt = snapshot.gantt

        #expect(gantt.windowStart == testCalendar.startOfDay(for: now), "非 fit 路径起点应为今天")
        #expect(gantt.dayWidth == 20)
        #expect(gantt.usesFitZoom == false)
    }

    /// 预设档位（非 fit、无 custom、无 span）维持改动前的口径：起点是内容起点。
    /// 与 `customDayWidthAnchorsTodayNotContentStart` 是一对——「锚今天」只属于 custom / span 两条路径，
    /// 把它推广到预设档位会打破 A7 冻结基线。
    @Test func presetPathAnchorsContentStartNotToday() {
        let contentStart = makeDate(2020, 3, 1)
        let (state, schedule) = makeFixture(contentStart: contentStart)
        var viewState = WorkspaceViewState()
        viewState.widthMode = .preset(.week)

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: 518, canvasHeight: 600),
            now: now
        )
        let gantt = snapshot.gantt

        #expect(
            gantt.windowStart == testCalendar.startOfDay(for: contentStart),
            "预设档位的起点仍是内容起点"
        )
        #expect(gantt.todayOutOfRange, "内容在 2020 时今天不在窗口内，与改动前一致")
        #expect(gantt.tickGranularity == viewState.zoom)
    }

    // MARK: - 边界：画布宽为 0（首帧瞬态）

    /// 首帧画布宽 0 是瞬态（布局还没夹取），呈现层用 `max(width, 1)` 兜底。
    /// 要求：日宽有限且 > 0、窗口自洽、坐标无 NaN/inf；**不**要求跨度恰好等于默认天数
    /// ——1pt 兜底画布会算出比默认跨度更短的窗口，这是已知偏差，不为它改判据。
    @Test func zeroCanvasWidthKeepsGeometryFinite() {
        let today = testCalendar.startOfDay(for: now)
        let (state, schedule) = makeFixture(contentStart: today)
        var viewState = WorkspaceViewState()
        viewState.widthMode = .span(
            days: WorkspaceViewState.defaultWindowSpanDays,
            base: .week
        )

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: 0, canvasHeight: 600),
            now: now
        )
        let gantt = snapshot.gantt
        let spanLimit = Double(WorkspaceViewState.defaultWindowSpanDays) * 86_400

        #expect(gantt.dayWidth.isFinite, "0 宽画布不得产生 inf/NaN 日宽")
        #expect(gantt.dayWidth > 0)
        #expect(gantt.windowEnd > gantt.windowStart)
        #expect(
            gantt.windowEnd.timeIntervalSince(gantt.windowStart) <= spanLimit + 1,
            "兜底窗口不应超过默认跨度（允许已知偏差）"
        )
        for bar in gantt.bars {
            #expect(bar.x.isFinite)
            #expect(bar.width.isFinite)
        }
        for tick in gantt.ticks {
            #expect(tick.x.isFinite)
        }
        if let todayX = gantt.todayX {
            #expect(todayX.isFinite)
        }
    }

    // MARK: - 边界：跨度为 0 / 负数时不产生 NaN 坐标

    @Test(arguments: [0, -3])
    func nonPositiveSpanFallsBackToOneDay(spanDays: Int) {
        let today = testCalendar.startOfDay(for: now)
        let (state, schedule) = makeFixture(contentStart: today)
        var viewState = WorkspaceViewState()
        viewState.widthMode = .span(days: spanDays, base: .week)

        let snapshot = makeSnapshot(
            state: state,
            schedule: schedule,
            viewState: viewState,
            viewport: WorkspaceViewport(canvasWidth: 518, canvasHeight: 600),
            now: now
        )
        let gantt = snapshot.gantt

        #expect(gantt.dayWidth.isFinite, "跨度 ≤ 0 不得产生 inf / NaN 日宽")
        #expect(gantt.dayWidth == 518.0, "非法跨度按 1 天兜底 = 画布宽")
        #expect(abs(gantt.windowEnd.timeIntervalSince(gantt.windowStart) - 86_400) < 1)
    }
}

import Foundation
import Testing
import KairoCore
import KairoPresentation

/// 窗口宽度来源单测（D-041）：派生读取、持久化往返，以及视图状态上的只读兼容访问器。
///
/// 本文件钉的不是「哪个动作清哪个标志」（那正是合并前的失败模式），而是
/// **类型本身**：一个模式能派生出哪些量、落盘后读回什么、矛盾态为什么不可表示。
struct WindowWidthModeTests {
    // MARK: - 派生读取

    @Test func presetDerivesZoomAndNothingElse() {
        let mode = WindowWidthMode.preset(.month)
        #expect(mode.baseZoom == .month)
        #expect(mode.customDayWidth == nil)
        #expect(mode.spanDays == nil)
        #expect(!mode.isFit)
        #expect(!mode.isSpan)
        #expect(!mode.anchorsToday)
    }

    @Test func fitDerivesZoomAndFlag() {
        let mode = WindowWidthMode.fit(.day)
        #expect(mode.baseZoom == .day)
        #expect(mode.isFit)
        #expect(!mode.isSpan)
        #expect(mode.customDayWidth == nil)
        #expect(mode.spanDays == nil)
        #expect(!mode.anchorsToday)
    }

    @Test func customCarriesDayWidthAndBaseZoom() {
        let mode = WindowWidthMode.custom(dayWidth: 20, base: .month)
        #expect(mode.baseZoom == .month)
        #expect(mode.customDayWidth == 20)
        #expect(mode.spanDays == nil)
        #expect(!mode.isFit)
        // 自定义日宽是「盯当下」的路径：默认起点锚今天。
        #expect(mode.anchorsToday)
    }

    @Test func spanCarriesDaysAndBaseZoom() {
        let mode = WindowWidthMode.span(days: 7, base: .week)
        #expect(mode.baseZoom == .week)
        #expect(mode.spanDays == 7)
        #expect(mode.customDayWidth == nil)
        #expect(!mode.isFit)
        #expect(mode.anchorsToday)
    }

    /// 互斥由类型保证（四态是 enum 的 case，装不下非法组合），这里钉的是**默认态**：
    /// 新建视图状态必须是「适合项目 + 周档」，与合并前四个字段的默认值逐项一致。
    /// （旧版本这里断言「合法构造之间不矛盾」，构造不出非法组合，永远不会红——已删。）
    @Test func defaultStateIsFitOverWeek() {
        let state = WorkspaceViewState()
        #expect(state.widthMode == .fit(.week))
        #expect(state.zoom == .week)
        #expect(state.usesFitZoom)
        #expect(state.customDayWidth == nil)
        #expect(state.windowSpanDays == nil)
    }

    // MARK: - 模式切换

    @Test func withoutFitFallsBackToPresetWithSameBase() {
        #expect(WindowWidthMode.fit(.month).withoutFit == .preset(.month))
        // 其余模式原样返回：合并前 `usesFitZoom = false` 在自定义 / 跨度下就是 no-op。
        #expect(WindowWidthMode.custom(dayWidth: 20, base: .week).withoutFit
            == .custom(dayWidth: 20, base: .week))
        #expect(WindowWidthMode.span(days: 7, base: .week).withoutFit
            == .span(days: 7, base: .week))
        #expect(WindowWidthMode.preset(.day).withoutFit == .preset(.day))
    }

    @Test func asPresetDropsCustomAndSpanKeepingBase() {
        #expect(WindowWidthMode.custom(dayWidth: 33, base: .month).asPreset == .preset(.month))
        #expect(WindowWidthMode.span(days: 14, base: .day).asPreset == .preset(.day))
    }

    // MARK: - 持久化往返

    @Test func fromPersistedPrefersCustomOverFit() {
        // 合并前的口径：自定义日宽是唯一权威日宽，fit 同真也让位。
        let mode = WindowWidthMode.fromPersisted(
            zoom: .week, usesFitZoom: true, customDayWidth: 20
        )
        #expect(mode == .custom(dayWidth: 20, base: .week))
    }

    @Test func fromPersistedResolvesFitThenPreset() {
        #expect(WindowWidthMode.fromPersisted(zoom: .month, usesFitZoom: true, customDayWidth: nil)
            == .fit(.month))
        #expect(WindowWidthMode.fromPersisted(zoom: .day, usesFitZoom: false, customDayWidth: nil)
            == .preset(.day))
    }

    @Test func persistedRoundTripsPresetFitAndCustom() {
        let modes: [WindowWidthMode] = [
            .preset(.day), .fit(.month), .custom(dayWidth: 12.3, base: .week)
        ]
        for mode in modes {
            let persisted = mode.persisted
            #expect(WindowWidthMode.fromPersisted(
                zoom: persisted.zoom,
                usesFitZoom: persisted.usesFitZoom,
                customDayWidth: persisted.customDayWidth
            ) == mode)
        }
    }

    /// 跨度**不**持久化：读回退成基准档位，启动窗口由 store 重新注入跨度。
    @Test func persistedDropsSpan() {
        let persisted = WindowWidthMode.span(days: 7, base: .month).persisted
        #expect(persisted.zoom == .month)
        #expect(!persisted.usesFitZoom)
        #expect(persisted.customDayWidth == nil)
        #expect(WindowWidthMode.fromPersisted(
            zoom: persisted.zoom,
            usesFitZoom: persisted.usesFitZoom,
            customDayWidth: persisted.customDayWidth
        ) == .preset(.month))
    }

    // MARK: - 视图状态兼容访问器

    @Test func defaultStateMatchesLegacyFitWeek() {
        let state = WorkspaceViewState()
        #expect(state.widthMode == .fit(.week))
        #expect(state.zoom == .week)
        #expect(state.usesFitZoom)
        #expect(state.customDayWidth == nil)
        #expect(state.windowSpanDays == nil)
    }

    @Test func viewStateAccessorsMirrorWidthMode() {
        var state = WorkspaceViewState()
        state.widthMode = .custom(dayWidth: 20, base: .month)
        #expect(state.zoom == .month)
        #expect(state.customDayWidth == 20)
        #expect(state.windowSpanDays == nil)
        #expect(!state.usesFitZoom)

        state.widthMode = .span(days: 14, base: .day)
        #expect(state.zoom == .day)
        #expect(state.customDayWidth == nil)
        #expect(state.windowSpanDays == 14)
        #expect(!state.usesFitZoom)

        state.widthMode = .fit(.week)
        #expect(state.zoom == .week)
        #expect(state.usesFitZoom)
    }

    // MARK: - 状态栏档位（D-044 的单一判定）

    @Test func statusBarPresetFollowsWidthMode() {
        let task = TaskItem(title: "A", durationDays: 3)
        let state = makeState([task], projectStart: makeDate(2025, 3, 10))
        let now = makeDate(2025, 4, 15)
        let schedule = makeSchedule([task], projectStart: makeDate(2025, 3, 10), now: now)
        let cases: [(WindowWidthMode, ZoomPreset)] = [
            (.preset(.month), .month),
            (.fit(.week), .fit),
            (.custom(dayWidth: 20, base: .week), .custom),
            (.span(days: 7, base: .week), .span)
        ]
        for (mode, expected) in cases {
            var viewState = WorkspaceViewState()
            viewState.widthMode = mode
            let snapshot = makeSnapshot(
                state: state,
                schedule: schedule,
                viewState: viewState,
                now: now
            )
            #expect(snapshot.statusBar.zoom.preset == expected)
        }
    }
}

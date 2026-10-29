import AppKit
import Foundation
import KairoCore
import KairoPresentation
import Testing
@testable import KairoMacApp

/// 横向平移：判定/换算（controller）、视图级消费（NSView）、store 级连续推进。
///
/// D-028 的教训：这条链路前两轮都「逻辑单测全绿、真机全灭」，因为断言只覆盖了
/// 纯函数，真正的胶水层（谁消费事件、命中的是谁的 bounds、谁收到整天数）没有断言。
/// 本次把三层都钉住：`GanttScrollController` / `ScrollSurfaceView.handle` / `WorkspaceStore.panWindow`。
@MainActor
struct GanttScrollSurfaceTests {

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.pan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KairoFile.read(from: $0) }
        )
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 900, height: 700),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.contentView = NSView(frame: CGRect(x: 0, y: 0, width: 900, height: 700))
        return window
    }

    private func makeSurface(
        dayWidth: Double = 10,
        onDays: @escaping (Double) -> Void = { _ in }
    ) -> GanttScrollSurface.ScrollSurfaceView {
        let view = GanttScrollSurface.ScrollSurfaceView(frame: CGRect(x: 100, y: 100, width: 400, height: 300))
        view.update(dayWidth: dayWidth, onDays: onDays)
        return view
    }

    /// 合成一条精确滚动事件（`wheel2` = 横向像素位移，实测一一对应 `scrollingDeltaX`）。
    private func makeScrollEvent(deltaX: Int32 = 0, deltaY: Int32 = 0, shift: Bool = false) -> NSEvent {
        let cg = CGEvent(
            scrollWheelEvent2Source: nil,
            units: .pixel,
            wheelCount: 2,
            wheel1: deltaY,
            wheel2: deltaX,
            wheel3: 0
        )!
        if shift { cg.flags = .maskShift }
        return NSEvent(cgEvent: cg)!
    }

    // MARK: - controller：判定与连续换算

    /// 亚日位移立刻提交（v1.3.7 / D-049）：旧实现攒满整天再提交，跨度模式一天 171pt，
    /// 手指滑半天画面纹丝不动 —— 这才是用户说的「不顺畅」。
    @Test func subDayScrollIsCommittedImmediately() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true))
        #expect(controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true))
        #expect(days == [0.4, 0.4], "每一帧都要推进：0.4 天 = 0.4 × 日宽像素")
    }

    @Test func cursorOutsideIsPassedThrough() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(!controller.handle(deltaX: 30, deltaY: 0, shift: false, cursorInside: false))
        #expect(days.isEmpty, "画布外不得吞事件，否则外层容器滚不动")
    }

    /// 纵向占优的手势：横向分量照样平移（v1.3.6 起不再二选一）；
    /// 事件是否放行给纵向滚动由视图层按 |deltaY| 判定。
    @Test func verticalDominantEventStillUsesHorizontalComponent() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(controller.handle(deltaX: 1, deltaY: 30, shift: false, cursorInside: true))
        #expect(days == [0.1], "1pt ≈ 0.1 天，横向分量不得丢")
    }

    @Test func shiftWheelActsAsHorizontal() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(controller.handle(deltaX: 0, deltaY: 30, shift: true, cursorInside: true))
        #expect(days == [3], "无横向滚轮的鼠标：Shift + 滚轮转横向")
    }

    /// 缩放换日宽后，同样的像素位移按新日宽折算（连续口径没有余量可清）。
    @Test func dayWidthChangeUsesNewScaleImmediately() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }
        _ = controller.handle(deltaX: 9, deltaY: 0, shift: false, cursorInside: true)
        #expect(days == [0.9])

        controller.update(dayWidth: 5) { days.append($0) }
        _ = controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true)
        #expect(days == [0.9, 0.8])
    }

    @Test func tinyDayWidthFallsBackToHalfPoint() {
        var days: [Double] = []
        let controller = GanttScrollController(dayWidth: 0) { days.append($0) }
        _ = controller.handle(deltaX: 1, deltaY: 0, shift: false, cursorInside: true)
        #expect(days == [2], "日宽异常按 0.5 兜底，避免除零")
    }

    // MARK: - 视图级：事件真的被消费 / 放行

    @Test func horizontalScrollInsideSurfaceIsConsumed() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        var days: [Double] = []
        surface.update(dayWidth: 10) { days.append($0) }
        surface.cursorInScreen = { window.convertPoint(toScreen: CGPoint(x: 200, y: 200)) }

        let event = makeScrollEvent(deltaX: 30)
        #expect(surface.handle(event) == nil, "画布内的横向滚动必须被消费")
        #expect(days == [3])

        surface.stopMonitoring()
    }

    /// 斜向手势：横向分量照样平移，同时事件必须放行给纵向滚动（v1.3.6「横纵叠加」）。
    @Test func diagonalScrollPansAndPassesThrough() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        var days: [Double] = []
        surface.update(dayWidth: 10) { days.append($0) }
        surface.cursorInScreen = { window.convertPoint(toScreen: CGPoint(x: 200, y: 200)) }

        let event = makeScrollEvent(deltaX: 30, deltaY: 12)
        #expect(surface.handle(event) != nil, "含纵向分量的事件必须放行给纵向滚动")
        #expect(days == [3], "横向分量仍要生效")

        surface.stopMonitoring()
    }

    @Test func horizontalScrollOutsideSurfaceIsPassedThrough() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        var days: [Double] = []
        surface.update(dayWidth: 10) { days.append($0) }
        // 视口在 (100,100,400,300)，光标放到 (800,650)。
        surface.cursorInScreen = { window.convertPoint(toScreen: CGPoint(x: 800, y: 650)) }

        let event = makeScrollEvent(deltaX: 30)
        #expect(surface.handle(event) === event)
        #expect(days.isEmpty)

        surface.stopMonitoring()
    }

    /// D-034：视图在窗口但监听不在时，下一次 SwiftUI 更新必须把监听补回来。
    /// 现场事故是「attached → 原地 detached 两次 → 再无 attached」，画布平移整段失效。
    @Test func syncMonitoringStateReattachesAfterUnexpectedDetach() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)
        #expect(surface.isMonitoring, "进入窗口即安装")

        // 模拟生命周期漏事件：监听被摘掉，但视图仍在窗口里。
        surface.stopMonitoring()
        #expect(!surface.isMonitoring)

        surface.syncMonitoringState()
        #expect(surface.isMonitoring, "视图在窗口时下一次更新必须自愈补装")

        surface.stopMonitoring()
    }

    @Test func syncMonitoringStateStaysOffWithoutWindow() {
        let surface = makeSurface()
        #expect(!surface.isMonitoring)
        surface.syncMonitoringState()
        #expect(!surface.isMonitoring, "不在窗口里不得凭空安装监听")
    }

    @Test func surfaceInstallsMonitorWithViewLifetime() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        #expect(surface.isMonitoring, "进入窗口即安装监听")

        surface.stopMonitoring()
        #expect(!surface.isMonitoring)
    }

    // MARK: - store 级：连续推进（双向）

    @Test func panningRightShowsEarlierDates() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        store.panWindow(byDays: 3)
        let after = store.snapshot.gantt.windowStart
        #expect(Calendar.current.dateComponents([.day], from: after, to: before).day == 3)
        #expect(store.viewState.usesFitZoom == false)
    }

    @Test func panningLeftShowsLaterDates() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        store.panWindow(byDays: -2)
        let after = store.snapshot.gantt.windowStart
        #expect(Calendar.current.dateComponents([.day], from: before, to: after).day == 2)
    }

    @Test func consecutivePansAccumulateFromStoreState() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        store.panWindow(byDays: 2)
        store.panWindow(byDays: 3)
        let after = store.snapshot.gantt.windowStart
        #expect(Calendar.current.dateComponents([.day], from: after, to: before).day == 5)
    }

    /// 亚日平移：窗口起点带相位，画布才连续跟手（v1.3.7 / D-049）。
    /// 旧口径把起点归一为整天，逐帧位移全被取整吃掉——这就是「不顺畅」的根。
    @Test func subDayPanKeepsFractionalWindowStart() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        // 负数 = 看更晚日期：起点前移到 before + 1/4 天，仍在同一天内 ⇒ 相位 0.25。
        store.panWindow(byDays: -0.25)
        let after = store.snapshot.gantt.windowStart

        #expect(abs(after.timeIntervalSince(before) - 0.25 * 86_400) < 0.001, "位移不得被取整")
        #expect(abs(store.snapshot.gantt.dayPhase - 0.25) < 1e-6, "日界不动，相位只落在窗口起点上")
        #expect(store.snapshot.gantt.dayOrigin == before)
    }

    @Test func zeroDaysIsNoOp() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        // 用「平移前后视图状态整体相等」表达「0 天不改写状态」，不把口径钉在启动是 fit
        // 还是固定跨度上（v1.4 起启动即 7 天跨度，fit 恒关）。
        let stateBefore = store.viewState
        store.panWindow(byDays: 0)
        #expect(store.snapshot.gantt.windowStart == before)
        #expect(store.viewState == stateBefore, "0 天不应改写视图状态")
    }
}

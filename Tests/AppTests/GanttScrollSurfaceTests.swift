import AppKit
import Foundation
import KairoCore
import KairoPresentation
import Testing
@testable import KairoMacApp

/// 横向平移：判定/累积（controller）、视图级消费（NSView）、store 级整天推进。
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
        onDays: @escaping (Int) -> Void = { _ in }
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

    // MARK: - controller：判定与累积

    @Test func slowScrollAccumulatesWholeDays() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true))
        #expect(controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true))
        #expect(days.isEmpty, "不足一天不提交，避免慢速滑动「一天天蹦」")

        #expect(controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true))
        #expect(days == [1])
    }

    @Test func cursorOutsideIsPassedThrough() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(!controller.handle(deltaX: 30, deltaY: 0, shift: false, cursorInside: false))
        #expect(days.isEmpty, "画布外不得吞事件，否则外层容器滚不动")
    }

    @Test func verticalScrollIsPassedThrough() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(!controller.handle(deltaX: 1, deltaY: 30, shift: false, cursorInside: true))
        #expect(days.isEmpty)
    }

    @Test func shiftWheelActsAsHorizontal() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }

        #expect(controller.handle(deltaX: 0, deltaY: 30, shift: true, cursorInside: true))
        #expect(days == [3], "无横向滚轮的鼠标：Shift + 滚轮转横向")
    }

    @Test func dayWidthChangeResetsRemainder() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 10) { days.append($0) }
        _ = controller.handle(deltaX: 9, deltaY: 0, shift: false, cursorInside: true)

        // 切到日宽 5：旧余量清零，单次 4pt 不足一天。
        controller.update(dayWidth: 5) { days.append($0) }
        _ = controller.handle(deltaX: 4, deltaY: 0, shift: false, cursorInside: true)
        #expect(days.isEmpty)

        _ = controller.handle(deltaX: 1, deltaY: 0, shift: false, cursorInside: true)
        #expect(days == [1])
    }

    @Test func tinyDayWidthFallsBackToHalfPoint() {
        var days: [Int] = []
        let controller = GanttScrollController(dayWidth: 0) { days.append($0) }
        _ = controller.handle(deltaX: 1, deltaY: 0, shift: false, cursorInside: true)
        #expect(days == [2], "日宽异常按 0.5 兜底，避免除零")
    }

    // MARK: - 视图级：事件真的被消费 / 放行

    @Test func horizontalScrollInsideSurfaceIsConsumed() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        var days: [Int] = []
        surface.update(dayWidth: 10) { days.append($0) }
        surface.cursorInScreen = { window.convertPoint(toScreen: CGPoint(x: 200, y: 200)) }

        let event = makeScrollEvent(deltaX: 30)
        #expect(surface.handle(event) == nil, "画布内的横向滚动必须被消费")
        #expect(days == [3])

        surface.stopMonitoring()
    }

    @Test func horizontalScrollOutsideSurfaceIsPassedThrough() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        var days: [Int] = []
        surface.update(dayWidth: 10) { days.append($0) }
        // 视口在 (100,100,400,300)，光标放到 (800,650)。
        surface.cursorInScreen = { window.convertPoint(toScreen: CGPoint(x: 800, y: 650)) }

        let event = makeScrollEvent(deltaX: 30)
        #expect(surface.handle(event) === event)
        #expect(days.isEmpty)

        surface.stopMonitoring()
    }

    @Test func surfaceInstallsMonitorWithViewLifetime() {
        let window = makeWindow()
        let surface = makeSurface()
        window.contentView?.addSubview(surface)

        #expect(surface.isMonitoring, "进入窗口即安装监听")

        surface.stopMonitoring()
        #expect(!surface.isMonitoring)
    }

    // MARK: - store 级：整天推进（双向）

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

    @Test func zeroDaysIsNoOp() {
        let store = makeStore()
        let before = store.snapshot.gantt.windowStart
        store.panWindow(byDays: 0)
        #expect(store.snapshot.gantt.windowStart == before)
        #expect(store.viewState.usesFitZoom, "0 天不应改写视图状态")
    }
}

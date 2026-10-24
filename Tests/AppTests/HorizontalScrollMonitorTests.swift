import AppKit
import Foundation
import KairoPresentation
import Testing
@testable import KairoMacApp

/// 横向滚动监听：单实例仲裁、采集层闸门与事件级消费（D-027 / F-14-18）。
///
/// 背景：SwiftUI 在结构身份变化时会重复触发 `onAppear`，旧实例的
/// `onDisappear` 不保证执行。多个监听同时存活时，先安装的实例会抢占事件并用
/// 过期的窗口起点派发 `.panWindow`，表现为「双指横滑画布不动」。
///
/// 另有两处仅靠纯函数测不到的闸门在这里锁定（真机事故复盘 D-027）：
/// 事件是否真的被消费（`handle` 的返回值），以及「编辑中」是否只按光标落点判定。
@MainActor
struct HorizontalScrollMonitorTests {

    private func makeMonitor(
        viewport: @escaping () -> CGRect? = { nil },
        window: @escaping () -> NSWindow? = { nil },
        cursor: @escaping () -> CGPoint = { .zero },
        handler: @escaping (Double) -> Void = { _ in }
    ) -> HorizontalScrollMonitor {
        HorizontalScrollMonitor(.init(
            viewportInWindow: viewport,
            window: window,
            cursorInScreen: cursor,
            handler: handler
        ))
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

    // MARK: - 单实例仲裁

    @Test func startingSecondMonitorTakesOverFromFirst() {
        let first = makeMonitor()
        let second = makeMonitor()

        first.start()
        #expect(first.isRunning)

        second.start()
        #expect(!first.isRunning, "旧实例必须被接管停掉，否则会继续消费事件")
        #expect(second.isRunning)
        #expect(HorizontalScrollMonitor.activeInstance === second)

        second.stop()
        #expect(!second.isRunning)
        #expect(HorizontalScrollMonitor.activeInstance == nil)
    }

    @Test func stoppingStaleInstanceDoesNotKillActiveOne() {
        let stale = makeMonitor()
        let current = makeMonitor()

        stale.start()
        current.start()

        // 迟到的 onDisappear 只应作用在自己身上。
        stale.stop()
        #expect(current.isRunning)
        #expect(HorizontalScrollMonitor.activeInstance === current)

        current.stop()
    }

    // MARK: - 采集层闸门

    @Test func unmeasuredCanvasNeverConsumesScroll() {
        // 视图尚未上报窗口/视口时不得消费事件（否则会吞掉容器滚动）。
        let monitor = makeMonitor()
        #expect(
            monitor.decide(deltaX: 12, deltaY: 0, shift: false, isEditingText: false)
                == .ignore(reason: .windowUnavailable)
        )
    }

    @Test func verticalScrollIsNotCollectedEvenWithoutGeometry() {
        // 纵向滚动在采集层就被判为「不归横向平移管」，与几何是否就绪无关。
        let monitor = makeMonitor()
        #expect(
            monitor.decide(deltaX: 1, deltaY: 12, shift: false, isEditingText: false)
                == .ignore(reason: .verticalOnly)
        )
    }

    // MARK: - 事件级消费（handle 返回值）

    @Test func horizontalScrollInsideCanvasIsConsumed() {
        let window = makeWindow()
        let viewport = CGRect(x: 100, y: 100, width: 400, height: 300)
        let cursor = window.convertPoint(toScreen: CGPoint(x: 200, y: 200))
        var received: [Double] = []

        let monitor = makeMonitor(
            viewport: { viewport },
            window: { window },
            cursor: { cursor },
            handler: { received.append($0) }
        )

        let swallowed = monitor.handle(makeScrollEvent(deltaX: 12))
        #expect(swallowed == nil, "画布内的横向滚动必须被消费，否则会被容器当作别的滚动手势")
        #expect(received == [12])
    }

    @Test func scrollOutsideCanvasIsPassedThrough() {
        let window = makeWindow()
        let viewport = CGRect(x: 100, y: 100, width: 400, height: 300)
        let cursor = window.convertPoint(toScreen: CGPoint(x: 800, y: 650))
        var received: [Double] = []

        let monitor = makeMonitor(
            viewport: { viewport },
            window: { window },
            cursor: { cursor },
            handler: { received.append($0) }
        )

        let event = makeScrollEvent(deltaX: 12)
        #expect(monitor.handle(event) === event)
        #expect(received.isEmpty)
    }

    @Test func verticalScrollInsideCanvasIsPassedThrough() {
        // 画布内纵向滚动必须留给外层 ScrollView。
        let window = makeWindow()
        let viewport = CGRect(x: 100, y: 100, width: 400, height: 300)
        let cursor = window.convertPoint(toScreen: CGPoint(x: 200, y: 200))
        var received: [Double] = []

        let monitor = makeMonitor(
            viewport: { viewport },
            window: { window },
            cursor: { cursor },
            handler: { received.append($0) }
        )

        let event = makeScrollEvent(deltaY: 30)
        #expect(monitor.handle(event) === event)
        #expect(received.isEmpty)
    }

    @Test func shiftWheelInsideCanvasIsConsumed() {
        // 无横向滚轮的鼠标：Shift + 滚轮转横向。
        let window = makeWindow()
        let viewport = CGRect(x: 100, y: 100, width: 400, height: 300)
        let cursor = window.convertPoint(toScreen: CGPoint(x: 200, y: 200))
        var received: [Double] = []

        let monitor = makeMonitor(
            viewport: { viewport },
            window: { window },
            cursor: { cursor },
            handler: { received.append($0) }
        )

        let swallowed = monitor.handle(makeScrollEvent(deltaY: 20, shift: true))
        #expect(swallowed == nil)
        #expect(received == [20])
    }

    // MARK: - 「编辑中」判据（D-027 末道闸）

    @Test func textEditingIsJudgedByCursorNotByFirstResponder() {
        // 事故根因：SwiftUI 工作台窗口没有输入焦点时，首响应者仍是共用 field editor，
        // 若只看 `firstResponder is NSTextView`，光标在画布上的滚动也会被放行。
        let window = makeWindow()
        let textView = NSTextView(frame: CGRect(x: 100, y: 100, width: 200, height: 40))
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)
        #expect(window.firstResponder is NSTextView)

        let cursorInsideText = window.convertPoint(toScreen: CGPoint(x: 150, y: 110))
        let cursorOnCanvas = window.convertPoint(toScreen: CGPoint(x: 600, y: 400))

        #expect(
            HorizontalScrollMonitor.isEditingText(
                window: window, cursorInScreen: cursorInsideText
            ),
            "光标落在文本视图内才让出滚动"
        )
        #expect(
            !HorizontalScrollMonitor.isEditingText(
                window: window, cursorInScreen: cursorOnCanvas
            ),
            "首响应者是文本框也不影响画布内的横向平移"
        )
    }

    @Test func nonEditableTextViewDoesNotBlockPanning() {
        let window = makeWindow()
        let textView = NSTextView(frame: CGRect(x: 100, y: 100, width: 200, height: 40))
        textView.isEditable = false
        window.contentView?.addSubview(textView)
        window.makeFirstResponder(textView)

        let cursorInsideText = window.convertPoint(toScreen: CGPoint(x: 150, y: 110))
        #expect(
            !HorizontalScrollMonitor.isEditingText(window: window, cursorInScreen: cursorInsideText)
        )
    }
}

import AppKit
import Foundation
import KairoPresentation
import Testing
@testable import KairoMacApp

/// 横向滚动监听：单实例仲裁与采集层闸门（D-027 / F-14-18）。
///
/// 背景：SwiftUI 在结构身份变化时会重复触发 `onAppear`，旧实例的
/// `onDisappear` 不保证执行。多个监听同时存活时，先安装的实例会抢占事件并用
/// 过期的窗口起点派发 `.panWindow`，表现为「双指横滑画布不动」。
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
}

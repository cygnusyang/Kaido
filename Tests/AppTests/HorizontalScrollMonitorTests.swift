import AppKit
import Foundation
import Testing
@testable import KairoMacApp

/// 横向滚动监听的单实例仲裁（D-027）。
///
/// 背景：SwiftUI 在视图结构身份变化时会重复触发 `onAppear`，旧实例的
/// `onDisappear` 不保证执行。多个监听同时存活时，先安装的实例会抢占事件并用
/// 过期的窗口起点派发 `.panWindow`，表现为「双指横滑画布不动」。
@MainActor
struct HorizontalScrollMonitorTests {

    @Test func startingSecondMonitorTakesOverFromFirst() {
        let first = HorizontalScrollMonitor(viewportRect: { .zero }, handler: { _ in })
        let second = HorizontalScrollMonitor(viewportRect: { .zero }, handler: { _ in })

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
        let stale = HorizontalScrollMonitor(viewportRect: { .zero }, handler: { _ in })
        let current = HorizontalScrollMonitor(viewportRect: { .zero }, handler: { _ in })

        stale.start()
        current.start()

        // 迟到的 onDisappear 只应作用在自己身上。
        stale.stop()
        #expect(current.isRunning)
        #expect(HorizontalScrollMonitor.activeInstance === current)

        current.stop()
    }
}

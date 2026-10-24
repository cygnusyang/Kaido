import AppKit
import SwiftUI

/// 画布视口的窗口坐标探针（F-14-18）。
///
/// 为什么不用 SwiftUI 的 `GeometryReader` + `.global`：`.global` 是 SwiftUI 自有的
/// 坐标空间，而 `NSEvent.locationInWindow` / `NSWindow.convertPoint(fromScreen:)`
/// 是 AppKit 窗口坐标（左下原点）。两者原点与是否含标题栏都不保证一致，跨空间比较
/// 会让命中矩形整体偏移 —— D-027 二次排查确认「双指横滑无反应」的成因之一即此。
///
/// 本探针是一个纯几何 NSView：把自己的 bounds 换算到窗口坐标上报，滚动监听与光标
/// 位置就都在**同一个**空间里比较，无需手工翻转 Y 轴。
struct CanvasViewportProbe: NSViewRepresentable {
    /// 上报（所属窗口，视口在窗口坐标中的矩形）；窗口未挂载时不回调。
    let onResolve: (NSWindow, CGRect) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onResolve = onResolve
        return view
    }

    func updateNSView(_ view: ProbeView, context: Context) {
        view.onResolve = onResolve
        view.report()
    }

    /// 探针本体：不吃任何事件（`hitTest` 返回 nil），只做几何上报。
    final class ProbeView: NSView {
        var onResolve: ((NSWindow, CGRect) -> Void)?

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            report()
        }

        override func layout() {
            super.layout()
            report()
        }

        /// `convert(bounds, to: nil)` = 窗口基底坐标（左下原点）。
        func report() {
            guard let window, window.contentView != nil else { return }
            onResolve?(window, convert(bounds, to: nil))
        }
    }
}

import AppKit
import Foundation

/// 画布横向滚动捕获（F-14-18，薄胶水层）。
///
/// SwiftUI 没有 scrollWheel 钩子，且画布是「视口宽的 Canvas + 时间窗」模型
/// （无横向 ScrollView），故用本地事件监听把画布内的横向滚动换算成窗口平移。
///
/// 边界纪律：
/// - 只消费「光标在画布视口内 + 主窗口 + 非文本编辑」的横向滚动，其余原样放行；
/// - 不做任何几何换算（交给 `HorizontalPanAccumulator` 纯函数），本类只做命中与转发；
/// - 离屏渲染测试无窗口事件循环，本层不进单测，行为由纯函数 + Store 用例覆盖。
@MainActor
final class HorizontalScrollMonitor {
    /// 画布视口矩形（窗口内容坐标，左上原点）。
    private let viewportRect: () -> CGRect
    /// 横向位移回调（点）；正 = 内容右移。
    private let handler: (Double) -> Void
    private var token: Any?

    init(viewportRect: @escaping () -> CGRect, handler: @escaping (Double) -> Void) {
        self.viewportRect = viewportRect
        self.handler = handler
    }

    func start() {
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
    }

    /// 命中则消费事件（返回 nil），否则原样放行。
    private func handle(_ event: NSEvent) -> NSEvent? {
        guard let window = event.window, let contentView = window.contentView else { return event }
        // 只处理主窗口（面板/弹层上的滚动交给各自容器）。
        if let main = NSApp.mainWindow, window !== main { return event }
        // 文本编辑中不抢滚动。
        if window.firstResponder is NSTextView { return event }

        let point = contentView.convert(event.locationInWindow, from: nil)
        // AppKit 左下原点 → SwiftUI global 左上原点。
        let flipped = CGPoint(x: point.x, y: contentView.bounds.height - point.y)
        guard viewportRect().contains(flipped) else { return event }

        let deltaX = event.scrollingDeltaX
        let deltaY = event.scrollingDeltaY
        let shift = event.modifierFlags.contains(.shift)
        // 横向分量占优：横向平移；Shift + 纵向：转横向（无横向滚轮的鼠标）。
        guard abs(deltaX) > abs(deltaY) || (shift && abs(deltaY) > 0) else { return event }
        let delta = abs(deltaX) > abs(deltaY) ? deltaX : deltaY
        guard delta != 0 else { return event }
        handler(Double(delta))
        return nil
    }
}

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
    /// 当前唯一活动的监听实例（D-027）。
    ///
    /// SwiftUI 在结构身份变化时会重复触发 `onAppear`，而旧实例的 `onDisappear`
    /// 不保证执行；若放任多个实例同时 `start()`，先安装的实例会持续抢占事件，
    /// 并用自己那份已经过期的窗口起点派发 `.panWindow`，表现为「双指横滑画布不动」。
    /// 因此 `start()` 是接管语义：新实例启动即停掉旧实例。
    private static weak var active: HorizontalScrollMonitor?

    /// 画布视口矩形（窗口内容坐标，左上原点）。
    private let viewportRect: () -> CGRect
    /// 横向位移回调（点）；正 = 内容右移。
    private let handler: (Double) -> Void
    private var token: Any?

    /// 是否正在监听（单实例仲裁的可测口径）。
    var isRunning: Bool { token != nil }

    /// 当前活动实例（测试断言用）。
    static var activeInstance: HorizontalScrollMonitor? { active }

    init(viewportRect: @escaping () -> CGRect, handler: @escaping (Double) -> Void) {
        self.viewportRect = viewportRect
        self.handler = handler
    }

    func start() {
        // 接管：先停掉可能残留的旧实例，保证同一时刻只有一个监听在消费事件。
        if let previous = Self.active, previous !== self {
            previous.stop()
        }
        guard token == nil else { return }
        token = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self else { return event }
            return self.handle(event)
        }
        Self.active = self
    }

    func stop() {
        if let token {
            NSEvent.removeMonitor(token)
        }
        token = nil
        if Self.active === self {
            Self.active = nil
        }
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

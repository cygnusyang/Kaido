import AppKit
import SwiftUI
import KairoPresentation
import os

/// 甘特画布的横向滚动承接层（F-14-18 / D-028）。
///
/// **为什么是「视图自己持有」而不是进程级单例**（D-028 根因）：
/// 此前把「监听、命中的视口矩形、所属窗口、派发目标 store、窗口起点」拆成若干
/// 全局件（`HorizontalScrollMonitor.shared` / `HorizontalPanContext.shared`），
/// 视图重建或容器滚动位移后这些值会变旧而无人更新，表现为「平移在自己的窗口里
/// 静默失效，只有重启进程才恢复」——D-027 之后第三次回归即此。
///
/// 本层的不变量：
/// 1. 监听装在视图的 `viewDidMoveToWindow` / 摘在 `viewWillMove(toWindow: nil)`，
///    生命周期严格等于「视图在窗口里的存活期」，不残留；
/// 2. 命中判定用**自己的 bounds 现场换算**（`convert(bounds, to: nil)` ↔ 屏幕光标），
///    不缓存矩形，容器滚动/窗口缩放后立刻正确；
/// 3. 派发目标由 `updateNSView` 每次渲染注入（强引用），不存弱引用；
/// 4. 窗口起点只由 store 决定（`WorkspaceStore.panWindow(byDays:)`），视图侧不做
///    乐观推进，连续事件不会越滑越偏。
struct GanttScrollSurface: NSViewRepresentable {
    /// 当前生效日宽（像素 → 整天的换算基准）。
    let dayWidth: Double
    /// 提交整天数：正 = 内容右移（看更早日期）。
    let onDays: (Int) -> Void

    func makeNSView(context: Context) -> ScrollSurfaceView {
        let view = ScrollSurfaceView()
        view.update(dayWidth: dayWidth, onDays: onDays)
        return view
    }

    func updateNSView(_ view: ScrollSurfaceView, context: Context) {
        view.update(dayWidth: dayWidth, onDays: onDays)
    }

    /// 承接滚动的 NSView：不吃鼠标事件（`hitTest` 返回 nil），画布手势照旧。
    final class ScrollSurfaceView: NSView {
        private static let logger = Logger(subsystem: "ai.kairo.app", category: "gantt-pan")
        /// 当前活动视图：新视图安装即接管，旧视图的监听当场摘除（D-027 的
        /// 单实例教训保留，但仲裁对象是「活着的视图」，不是「常驻的上下文」）。
        private static weak var active: ScrollSurfaceView?

        private var controller: GanttScrollController?
        private var monitor: Any?
        /// 光标屏幕坐标（测试可注入）。
        var cursorInScreen: () -> CGPoint = { NSEvent.mouseLocation }

        /// 是否正在监听（可测口径）。
        var isMonitoring: Bool { monitor != nil }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        func update(dayWidth: Double, onDays: @escaping (Int) -> Void) {
            if let controller {
                controller.update(dayWidth: dayWidth, onDays: onDays)
            } else {
                controller = GanttScrollController(dayWidth: dayWidth, onDays: onDays)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil { stopMonitoring() }
            super.viewWillMove(toWindow: newWindow)
        }

        private func startMonitoring() {
            if let previous = Self.active, previous !== self {
                previous.stopMonitoring()
            }
            Self.active = self
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
            // 现场排查口径：只记「装/卸」与首次消费，高频滚动不刷屏。
            Self.logger.notice("scroll surface attached (pid=\(ProcessInfo.processInfo.processIdentifier))")
        }

        func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            if Self.active === self { Self.active = nil }
            Self.logger.notice("scroll surface detached")
        }

        /// 一条滚动事件：命中则消费（返回 nil），否则原样放行。
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let controller else { return event }
            let consumed = controller.handle(
                deltaX: Double(event.scrollingDeltaX),
                deltaY: Double(event.scrollingDeltaY),
                shift: event.modifierFlags.contains(.shift),
                cursorInside: cursorInsideBounds()
            )
            return consumed ? nil : event
        }

        /// 光标是否落在本视图当前所占的窗口区域内（现场换算，不缓存）。
        func cursorInsideBounds() -> Bool {
            guard let window else { return false }
            let cursor = convert(window.convertPoint(fromScreen: cursorInScreen()), from: nil)
            return bounds.contains(cursor)
        }
    }
}

/// 横向平移的判定与位移累积（纯逻辑 + 闭包出口，单测直接调用）。
@MainActor
final class GanttScrollController {
    private static let logger = Logger(subsystem: "ai.kairo.app", category: "gantt-pan")
    /// 首次成功平移只记一条（现场核对「事件到底有没有到」）。
    private static var reportedFirstPan = false
    private var accumulator = HorizontalPanAccumulator()
    private var dayWidth: Double
    private var onDays: (Int) -> Void

    init(dayWidth: Double, onDays: @escaping (Int) -> Void) {
        self.dayWidth = max(dayWidth, 0.5)
        self.onDays = onDays
    }

    /// 尺度变化后旧余量失去意义，清空避免跳变。
    func update(dayWidth: Double, onDays: @escaping (Int) -> Void) {
        let width = max(dayWidth, 0.5)
        if width != self.dayWidth { accumulator.reset() }
        self.dayWidth = width
        self.onDays = onDays
    }

    /// 消费一条滚动输入；返回是否消费（true = 事件应被吞掉）。
    func handle(deltaX: Double, deltaY: Double, shift: Bool, cursorInside: Bool) -> Bool {
        let decision = GanttScrollRouter.decide(GanttScrollInput(
            deltaX: deltaX,
            deltaY: deltaY,
            shift: shift,
            hasViewport: true,
            hasCursor: true,
            cursorInsideViewport: cursorInside,
            isEditingText: false
        ))
        guard case .pan(let pixels) = decision else { return false }
        let days = accumulator.consume(deltaX: pixels, dayWidth: dayWidth)
        if days != 0 {
            if !Self.reportedFirstPan {
                Self.reportedFirstPan = true
                Self.logger.notice("first pan: \(pixels, privacy: .public)pt / \(self.dayWidth, privacy: .public)pt-per-day = \(days, privacy: .public) days")
            }
            onDays(days)
        }
        return true
    }
}

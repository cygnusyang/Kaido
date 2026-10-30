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
    /// 提交位移天数（亚日精度）：正 = 内容右移（看更早日期）。
    let onDays: (Double) -> Void

    func makeNSView(context: Context) -> ScrollSurfaceView {
        let view = ScrollSurfaceView()
        view.update(dayWidth: dayWidth, onDays: onDays)
        return view
    }

    func updateNSView(_ view: ScrollSurfaceView, context: Context) {
        view.update(dayWidth: dayWidth, onDays: onDays)
        // 每次渲染都把「视图在窗口 / 监听在岗」对齐一次（D-034 自愈）。
        view.syncMonitoringState()
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

        func update(dayWidth: Double, onDays: @escaping (Double) -> Void) {
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

        /// 视图在窗口里、但监听不在时补装（D-034）。
        ///
        /// 为什么需要这道自愈：SwiftUI 在结构变化（切视图、换项目、覆盖层进出）时
        /// 并不保证按配对顺序调用 `viewWillMove(nil)` → `viewDidMoveToWindow`。
        /// 曾经出现「启动时 attached → 原地 detached 两次 → 再无 attached」的现场，
        /// 结果是画布左右平移整段失效而界面毫无异常。这里在每次 SwiftUI 更新时
        /// 把「视图在窗口」与「监听在岗」拉回一致，漏掉的生命周期事件不再致命。
        func syncMonitoringState() {
            if window == nil, monitor != nil {
                stopMonitoring()
            } else if window != nil, monitor == nil {
                startMonitoring()
            }
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

        /// 一条滚动事件：横向分量用于平移，纵向分量原样放行给纵向滚动。
        ///
        /// 「横纵叠加」是刻意的（v1.3.6 用户要求）：双指斜向滑动时，甘特跟着横向走、
        /// 大纲跟着纵向走，而不是按「谁更大」二选一。只有当这一帧几乎没有纵向分量
        /// （< 1pt）时才吞掉事件，避免重复滚动。
        func handle(_ event: NSEvent) -> NSEvent? {
            guard let controller else { return event }
            // 传统滚轮（鼠标）的 delta 单位是「行」而非像素：不换算的话一次滚格只走
            // 1pt，跨度模式要 171 格才动一天，实测就是「滚不动」。触摸板是精确像素，1:1。
            let scale = event.hasPreciseScrollingDeltas ? 1 : GanttScrollController.lineScrollPoints
            let deltaX = Double(event.scrollingDeltaX) * scale
            let deltaY = Double(event.scrollingDeltaY) * scale
            let consumed = controller.handle(
                deltaX: deltaX,
                deltaY: deltaY,
                shift: event.modifierFlags.contains(.shift),
                cursorInside: cursorInsideBounds()
            )
            let hasVertical = abs(event.scrollingDeltaY) >= 1
            return (consumed && !hasVertical) ? nil : event
        }

        /// 光标是否落在本视图当前所占的窗口区域内（现场换算，不缓存）。
        func cursorInsideBounds() -> Bool {
            guard let window else { return false }
            let cursor = convert(window.convertPoint(fromScreen: cursorInScreen()), from: nil)
            return bounds.contains(cursor)
        }
    }
}

/// 横向平移的判定与位移换算（纯逻辑 + 闭包出口，单测直接调用）。
@MainActor
final class GanttScrollController {
    private static let logger = Logger(subsystem: "ai.kairo.app", category: "gantt-pan")
    /// 传统滚轮一「行」折算的点数（AppKit 的非精确 delta 以行为单位）。
    static let lineScrollPoints: Double = 10
    private var dayWidth: Double
    private var onDays: (Double) -> Void

    init(dayWidth: Double, onDays: @escaping (Double) -> Void) {
        self.dayWidth = max(dayWidth, HorizontalPan.minimumDayWidth)
        self.onDays = onDays
    }

    /// 日宽变化（缩放 / 画布改宽）：只换换算基准，无余量可清（连续位移不需要累积）。
    func update(dayWidth: Double, onDays: @escaping (Double) -> Void) {
        self.dayWidth = max(dayWidth, HorizontalPan.minimumDayWidth)
        self.onDays = onDays
    }

    /// 消费一条滚动输入；返回值表示「横向分量是否已被本层用掉」。
    ///
    /// 注意：纵向分量一律放行（见 ScrollSurfaceView.handle），所以这里返回 true
    /// 不代表事件被吞——视图层按纵向分量大小决定是否把事件继续交给纵向滚动。
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
        guard case .pan(let pixels) = decision else {
            // 放行原因每种只记首次（F-14-18 承诺的诊断口径）：outsideViewport 此前完全
            // 静默，承接层被 .offset 留在布局原位、整条移出视口时横向滚动毫无线索，
            // 排查耗了五轮（D-050）。只在首次记，高频滚动不刷屏。
            if case .ignore(let reason) = decision {
                logFirstIgnore(reason)
            }
            return false
        }
        let days = HorizontalPan.days(deltaX: pixels, dayWidth: dayWidth)
        guard days != 0 else { return true }
        Self.logFirstPan(pixels: pixels, dayWidth: dayWidth, days: days)
        onDays(days)
        return true
    }

    /// 已记录过的放行原因（按 rawValue 存，不要求呈现层类型额外遵循 Hashable）。
    private var loggedIgnoreReasons: Set<String> = []

    /// 每种放行原因仅首次记一条：现场一眼看出是哪道闸挡住了。
    private func logFirstIgnore(_ reason: GanttScrollIgnoreReason) {
        guard loggedIgnoreReasons.insert(reason.rawValue).inserted else { return }
        Self.logger.notice("scroll ignored (\(reason.rawValue, privacy: .public))")
    }

    /// 首次成功平移只记一条（现场核对「事件到底有没有到」）。
    private static var reportedFirstPan = false
    private static func logFirstPan(pixels: Double, dayWidth: Double, days: Double) {
        guard !reportedFirstPan else { return }
        reportedFirstPan = true
        logger.notice("first pan: \(pixels, privacy: .public)pt / \(dayWidth, privacy: .public)pt-per-day = \(days, privacy: .public) days")
    }
}

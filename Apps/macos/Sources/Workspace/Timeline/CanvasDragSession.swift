import Foundation
import KairoPresentation

/// 甘特画布拖拽提交节流状态机（F-14-09；模板 = `DayWidthThrottle`）。
///
/// 引用语义独立于 View 存在：GUIRenderTests 只能 dispatch 动作、无法模拟手势事件，
/// 拖拽生命线（按下 → 拖动节流提交 → 松手收尾/取消）必须可由单测直接驱动同一实例。
/// 预览与提交全部基于 `begin` 时捕获的 `Anchor`（拖拽起点快照锚定，设计稿 R4：
/// 拖拽中排程重算导致快照刷新不干扰预览与末值提交）。
@MainActor
final class CanvasDragSession {
    /// 提交节流间隔（秒）：拖动中最多每 100ms 提交一次。
    static let commitInterval: TimeInterval = 0.1

    /// 拖拽起点锚定的几何：条 + 当前持续时间 + 窗口起点 + 日界 + 生效日宽。
    ///
    /// `dayOrigin` 是窗口起点所在自然日的零点。窗口起点允许亚日精度（连续滚动，
    /// v1.3.7 / D-049），日的边界仍按真实午夜算，所以日偏移与落库日期都以它为准；
    /// 相位只影响「画在哪一像素」，不影响「算哪一天」。
    struct Anchor {
        let bar: GanttBar
        let durationDays: Double
        let windowStart: Date
        let dayOrigin: Date
        let dayWidth: Double

        /// 窗口相位移（天，0..<1）。
        var dayPhase: Double { windowStart.timeIntervalSince(dayOrigin) / 86_400 }

        /// `dayOrigin` 缺省回落到窗口起点（整天对齐的旧调用点相位移为 0）。
        init(bar: GanttBar, durationDays: Double, windowStart: Date, dayOrigin: Date? = nil, dayWidth: Double) {
            self.bar = bar
            self.durationDays = durationDays
            self.windowStart = windowStart
            self.dayOrigin = dayOrigin ?? windowStart
            self.dayWidth = dayWidth
        }
    }

    /// 单笔提交请求；视图层映射为 WorkspaceAction。
    enum Commit: Equatable {
        /// 拖条改期：只改 startDate（duration 不变）。
        case move(id: UUID, startDate: Date)
        /// 拖端点：右端 startDate 为 nil（只改 duration）；左端两者都带（end 不变）。
        case resize(id: UUID, startDate: Date?, durationDays: Double)
        /// 建依赖：方向语义由拖出端决定（`isFromEnd`）。
        case link(taskID: UUID, predecessorID: UUID)
    }

    /// 视图预览：调整后的条起点（相对 windowStart 的日偏移）与持续天数。
    /// 三种模式统一表达——move 平移、resize 单边伸缩，视图据此画虚线框。
    struct BarPreview: Equatable {
        let bar: GanttBar
        let startDay: Int
        let durationDays: Double
    }

    /// 依赖连线预览：从锚定条端点到当前鼠标（内容坐标）。
    struct LinkPreview: Equatable {
        let sourceBar: GanttBar
        let isFromEnd: Bool
        let pointX: Double
        let pointY: Double
        /// 悬停中的目标条（高亮提示），松手即提交对象。
        let targetID: UUID?
    }

    enum Preview: Equatable {
        case bar(BarPreview)
        case link(LinkPreview)
    }

    private enum Mode {
        case idle
        case move(UUID)
        case resize(UUID, isStartEdge: Bool)
        case link(isFromEnd: Bool)
    }

    /// 拖拽中预览（nil = 空闲）。
    private(set) var preview: Preview?

    private let commit: @MainActor (Commit) -> Void
    private var anchor: Anchor?
    private var mode: Mode = .idle
    /// 已提交的末值（同值跳过，避免重复 dispatch 造成无谓刷新）。
    private var lastCommit: Commit?
    /// 节流基准：距上次提交不足 `commitInterval` 的中间值跳过。
    private var lastCommitAt = Date.distantPast

    init(commit: @escaping @MainActor (Commit) -> Void) {
        self.commit = commit
    }

    // MARK: - 生命线

    /// 按下：按命中结果进入对应拖拽模式；`dependencyLine` / `none` 不进入任何模式。
    func begin(target: GanttDragTarget, anchor: Anchor) {
        endPending()
        switch target {
        case .body, .startHandle, .endHandle, .dependencyStart, .dependencyEnd:
            self.anchor = anchor
        case .dependencyLine, .none:
            return
        }
        lastCommit = nil
        // 新拖拽首笔必提交（不受上一次拖拽的节流窗口影响）。
        lastCommitAt = .distantPast
        let rowCenter = Double(anchor.bar.rowIndex) * 28 + 14
        switch target {
        case .body(let id):
            mode = .move(id)
            preview = .bar(Self.movePreview(anchor: anchor, offsetDays: 0))
        case .startHandle(let id):
            mode = .resize(id, isStartEdge: true)
            preview = .bar(Self.resizePreview(anchor: anchor, isStartEdge: true, offsetDays: 0))
        case .endHandle(let id):
            mode = .resize(id, isStartEdge: false)
            preview = .bar(Self.resizePreview(anchor: anchor, isStartEdge: false, offsetDays: 0))
        case .dependencyStart(_):
            mode = .link(isFromEnd: false)
            preview = .link(LinkPreview(
                sourceBar: anchor.bar, isFromEnd: false,
                pointX: anchor.bar.x, pointY: rowCenter, targetID: nil
            ))
        case .dependencyEnd(_):
            mode = .link(isFromEnd: true)
            preview = .link(LinkPreview(
                sourceBar: anchor.bar, isFromEnd: true,
                pointX: anchor.bar.x + max(anchor.bar.width, 1), pointY: rowCenter, targetID: nil
            ))
        case .dependencyLine, .none:
            break
        }
    }

    /// 拖动：更新预览并按节流提交（连线模式只更新预览与目标，松手才提交）。
    /// - Parameters:
    ///   - translationX: 手势总位移（视口横坐标即内容横坐标，画布无横向滚动）。
    ///   - pointX/pointY: 当前鼠标视口坐标（连线模式用）。
    ///   - canvasOffset: 画布滚动偏移（换算内容纵坐标）。
    ///   - targetID: 命中中的目标条 ID（连线模式高亮/提交用，视图经 hitTest 提供）。
    func update(
        translationX: Double,
        pointX: Double,
        pointY: Double,
        canvasOffset: Double,
        targetID: UUID?
    ) {
        guard let anchor else { return }
        switch mode {
        case .link(let isFromEnd):
            preview = .link(LinkPreview(
                sourceBar: anchor.bar, isFromEnd: isFromEnd,
                pointX: pointX, pointY: pointY + canvasOffset, targetID: targetID
            ))
        case .move(let id):
            let offset = GanttHitTesting.days(fromTranslationX: translationX, dayWidth: anchor.dayWidth)
            preview = .bar(Self.movePreview(anchor: anchor, offsetDays: offset))
            throttledCommit(.move(id: id, startDate: Self.moveStartDate(anchor: anchor, offsetDays: offset)))
        case .resize(let id, let isStartEdge):
            let offset = GanttHitTesting.days(fromTranslationX: translationX, dayWidth: anchor.dayWidth)
            preview = .bar(Self.resizePreview(anchor: anchor, isStartEdge: isStartEdge, offsetDays: offset))
            throttledCommit(Self.resizeCommit(id: id, anchor: anchor, isStartEdge: isStartEdge, offsetDays: offset))
        case .idle:
            break
        }
    }

    /// 松手：提交最终值（连线模式在此提交依赖）并回到空闲。
    func finish() {
        guard let anchor else { return }
        switch mode {
        case .link(let isFromEnd):
            if let target = linkTargetID, target != anchor.bar.taskID {
                let value: Commit = isFromEnd
                    ? .link(taskID: target, predecessorID: anchor.bar.taskID)
                    : .link(taskID: anchor.bar.taskID, predecessorID: target)
                commitNow(value)
            }
        case .move(let id):
            if case .bar(let barPreview) = preview {
                let offset = barPreview.startDay - Self.startDay(anchor: anchor)
                let value = Commit.move(id: id, startDate: Self.moveStartDate(anchor: anchor, offsetDays: offset))
                // 松手收尾绕过节流立即提交；已提交过的同值不重复 dispatch。
                if value != lastCommit { commitNow(value) }
            }
        case .resize(let id, let isStartEdge):
            if case .bar(let barPreview) = preview {
                let offset = isStartEdge
                    ? Double(barPreview.startDay - Self.startDay(anchor: anchor))
                    : barPreview.durationDays - anchor.durationDays
                let value = Self.resizeCommit(
                    id: id, anchor: anchor, isStartEdge: isStartEdge, offsetDays: Int(offset.rounded())
                )
                if value != lastCommit { commitNow(value) }
            }
        case .idle:
            break
        }
        endPending()
    }

    /// 取消（Escape）：丢弃预览与待提交，不产生任何提交。
    func cancel() {
        endPending()
    }

    // MARK: - 纯函数（提交值计算）

    /// 锚定条的起点日偏移（相对**日界**：0 = 窗口起点所在那一天）。
    ///
    /// 条在画布上的横坐标是 `(天数 − 相位) × 日宽`，所以要先把相位加回来再取整，
    /// 否则窗口滑到半天时所有日期标签都会差一天。
    static func startDay(anchor: Anchor) -> Int {
        Int((anchor.bar.x / max(anchor.dayWidth, 0.5) + anchor.dayPhase).rounded())
    }

    static func movePreview(anchor: Anchor, offsetDays: Int) -> BarPreview {
        BarPreview(
            bar: anchor.bar,
            startDay: startDay(anchor: anchor) + offsetDays,
            durationDays: anchor.durationDays
        )
    }

    static func resizePreview(anchor: Anchor, isStartEdge: Bool, offsetDays: Int) -> BarPreview {
        let clamped = clampStartOffset(anchor: anchor, offsetDays: offsetDays)
        return BarPreview(
            bar: anchor.bar,
            startDay: isStartEdge ? startDay(anchor: anchor) + Int(clamped) : startDay(anchor: anchor),
            durationDays: isStartEdge
                ? max(1, anchor.durationDays - clamped)
                : max(1, anchor.durationDays + Double(offsetDays))
        )
    }

    static func moveStartDate(anchor: Anchor, offsetDays: Int) -> Date {
        anchor.dayOrigin.addingTimeInterval(Double(startDay(anchor: anchor) + offsetDays) * 86_400)
    }

    /// 左端拖拽的位移夹取：end 不变 ⇒ 新 duration ≥ 1 天。
    static func clampStartOffset(anchor: Anchor, offsetDays: Int) -> Double {
        min(Double(offsetDays), max(0, anchor.durationDays - 1))
    }

    static func resizeCommit(
        id: UUID, anchor: Anchor, isStartEdge: Bool, offsetDays: Int
    ) -> Commit {
        if isStartEdge {
            let offset = clampStartOffset(anchor: anchor, offsetDays: offsetDays)
            return .resize(
                id: id,
                startDate: anchor.dayOrigin.addingTimeInterval(
                    Double(startDay(anchor: anchor) + Int(offset)) * 86_400
                ),
                durationDays: max(1, anchor.durationDays - offset)
            )
        }
        return .resize(id: id, startDate: nil, durationDays: max(1, anchor.durationDays + Double(offsetDays)))
    }

    // MARK: - 节流

    /// 节流提交：距上次提交不足 `commitInterval` 的中间值直接跳过，
    /// 末值由 `finish()` 必提交兜底。
    ///
    /// 与 `DayWidthThrottle` 的差异：**不使用延迟任务**。延迟任务依赖真实时钟调度，
    /// 在 CI 并行测试负载下可能长时间不被调度（D-020），且让拖拽提交时序不可测。
    /// 去掉定时器后：连续拖动仍在 100ms 粒子上提交，停手不动的末值由松手保证落地。
    private func throttledCommit(_ value: Commit) {
        guard value != lastCommit else { return }
        guard Date().timeIntervalSince(lastCommitAt) >= Self.commitInterval else { return }
        commitNow(value)
    }

    private func commitNow(_ value: Commit) {
        lastCommitAt = Date()
        lastCommit = value
        commit(value)
    }

    private func endPending() {
        anchor = nil
        mode = .idle
        preview = nil
    }

    private var linkTargetID: UUID? {
        if case .link(let link) = preview { return link.targetID }
        return nil
    }
}

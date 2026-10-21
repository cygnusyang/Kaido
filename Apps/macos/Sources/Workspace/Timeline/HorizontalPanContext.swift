import Foundation
import KairoPresentation

/// 横向滚动捕获所需的「最新画布上下文」（F-14-18，引用语义）。
///
/// 滚动监听是长生命周期的 AppKit 回调，闭包不能直接捕获 `TimelineBody` 的值型
/// `gantt`（会锁住创建时刻的旧窗口起点），故把日宽 / 窗口起点 / 视口矩形 / 亚日余量
/// 统一放进引用对象，由视图在快照变化时同步，监听侧只读最新值。
@MainActor
final class HorizontalPanContext {
    /// 画布视口矩形（窗口内容坐标，左上原点）。
    var viewportRect: CGRect = .zero
    private(set) var dayWidth: Double = 1
    private(set) var windowStart = Date()
    private var accumulator = HorizontalPanAccumulator()

    /// 快照变化时同步几何（视图在 `onAppear` / `onChange(of: gantt)` 调用）。
    func sync(dayWidth: Double, windowStart: Date) {
        self.dayWidth = max(dayWidth, 0.5)
        self.windowStart = windowStart
    }

    /// 消费一段横向像素位移，返回可提交的整天数（余量留存，跨整天才释放）。
    func consumeScroll(deltaX: Double) -> Int {
        accumulator.consume(deltaX: deltaX, dayWidth: dayWidth)
    }

    /// 缩放档位 / 窗口被外部重置时清空余量，避免旧余量在新尺度下突变。
    func resetAccumulator() {
        accumulator.reset()
    }
}

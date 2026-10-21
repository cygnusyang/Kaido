import Foundation

/// 画布横向平移的亚日余量累积器（F-14-18）。
///
/// 布局把窗口起点归一为整天（`GanttLayoutEngine.make` 的 `startOfDay`），
/// 因此触摸板/滚轮的连续像素位移必须先累积、跨整天才提交，否则逐事件取整
/// 会让慢速滑动「一天天蹦」且丢失不足一天的位移。
///
/// 语义：`consume` 返回正数 = 内容右移（窗口起点减小）；负数反之。
public struct HorizontalPanAccumulator: Equatable, Sendable {
    /// 尚未凑满一整天的位移余量（天）。
    public private(set) var remainderDays: Double = 0

    public init() {}

    /// 消费一段横向像素位移，返回本段可提交的整天数（余量留存到下次）。
    public mutating func consume(deltaX: Double, dayWidth: Double) -> Int {
        remainderDays += deltaX / max(dayWidth, 0.5)
        let whole = remainderDays.rounded(.towardZero)
        remainderDays -= whole
        return Int(whole)
    }

    /// 清空余量（窗口被外部重置、切换缩放档位等场景）。
    public mutating func reset() {
        remainderDays = 0
    }
}

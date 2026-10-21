import Foundation
import KairoCore
import KairoPresentation

/// 画布空白处拖拽平移状态机（F-14-18，引用语义、可单测）。
///
/// 与 `CanvasDragSession` 同款纪律：手势逻辑不内联在视图里（D-020 教训），
/// 锚定按下时的 `windowStart`，按绝对位移取整换算，同天数抑制重复提交。
@MainActor
final class PanDragSession {
    private var baseStart: Date?
    private var dayWidth: Double = 1
    private var lastDays: Int?

    /// 是否处于拖拽平移中。
    var isActive: Bool { baseStart != nil }

    /// 按下：锚定当前窗口起点与生效日宽。
    func begin(windowStart: Date, dayWidth: Double) {
        baseStart = windowStart
        self.dayWidth = max(dayWidth, 0.5)
        lastDays = nil
    }

    /// 拖动位移 → 目标窗口起点；天数未变返回 nil（避免无谓 dispatch）。
    /// 内容跟手：向右拖（正位移）看更早日期 ⇒ 窗口起点减小。
    func update(translationX: Double) -> Date? {
        guard let baseStart else { return nil }
        let days = Int((translationX / dayWidth).rounded())
        guard days != lastDays else { return nil }
        lastDays = days
        return baseStart.addingTimeInterval(-Double(days) * 86_400)
    }

    /// 松手收尾。
    func end() {
        baseStart = nil
        lastDays = nil
    }

    /// Escape 取消：停止本段拖拽；已提交的平移不回滚（同表头拖拽语义）。
    func cancel() {
        end()
    }
}

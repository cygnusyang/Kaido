import Foundation
import ZenoCore
import ZenoPresentation

/// 工作日历顺延留痕的视图层渲染（F-22-06 / D3）。
///
/// 快照只给日期与原因码，整句文案在这里组装——与 `ViolationText` 同一分工（ADR-013）：
/// 同一份留痕给 UI / CLI / MCP 三端用，文案不能写进呈现层。
enum CalendarAdjustmentText {
    /// 单条留痕的整句：「已从 2026-10-01 顺延到 2026-10-09（节假日）」。
    ///
    /// 日期走 `Display.isoDate`（契约格式 `yyyy-MM-dd`，不随语言变化）：
    /// 这行文字要与检查器日期字段、CLI 回执逐字对得上，用户才能拿去核对。
    static func message(_ row: CalendarAdjustmentRow) -> String {
        I18n.t(
            "inspector.calendar.shifted",
            "Moved from %1$@ to %2$@ (%3$@)",
            Display.isoDate(row.requested),
            Display.isoDate(row.adjusted),
            kind(row.kind)
        )
    }

    /// 顺延原因：用户输入那天不上班，或日历本身不可用而退化。
    static func kind(_ kind: CalendarAdjustment.Kind) -> String {
        switch kind {
        case .nonWorkingDay:
            return I18n.t("inspector.calendar.kind.non_working", "non-working day")
        case .invalidWeekdays:
            return I18n.t("inspector.calendar.kind.invalid_weekdays", "working week unavailable")
        }
    }
}

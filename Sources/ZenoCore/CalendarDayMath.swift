import Foundation

/// 日历整日算术（D-023 / D-024）：全仓「天」粒度换算的唯一实现。
///
/// 一切天数差与「加 N 天」都必须走 `Calendar`，禁止用 `86_400` 秒除法：
/// 夏令时切换日的本地一天只有 23 或 25 小时，秒除会让天数差漂移 1 天。
///
/// 纯函数层：仅依赖 Foundation（ADR-004），供核心、呈现层与命令层共用。
public enum CalendarDayMath {
    /// 归一为当天零点（`calendar.startOfDay`）。
    public static func startOfDay(_ date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 两个日期相差的整日数（先各自归一到零点；可为负）。
    ///
    /// 取「日历日序号之差」而非时间间隔：跨 DST 前后两个零点相差 23/25 小时，
    /// 用 `.day` 分量相减仍得 1 天。
    public static func dayOffset(
        from: Date,
        to: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Int {
        let start = startOfDay(from, calendar: calendar)
        let end = startOfDay(to, calendar: calendar)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// 按整日推进：`date` 当天零点 + `days` 个日历日（可为负）。
    ///
    /// 结果落在目标日的本地零点；不存在「加 86 400 秒」造成的 01:00 / 23:00 漂移。
    public static func adding(
        days: Int,
        to date: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date {
        let start = startOfDay(date, calendar: calendar)
        guard days != 0 else { return start }
        return calendar.date(byAdding: .day, value: days, to: start) ?? start
    }
}

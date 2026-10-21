import Foundation
import KairoCore

/// 检查器日期字段的日粒度换算（F-14-10）。
///
/// 全部换算走 Calendar 整日相减/相加，不用 86_400 秒除——含夏令时的时区里
/// 一天可能只有 23 或 25 小时，秒除会让天数差漂移 1 天。
///
/// 「结束」一律是排他端点：finish = start + durationDays，1 天任务 start=11-02
/// 的 finish 为 11-03，条体只覆盖 11-02 当天。
///
/// 纯函数层：仅依赖 Foundation 与模型类型，不 import 任何 UI 框架（ADR-004 / ADR-013）。
public enum ScheduleDateMath {
    /// 归一为当天零点（calendar.startOfDay）。
    public static func startOfDay(_ date: Date, calendar: Calendar = .current) -> Date {
        calendar.startOfDay(for: date)
    }

    /// 两个日期相差的整日数（先各自归一到零点；可为负）。
    public static func dayOffset(from: Date, to: Date, calendar: Calendar = .current) -> Int {
        let start = startOfDay(from, calendar: calendar)
        let end = startOfDay(to, calendar: calendar)
        return calendar.dateComponents([.day], from: start, to: end).day ?? 0
    }

    /// 排他端点 → 持续时间天数；finish <= start 返回 nil（非法，调用方拒绝写入）。
    ///
    /// 结果恒为整日数（≥ 1），因此经本行编辑后既有小数持续时间会变为整数天。
    public static func durationDays(
        start: Date,
        finish: Date,
        calendar: Calendar = .current
    ) -> Double? {
        let days = dayOffset(from: start, to: finish, calendar: calendar)
        guard days > 0 else { return nil }
        return Double(days)
    }

    /// 持续时间 → 排他端点：start + durationDays 天（按整日推进）。
    ///
    /// 非整数持续时间四舍五入到最近整日（2.5 天 → 3 天），与检查器预览行
    /// 「2.5 天 → 3 天」一致；durationDays <= 0 回落为当天零点。
    public static func finish(
        start: Date,
        durationDays: Double,
        calendar: Calendar = .current
    ) -> Date {
        let normalized = startOfDay(start, calendar: calendar)
        let days = Int(durationDays.rounded())
        guard days > 0 else { return normalized }
        return calendar.date(byAdding: .day, value: days, to: normalized) ?? normalized
    }

    /// 日历最小可选结束日：普通任务为起点次日；里程碑为起点当日（不可编辑，调用方禁用）。
    public static func minimumFinish(
        start: Date,
        kind: TaskKind,
        calendar: Calendar = .current
    ) -> Date {
        let normalized = startOfDay(start, calendar: calendar)
        guard kind != .milestone else { return normalized }
        return calendar.date(byAdding: .day, value: 1, to: normalized) ?? normalized
    }
}

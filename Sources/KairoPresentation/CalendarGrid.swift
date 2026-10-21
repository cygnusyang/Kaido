import Foundation

/// 6×7 月历网格模型（F-14-10）：视图只渲染 days，不自算日历。
///
/// 网格固定 42 格，首格是「当月 1 日所在周的周首」——周首跟随
/// calendar.firstWeekday（用户系统设置），因此同一月份在周日/周一首设置下
/// 可能相差一天。非本月的格照样输出（视图灰显但可点，点了顺带翻月）。
///
/// 纯数据层：仅依赖 Foundation，不 import SwiftUI / AppKit（ADR-004 / ADR-013）。
public struct CalendarMonthGrid: Equatable, Sendable {
    public static let rows = 6
    public static let columns = 7

    /// 当月 1 日（零点）。
    public let firstDay: Date
    /// 42 项，从网格首日（当月 1 日所在周的周首）起，逐日连续。
    public let days: [Date]
    public let calendar: Calendar

    init(firstDay: Date, days: [Date], calendar: Calendar) {
        self.firstDay = firstDay
        self.days = days
        self.calendar = calendar
    }

    /// 该日是否属于本网格的月份。
    public func isInMonth(_ day: Date) -> Bool {
        calendar.isDate(day, equalTo: firstDay, toGranularity: .month)
    }

    /// 该日是否为周末（口径由日历的周末定义决定，常见设置下为周六/周日）。
    public func isWeekend(_ day: Date) -> Bool {
        calendar.isDateInWeekend(day)
    }

    /// 两日是否同一天（忽略时分秒）——今天态 / 选中态判定用。
    public func isSameDay(_ lhs: Date, _ rhs: Date) -> Bool {
        calendar.isDate(lhs, inSameDayAs: rhs)
    }

    /// 相邻月份的网格（months 可为负），翻月保留当前周首设置。
    public func month(offsetBy months: Int) -> CalendarMonthGrid {
        guard months != 0,
              let shifted = calendar.date(byAdding: .month, value: months, to: firstDay) else {
            return self
        }
        return CalendarGrid.month(containing: shifted, calendar: calendar)
    }

    /// 指定年月日的零点；日期不存在（如 2 月 30 日）时返回 nil。
    ///
    /// 供快捷项（今天 / 下周一 / +1 周）定位使用。
    public func date(year: Int, month: Int, day: Int) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = calendar.date(from: components) else { return nil }
        // Calendar 会把越界日顺延（2 月 30 日 → 3 月 2 日），回读校验拦下这种输入。
        let resolved = calendar.dateComponents([.year, .month, .day], from: date)
        guard resolved.year == year, resolved.month == month, resolved.day == day else {
            return nil
        }
        return calendar.startOfDay(for: date)
    }
}

/// 月历网格工厂。
public enum CalendarGrid {
    /// 含该日的月份网格；周首跟随 calendar.firstWeekday。
    public static func month(containing date: Date, calendar: Calendar = .current) -> CalendarMonthGrid {
        let normalized = calendar.startOfDay(for: date)
        // 当月 1 日取 .month 区间起点，天然避开月末天数差异与闰年。
        let monthStart = calendar.dateInterval(of: .month, for: normalized)?.start ?? normalized
        let weekday = calendar.component(.weekday, from: monthStart)
        let leading = ((weekday - calendar.firstWeekday) % 7 + 7) % 7
        let gridStart = calendar.date(byAdding: .day, value: -leading, to: monthStart) ?? monthStart

        var days: [Date] = []
        days.reserveCapacity(CalendarMonthGrid.rows * CalendarMonthGrid.columns)
        for index in 0..<(CalendarMonthGrid.rows * CalendarMonthGrid.columns) {
            days.append(calendar.date(byAdding: .day, value: index, to: gridStart) ?? gridStart)
        }
        return CalendarMonthGrid(firstDay: monthStart, days: days, calendar: calendar)
    }
}

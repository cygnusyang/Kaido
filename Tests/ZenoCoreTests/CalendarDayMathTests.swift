import Foundation
import Testing

@testable import ZenoCore

// MARK: - 夹具

/// 固定时区日历：日算术与本地时区无关，断言必须钉死一个时区。
private func calendar(_ identifier: String) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: identifier)!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

/// 断言日期落在本地零点（dayOffset 的输入先归零，输出也必须落在零点）。
private func isStartOfDay(_ date: Date, calendar: Calendar) -> Bool {
    date == calendar.startOfDay(for: date)
}

// MARK: - 判据 4：整日相减

@Test func dayOffsetCountsCalendarDaysNotSeconds() {
    let cal = calendar("UTC")
    let from = day(2026, 11, 5, calendar: cal)
    let to = day(2026, 11, 8, calendar: cal)

    #expect(CalendarDayMath.dayOffset(from: from, to: to, calendar: cal) == 3)
    #expect(CalendarDayMath.dayOffset(from: to, to: from, calendar: cal) == -3)
    #expect(CalendarDayMath.dayOffset(from: from, to: from, calendar: cal) == 0)
}

@Test func dayOffsetNormalizesBothEndsToStartOfDay() {
    let cal = calendar("UTC")
    let morning = cal.date(byAdding: .hour, value: 6, to: day(2026, 11, 5, calendar: cal))!
    let evening = cal.date(byAdding: .hour, value: 22, to: day(2026, 11, 5, calendar: cal))!

    // 同一天的不同时刻：偏差恒为 0，不因小时数溢出成 1。
    #expect(CalendarDayMath.dayOffset(from: morning, to: evening, calendar: cal) == 0)
    #expect(CalendarDayMath.dayOffset(from: evening, to: morning, calendar: cal) == 0)
}

// MARK: - 判据 4：跨夏令时（08-baselines §4.1 / D-023）

@Test func dayOffsetSurvivesDaylightSavingFallBack() {
    // 美国东部 2026-11-01 回拨 02:00→01:00：当天本地 25 小时。
    // 按秒折算「11-01 → 11-02」得到 25 小时 / 24 = 1.04 → 取整 1，看似正确；
    // 但「11-01 → 11-02 23:00」这类同日跨零点判断会被 86 400 秒除误判成 2 天。
    let cal = calendar("America/New_York")
    let rollbackDay = day(2026, 11, 1, calendar: cal)
    let nextDayNoon = cal.date(byAdding: .hour, value: 12, to: day(2026, 11, 2, calendar: cal))!

    #expect(CalendarDayMath.dayOffset(from: rollbackDay, to: nextDayNoon, calendar: cal) == 1)
    #expect(CalendarDayMath.dayOffset(from: rollbackDay, to: day(2026, 11, 3, calendar: cal), calendar: cal) == 2)

    // 「加一天」必须落在下一个本地零点，而不是 25 小时后的 01:00。
    let plusOne = CalendarDayMath.adding(days: 1, to: rollbackDay, calendar: cal)
    #expect(plusOne == day(2026, 11, 2, calendar: cal))
    #expect(isStartOfDay(plusOne, calendar: cal))
}

@Test func dayOffsetSurvivesDaylightSavingSpringForward() {
    // 美国东部 2026-03-08 拨快 02:00→03:00：3-08 当天只有 23 小时。
    // 这是秒除法的真伤口：03-08 00:00 → 03-09 00:00 的秒差是 23 小时，
    // 除以 86 400 得 0 天，会把「晚一天」算成「准时」。
    let cal = calendar("America/New_York")
    let switchDay = day(2026, 3, 8, calendar: cal)
    let nextDay = day(2026, 3, 9, calendar: cal)

    #expect(CalendarDayMath.dayOffset(from: switchDay, to: nextDay, calendar: cal) == 1)
    #expect(nextDay.timeIntervalSince(switchDay) == 23 * 3600)
    #expect(CalendarDayMath.dayOffset(from: day(2026, 3, 7, calendar: cal), to: nextDay, calendar: cal) == 2)

    let plusOne = CalendarDayMath.adding(days: 1, to: switchDay, calendar: cal)
    #expect(plusOne == nextDay)
    #expect(isStartOfDay(plusOne, calendar: cal))
}

// MARK: - 整日相加

@Test func addingDaysLandsOnStartOfDayAndCommutes() {
    let cal = calendar("Europe/Berlin")
    let origin = day(2026, 3, 28, calendar: cal)

    let plusThree = CalendarDayMath.adding(days: 3, to: origin, calendar: cal)
    let minusThree = CalendarDayMath.adding(days: -3, to: plusThree, calendar: cal)

    #expect(plusThree == day(2026, 3, 31, calendar: cal))
    #expect(minusThree == origin)
    #expect(isStartOfDay(plusThree, calendar: cal))
}

@Test func addingZeroDaysNormalizesTime() {
    let cal = calendar("Asia/Shanghai")
    let noon = cal.date(byAdding: .hour, value: 13, to: day(2026, 6, 1, calendar: cal))!

    #expect(CalendarDayMath.adding(days: 0, to: noon, calendar: cal) == day(2026, 6, 1, calendar: cal))
}

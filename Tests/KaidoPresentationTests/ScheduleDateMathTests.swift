import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// F-14-10 纯日期换算：日粒度归一、整日相减（不用 86_400 秒除，避免夏令时差 1 天）、
// finish（排他端点）与 duration 的双向换算、日历最小可选结束日。

@Suite("F-14-10 日程日期换算")
struct ScheduleDateMathTests {
    /// 固定时区与格里高利历，避免用例随开发机设置漂移。
    private func makeCalendar(_ identifier: String = "Asia/Shanghai") -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: identifier) ?? TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }

    private func makeDate(
        _ year: Int, _ month: Int, _ day: Int,
        hour: Int = 0, minute: Int = 0,
        calendar: Calendar
    ) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        components.minute = minute
        guard let date = calendar.date(from: components) else {
            fatalError("测试日期构造失败：\(year)-\(month)-\(day) \(hour):\(minute)")
        }
        return date
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        makeDate(year, month, day, hour: 0, minute: 0, calendar: calendar)
    }

    // MARK: - startOfDay

    @Test func startOfDayStripsTimeOfDay() {
        let calendar = makeCalendar()
        let noon = makeDate(2025, 11, 2, hour: 13, minute: 45, calendar: calendar)

        let start = ScheduleDateMath.startOfDay(noon, calendar: calendar)

        #expect(start == makeDate(2025, 11, 2, calendar: calendar))
        #expect(calendar.component(.hour, from: start) == 0)
    }

    @Test func startOfDayKeepsAlreadyNormalizedDate() {
        let calendar = makeCalendar()
        let midnight = makeDate(2025, 11, 2, calendar: calendar)

        #expect(ScheduleDateMath.startOfDay(midnight, calendar: calendar) == midnight)
    }

    // MARK: - dayOffset

    @Test func dayOffsetCountsWholeDaysAcrossMonthBoundary() {
        let calendar = makeCalendar()
        let from = makeDate(2025, 10, 30, hour: 22, minute: 10, calendar: calendar)
        let to = makeDate(2025, 11, 2, hour: 3, minute: 5, calendar: calendar)

        #expect(ScheduleDateMath.dayOffset(from: from, to: to, calendar: calendar) == 3)
    }

    @Test func dayOffsetIsNegativeWhenTargetIsEarlier() {
        let calendar = makeCalendar()
        let from = makeDate(2025, 11, 2, calendar: calendar)
        let to = makeDate(2025, 10, 30, calendar: calendar)

        #expect(ScheduleDateMath.dayOffset(from: from, to: to, calendar: calendar) == -3)
    }

    @Test func dayOffsetIsZeroForSameDayDifferentTimes() {
        let calendar = makeCalendar()
        let morning = makeDate(2025, 11, 2, hour: 1, minute: 0, calendar: calendar)
        let night = makeDate(2025, 11, 2, hour: 23, minute: 59, calendar: calendar)

        #expect(ScheduleDateMath.dayOffset(from: morning, to: night, calendar: calendar) == 0)
    }

    /// 2025-03-09 美东进入夏令时：区间跨度不是 86400 的整数倍，仍须得到整日数。
    @Test func dayOffsetStaysWholeAcrossDaylightSavingChange() {
        let calendar = makeCalendar("America/New_York")
        let winter = makeDate(2025, 1, 15, hour: 12, calendar: calendar)
        let summer = makeDate(2025, 5, 15, hour: 12, calendar: calendar)

        #expect(ScheduleDateMath.dayOffset(from: winter, to: summer, calendar: calendar) == 120)
        #expect(ScheduleDateMath.dayOffset(from: summer, to: winter, calendar: calendar) == -120)
    }

    // MARK: - durationDays（finish 为排他端点）

    @Test func durationDaysOfSingleDayTaskIsOne() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 11, 2, calendar: calendar),
            finish: makeDate(2025, 11, 3, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == 1)
    }

    @Test func durationDaysOfMultiDayTaskCountsCalendarDays() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 11, 2, calendar: calendar),
            finish: makeDate(2025, 11, 8, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == 6)
    }

    @Test func durationDaysNormalizesTimeOfDayBeforeSubtracting() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 11, 2, hour: 23, minute: 30, calendar: calendar),
            finish: makeDate(2025, 11, 4, hour: 0, minute: 10, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == 2)
    }

    @Test func durationDaysRejectsFinishEqualToStart() {
        let calendar = makeCalendar()
        let day = makeDate(2025, 11, 2, calendar: calendar)

        #expect(ScheduleDateMath.durationDays(start: day, finish: day, calendar: calendar) == nil)
    }

    @Test func durationDaysRejectsFinishEarlierThanStart() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 11, 5, calendar: calendar),
            finish: makeDate(2025, 11, 2, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == nil)
    }

    @Test func durationDaysRejectsSameDayWithEarlierTime() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 11, 2, hour: 18, calendar: calendar),
            finish: makeDate(2025, 11, 2, hour: 9, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == nil)
    }

    @Test func durationDaysSpansYearBoundary() {
        let calendar = makeCalendar()

        let duration = ScheduleDateMath.durationDays(
            start: makeDate(2025, 12, 30, calendar: calendar),
            finish: makeDate(2026, 1, 2, calendar: calendar),
            calendar: calendar
        )

        #expect(duration == 3)
    }

    // MARK: - finish（duration → 排他端点）

    @Test func finishAddsWholeDaysToStartOfDay() {
        let calendar = makeCalendar()

        let finish = ScheduleDateMath.finish(
            start: makeDate(2025, 11, 2, hour: 15, calendar: calendar),
            durationDays: 4,
            calendar: calendar
        )

        #expect(finish == makeDate(2025, 11, 6, calendar: calendar))
    }

    /// 小数持续时间按「半天向上取整」落到整日：2.5 天 → 3 天（设计稿 §1.4）。
    @Test func finishRoundsFractionalDurationToWholeDays() {
        let calendar = makeCalendar()
        let start = makeDate(2025, 11, 2, calendar: calendar)

        #expect(ScheduleDateMath.finish(start: start, durationDays: 2.5, calendar: calendar)
            == makeDate(2025, 11, 5, calendar: calendar))
        #expect(ScheduleDateMath.finish(start: start, durationDays: 1.4, calendar: calendar)
            == makeDate(2025, 11, 3, calendar: calendar))
    }

    @Test func finishOfZeroDurationIsStartOfDay() {
        let calendar = makeCalendar()

        let finish = ScheduleDateMath.finish(
            start: makeDate(2025, 11, 2, hour: 12, calendar: calendar),
            durationDays: 0,
            calendar: calendar
        )

        #expect(finish == makeDate(2025, 11, 2, calendar: calendar))
    }

    @Test func finishOfNegativeDurationFallsBackToStartOfDay() {
        let calendar = makeCalendar()

        let finish = ScheduleDateMath.finish(
            start: makeDate(2025, 11, 2, hour: 12, calendar: calendar),
            durationDays: -3,
            calendar: calendar
        )

        #expect(finish == makeDate(2025, 11, 2, calendar: calendar))
    }

    @Test func finishCrossesDaylightSavingChangeAtMidnight() {
        let calendar = makeCalendar("America/New_York")

        let finish = ScheduleDateMath.finish(
            start: makeDate(2025, 3, 8, calendar: calendar),
            durationDays: 3,
            calendar: calendar
        )

        #expect(finish == makeDate(2025, 3, 11, calendar: calendar))
        #expect(calendar.component(.hour, from: finish) == 0)
    }

    // MARK: - 往返一致

    @Test func durationAndFinishRoundTrip() {
        let calendar = makeCalendar()
        let start = makeDate(2025, 10, 28, hour: 8, calendar: calendar)

        for days in [1.0, 3, 14, 31] {
            let finish = ScheduleDateMath.finish(start: start, durationDays: days, calendar: calendar)
            #expect(ScheduleDateMath.durationDays(start: start, finish: finish, calendar: calendar) == days)
        }
    }

    // MARK: - minimumFinish

    @Test func minimumFinishOfTaskIsTheNextDay() {
        let calendar = makeCalendar()

        let minimum = ScheduleDateMath.minimumFinish(
            start: makeDate(2025, 11, 2, hour: 16, calendar: calendar),
            kind: .task,
            calendar: calendar
        )

        #expect(minimum == makeDate(2025, 11, 3, calendar: calendar))
    }

    @Test func minimumFinishOfMilestoneIsItsOwnStartDay() {
        let calendar = makeCalendar()

        let minimum = ScheduleDateMath.minimumFinish(
            start: makeDate(2025, 11, 2, hour: 16, calendar: calendar),
            kind: .milestone,
            calendar: calendar
        )

        #expect(minimum == makeDate(2025, 11, 2, calendar: calendar))
    }

    @Test func minimumFinishOfTaskIsAlwaysSelectableByDurationMath() {
        let calendar = makeCalendar()
        let start = makeDate(2025, 12, 31, calendar: calendar)

        let minimum = ScheduleDateMath.minimumFinish(start: start, kind: .task, calendar: calendar)

        #expect(ScheduleDateMath.durationDays(start: start, finish: minimum, calendar: calendar) == 1)
    }
}

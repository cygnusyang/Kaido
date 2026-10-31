import Foundation
import Testing
import ZenoPresentation

// F-14-10 月历网格模型：6×7 固定 42 格，周首跟随 calendar.firstWeekday；
// 覆盖 2 月 / 31 天月 / 跨年翻月 / 闰年 / isInMonth / isWeekend。

@Suite("F-14-10 月历网格")
struct CalendarGridTests {
    /// 周日为周首（美式设置）。
    private func sundayFirstCalendar() -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Shanghai") ?? TimeZone(secondsFromGMT: 0)!
        calendar.locale = Locale(identifier: "en_US")
        calendar.firstWeekday = 1
        return calendar
    }

    /// 周一为周首（ISO 设置）。
    private func mondayFirstCalendar() -> Calendar {
        var calendar = sundayFirstCalendar()
        calendar.firstWeekday = 2
        return calendar
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int, hour: Int = 0, calendar: Calendar) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        guard let date = calendar.date(from: components) else {
            fatalError("测试日期构造失败：\(year)-\(month)-\(day)")
        }
        return date
    }

    // MARK: - 结构

    @Test func gridHasSixRowsAndSevenColumns() {
        #expect(CalendarMonthGrid.rows == 6)
        #expect(CalendarMonthGrid.columns == 7)
    }

    @Test func gridAlwaysHasFortyTwoConsecutiveUniqueDays() {
        let calendar = mondayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 2, 14, calendar: calendar), calendar: calendar)

        #expect(grid.days.count == CalendarMonthGrid.rows * CalendarMonthGrid.columns)
        #expect(Set(grid.days).count == grid.days.count, "42 格不得重复")

        for (earlier, later) in zip(grid.days, grid.days.dropFirst()) {
            #expect(ScheduleDateMath.dayOffset(from: earlier, to: later, calendar: calendar) == 1)
            #expect(calendar.component(.hour, from: earlier) == 0, "每格都是当日零点")
        }
    }

    @Test func gridFirstDayIsFirstOfMonthAtMidnight() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 17, hour: 15, calendar: calendar), calendar: calendar)

        #expect(grid.firstDay == makeDate(2025, 11, 1, calendar: calendar))
        #expect(calendar.component(.hour, from: grid.firstDay) == 0)
    }

    @Test func gridFirstCellIsTheWeekStartContainingTheFirstOfMonth() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 17, calendar: calendar), calendar: calendar)

        // 2025-11-01 是周六 → 周日为周首时网格从 2025-10-26 起。
        #expect(grid.days.first == makeDate(2025, 10, 26, calendar: calendar))
        #expect(calendar.component(.weekday, from: grid.days[0]) == calendar.firstWeekday)
    }

    // MARK: - firstWeekday 两种设置

    @Test func sundayFirstGridStartsOnSunday() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 1, 1, calendar: calendar), calendar: calendar)

        #expect(grid.days.first == makeDate(2024, 12, 29, calendar: calendar))
        #expect(calendar.component(.weekday, from: grid.days[0]) == 1)
    }

    @Test func mondayFirstGridStartsOnMonday() {
        let calendar = mondayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 1, 1, calendar: calendar), calendar: calendar)

        #expect(grid.days.first == makeDate(2024, 12, 30, calendar: calendar))
        #expect(calendar.component(.weekday, from: grid.days[0]) == 2)
    }

    @Test func firstWeekdaySettingShiftsGridButKeepsTheSameMonth() {
        let sundayGrid = CalendarGrid.month(containing: makeDate(2025, 2, 10, calendar: sundayFirstCalendar()), calendar: sundayFirstCalendar())
        let mondayGrid = CalendarGrid.month(containing: makeDate(2025, 2, 10, calendar: mondayFirstCalendar()), calendar: mondayFirstCalendar())
        let sundayCalendar = sundayFirstCalendar()
        let mondayCalendar = mondayFirstCalendar()

        // 2025-02-01 是周六：两种周首只差一天。
        #expect(sundayGrid.days.first == makeDate(2025, 1, 26, calendar: sundayCalendar))
        #expect(mondayGrid.days.first == makeDate(2025, 1, 27, calendar: mondayCalendar))
        #expect(sundayGrid.days.filter(sundayGrid.isInMonth).count == 28)
        #expect(mondayGrid.days.filter(mondayGrid.isInMonth).count == 28)
    }

    // MARK: - 2 月与 31 天月

    @Test func februaryOfCommonYearHasTwentyEightInMonthDays() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 2, 1, calendar: calendar), calendar: calendar)

        #expect(grid.days.filter(grid.isInMonth).count == 28)
        #expect(grid.isInMonth(makeDate(2025, 2, 28, calendar: calendar)))
        #expect(!grid.isInMonth(makeDate(2025, 3, 1, calendar: calendar)))
    }

    @Test func februaryOfLeapYearHasTwentyNineInMonthDays() {
        let calendar = mondayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2024, 2, 29, calendar: calendar), calendar: calendar)

        #expect(grid.days.filter(grid.isInMonth).count == 29)
        #expect(grid.isInMonth(makeDate(2024, 2, 29, calendar: calendar)))
    }

    @Test func monthWithThirtyOneDaysFillsAllCellsInMonth() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 1, 20, calendar: calendar), calendar: calendar)

        #expect(grid.days.filter(grid.isInMonth).count == 31)
        #expect(grid.days.contains(makeDate(2025, 1, 31, calendar: calendar)))
    }

    // MARK: - 翻月（含跨年）

    @Test func monthOffsetMovesForwardAcrossYearBoundary() {
        let calendar = sundayFirstCalendar()
        let december = CalendarGrid.month(containing: makeDate(2025, 12, 15, calendar: calendar), calendar: calendar)

        let january = december.month(offsetBy: 1)

        #expect(january.firstDay == makeDate(2026, 1, 1, calendar: calendar))
        #expect(january.days.count == 42)
    }

    @Test func monthOffsetMovesBackwardAcrossYearBoundary() {
        let calendar = mondayFirstCalendar()
        let january = CalendarGrid.month(containing: makeDate(2025, 1, 15, calendar: calendar), calendar: calendar)

        let december = january.month(offsetBy: -1)

        #expect(december.firstDay == makeDate(2024, 12, 1, calendar: calendar))
    }

    @Test func monthOffsetCanJumpMoreThanAYear() {
        let calendar = sundayFirstCalendar()
        let january = CalendarGrid.month(containing: makeDate(2025, 1, 5, calendar: calendar), calendar: calendar)

        #expect(january.month(offsetBy: 13).firstDay == makeDate(2026, 2, 1, calendar: calendar))
        #expect(january.month(offsetBy: -13).firstDay == makeDate(2023, 12, 1, calendar: calendar))
    }

    @Test func monthOffsetByZeroKeepsSameGrid() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 8, 9, calendar: calendar), calendar: calendar)

        let sameMonth = grid.month(offsetBy: 0)

        #expect(sameMonth.firstDay == grid.firstDay)
        #expect(sameMonth.days == grid.days)
    }

    // MARK: - 判定

    @Test func isInMonthDistinguishesAdjacentMonthCells() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 10, calendar: calendar), calendar: calendar)

        #expect(grid.isInMonth(makeDate(2025, 11, 1, calendar: calendar)))
        #expect(grid.isInMonth(makeDate(2025, 11, 30, hour: 18, calendar: calendar)))
        #expect(!grid.isInMonth(makeDate(2025, 10, 31, calendar: calendar)))
        #expect(!grid.isInMonth(makeDate(2025, 12, 1, calendar: calendar)))
    }

    @Test func isWeekendMarksSaturdayAndSunday() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 2, 10, calendar: calendar), calendar: calendar)

        #expect(grid.isWeekend(makeDate(2025, 2, 1, calendar: calendar)), "2025-02-01 是周六")
        #expect(grid.isWeekend(makeDate(2025, 2, 2, calendar: calendar)), "2025-02-02 是周日")
        #expect(!grid.isWeekend(makeDate(2025, 2, 3, calendar: calendar)), "2025-02-03 是周一")
        #expect(!grid.isWeekend(makeDate(2025, 2, 5, calendar: calendar)), "2025-02-05 是周三")
    }

    @Test func isWeekendFollowsFirstWeekdaySetting() {
        let sundayCalendar = sundayFirstCalendar()
        let mondayCalendar = mondayFirstCalendar()
        let sundayGrid = CalendarGrid.month(containing: makeDate(2025, 5, 12, calendar: sundayCalendar), calendar: sundayCalendar)
        let mondayGrid = CalendarGrid.month(containing: makeDate(2025, 5, 12, calendar: mondayCalendar), calendar: mondayCalendar)
        let saturday = makeDate(2025, 5, 3, calendar: sundayCalendar)
        let monday = makeDate(2025, 5, 5, calendar: mondayCalendar)

        #expect(sundayGrid.isWeekend(saturday))
        #expect(mondayGrid.isWeekend(saturday))
        #expect(!sundayGrid.isWeekend(monday))
        #expect(!mondayGrid.isWeekend(monday))
    }

    @Test func isSameDayIgnoresTimeOfDay() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 7, 4, calendar: calendar), calendar: calendar)

        #expect(grid.isSameDay(
            makeDate(2025, 7, 4, hour: 8, calendar: calendar),
            makeDate(2025, 7, 4, hour: 22, calendar: calendar)
        ))
        #expect(!grid.isSameDay(
            makeDate(2025, 7, 4, calendar: calendar),
            makeDate(2025, 7, 5, calendar: calendar)
        ))
    }

    // MARK: - 快捷项定位

    @Test func dateForYearMonthDayReturnsMidnight() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 10, calendar: calendar), calendar: calendar)

        let date = grid.date(year: 2025, month: 11, day: 20)

        #expect(date == makeDate(2025, 11, 20, calendar: calendar))
    }

    @Test func dateForYearMonthDayRejectsInvalidDay() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 2, 10, calendar: calendar), calendar: calendar)

        #expect(grid.date(year: 2025, month: 2, day: 30) == nil)
        #expect(grid.date(year: 2025, month: 13, day: 1) == nil)
        #expect(grid.date(year: 2025, month: 2, day: 0) == nil)
    }

    @Test func dateForYearMonthDayCanTargetAnotherMonth() {
        let calendar = mondayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 10, calendar: calendar), calendar: calendar)

        #expect(grid.date(year: 2026, month: 1, day: 5) == makeDate(2026, 1, 5, calendar: calendar))
        #expect(grid.date(year: 2024, month: 12, day: 31) == makeDate(2024, 12, 31, calendar: calendar))
    }

    @Test func monthContainingIsIdempotentForAnyDayInGrid() {
        let calendar = sundayFirstCalendar()
        let grid = CalendarGrid.month(containing: makeDate(2025, 11, 10, calendar: calendar), calendar: calendar)

        // 网格内「本月」的任意一格都映回同一网格。
        for day in grid.days where grid.isInMonth(day) {
            #expect(CalendarGrid.month(containing: day, calendar: calendar) == grid)
        }
    }
}

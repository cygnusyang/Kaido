import Foundation
import Testing
@testable import KairoCore

/// D-017：month 档快路径与逐日参考实现逐位等价（跨实现比较，防快路径漂移）。
struct MonthFastPathEquivalenceTests {
    /// 逐日参考实现（与改造前 GanttLayout.make 的循环逐行同构）。
    private static func naiveMonthTicks(
        windowStart: Date, windowEnd: Date, dayWidth: Double, calendar: Calendar
    ) -> (lower: [String], dates: [Date], upper: [String]) {
        var lower: [String] = []
        var dates: [Date] = []
        var upper: [String] = []
        var upperSeen = Set<Date>()
        var cursor = windowStart
        while cursor < windowEnd {
            let day = calendar.component(.day, from: cursor)
            let month = calendar.component(.month, from: cursor)
            let year = calendar.component(.year, from: cursor)
            if day == 1 {
                lower.append(month == 1 ? "\(year)" : "\(month)月")
                dates.append(cursor)
                let day0 = calendar.startOfDay(for: cursor)
                if upperSeen.insert(day0).inserted, month == 1 {
                    upper.append("\(year)年")
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return (lower, dates, upper)
    }

    @Test func monthFastPathMatchesNaiveDayLoop() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let start = calendar.date(from: DateComponents(year: 2020, month: 3, day: 15))!

        for dayWidth in [0.5, 2.0, 5.0, 120.0] {
            let layout = GanttLayoutEngine.make(
                tasks: [], schedule: nil, calendar: calendar, zoom: .month,
                viewWidth: 1_920, windowStart: start, dayWidthOverride: dayWidth
            )
            let windowEnd = start.addingTimeInterval(1_920 / dayWidth * 86_400)
            var expected = Self.naiveMonthTicks(
                windowStart: start, windowEnd: windowEnd, dayWidth: dayWidth, calendar: calendar)
            // 循环前的既有行为：窗口起点非月初时补当月上层标签（x=0）。
            if calendar.component(.month, from: start) != 1 {
                expected.upper.insert(
                    "\(calendar.component(.year, from: start))年", at: 0)
            }

            let lower = layout.ticks.filter { $0.tier == .lower }
            let upper = layout.ticks.filter { $0.tier == .upper }
            #expect(lower.map(\.label) == expected.lower)
            #expect(lower.map(\.date) == expected.dates)
            #expect(upper.map(\.label) == expected.upper)
            #expect(lower.map(\.x) == expected.dates.map {
                $0.timeIntervalSince(start) / 86_400 * dayWidth
            })
            #expect(layout.bands.isEmpty)
        }
    }

    @Test func monthFastPathStartsAtNextMonthWhenMidMonth() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.firstWeekday = 2
        let start = calendar.date(from: DateComponents(year: 2026, month: 7, day: 18))!
        let layout = GanttLayoutEngine.make(
            tasks: [], schedule: nil, calendar: calendar, zoom: .month,
            viewWidth: 1_920, windowStart: start, dayWidthOverride: 5.0
        )
        let first = try #require(layout.ticks.first { $0.tier == .lower })
        let components = calendar.dateComponents([.year, .month, .day], from: first.date)
        #expect(components.month == 8 && components.day == 1 && components.year == 2026)
        #expect(abs(first.x - 14 * 5.0) < 1e-9)
    }
}

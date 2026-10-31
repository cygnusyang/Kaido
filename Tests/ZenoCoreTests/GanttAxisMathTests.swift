import Foundation
import Testing
@testable import ZenoCore

// v0.14 G2：横向换算抽成公开纯函数（docs/features/10-multi-baseline-gantt.md §3）。
//
// 锁定的口径：
// ① `x(for:windowStart:dayWidth:)` / `width(from:to:dayWidth:)` 就是
//    `(date − windowStart) / 86400 × dayWidth`，且引擎产出的计划条必须走这条路径
//    （基线细条与计划条同一条尺子，不得各算一份）；
// ② 跨夏令时的 23 / 25 小时日**仍按 24 小时虚拟日**占固定日宽——这是既有的坐标语义
//    （刻度、非工作带同一把尺子），改它会整体平移条体；
// ③ 负区间夹取为 0，不产生负宽条。
//
// 期望值一律写字面量或独立算式，不调用被测函数现算（D-009）。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

/// 纽约时区：2025-03-09 02:00 进入夏令时、2025-11-02 02:00 退出。
private let newYork: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}()

private func utcDate(_ y: Int, _ m: Int, _ d: Int, hour: Int = 0) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d, hour: hour))!
}

private func nyDate(_ y: Int, _ m: Int, _ d: Int) -> Date {
    newYork.date(from: DateComponents(year: y, month: m, day: d))!
}

private func makeTask(_ title: String, duration: Double, start: Date) -> TaskItem {
    TaskItem(
        title: title,
        durationDays: duration,
        constraint: .startNoEarlierThan(start)
    )
}

struct GanttAxisMathTests {
    // MARK: - x(for:windowStart:dayWidth:)

    @Test func xEqualsDayOffsetTimesDayWidth() {
        let windowStart = utcDate(2026, 3, 2)
        let cases: [(day: Int, dayWidth: Double, expected: Double)] = [
            (0, 32, 0),
            (1, 32, 32),
            (7, 12, 84),
            (45, 5, 225),
            (3, 2.5, 7.5)
        ]
        for c in cases {
            let date = windowStart.addingTimeInterval(Double(c.day) * 86_400)
            let x = GanttLayoutEngine.x(for: date, windowStart: windowStart, dayWidth: c.dayWidth)
            #expect(x == c.expected, "day=\(c.day) dayWidth=\(c.dayWidth)")
        }
    }

    @Test func xBeforeWindowStartIsNegative() {
        let windowStart = utcDate(2026, 3, 2)
        let earlier = windowStart.addingTimeInterval(-2 * 86_400)
        #expect(GanttLayoutEngine.x(for: earlier, windowStart: windowStart, dayWidth: 12) == -24)
    }

    /// 跨 DST：2025-03-09 02:00 进入夏令时，故 03-09 → 03-10 只有 23 小时。
    /// 坐标按 86 400 秒折算，这一天占 23/24 个日宽（不是整 32）。
    @Test func xAcrossSpringForwardUsesVirtualDays() {
        let windowStart = nyDate(2025, 3, 9)
        let date = nyDate(2025, 3, 10)
        let expected = 23.0 / 24 * 32
        let x = GanttLayoutEngine.x(for: date, windowStart: windowStart, dayWidth: 32)
        #expect(x == expected)
        #expect(x != 32)
    }

    /// 跨 DST 累积：03-08 → 03-10 = 24 + 23 = 47 小时（只有切换日短一小时）。
    @Test func xAcrossSpringForwardAccumulatesSkippedHour() {
        let windowStart = nyDate(2025, 3, 8)
        let date = nyDate(2025, 3, 10)
        let x = GanttLayoutEngine.x(for: date, windowStart: windowStart, dayWidth: 32)
        #expect(x == 47.0 / 24 * 32)
    }

    /// 跨 DST：2025-11-01 → 2025-11-03 有 49 小时（回拨一小时）。
    @Test func xAcrossFallBackUsesVirtualDays() {
        let windowStart = nyDate(2025, 11, 1)
        let date = nyDate(2025, 11, 3)
        let expected = 49.0 / 24 * 32
        let x = GanttLayoutEngine.x(for: date, windowStart: windowStart, dayWidth: 32)
        #expect(x == expected)
        #expect(x != 2 * 32)
    }

    // MARK: - width(from:to:dayWidth:)

    @Test func widthEqualsDurationTimesDayWidth() {
        let start = utcDate(2026, 3, 2)
        let cases: [(days: Double, dayWidth: Double, expected: Double)] = [
            (0, 32, 0),
            (1, 32, 32),
            (3.5, 32, 112),
            (5, 12, 60),
            (10, 2.5, 25)
        ]
        for c in cases {
            let finish = start.addingTimeInterval(c.days * 86_400)
            let w = GanttLayoutEngine.width(from: start, to: finish, dayWidth: c.dayWidth)
            #expect(w == c.expected, "days=\(c.days) dayWidth=\(c.dayWidth)")
        }
    }

    /// 反向区间（finish < start）不得产生负宽条。
    @Test func widthClampsReversedRangeToZero() {
        let start = utcDate(2026, 3, 5)
        let finish = start.addingTimeInterval(-3 * 86_400)
        #expect(GanttLayoutEngine.width(from: start, to: finish, dayWidth: 32) == 0)
    }

    /// 跨 DST 的区间同样按虚拟日折算：2025-11-01 → 2025-11-03 = 49h。
    @Test func widthAcrossFallBackUsesVirtualDays() {
        let start = nyDate(2025, 11, 1)
        let finish = nyDate(2025, 11, 3)
        #expect(GanttLayoutEngine.width(from: start, to: finish, dayWidth: 32) == 49.0 / 24 * 32)
    }

    // MARK: - 引擎调用点必须走同一换算（D-024「不得写第二份」）

    /// 引擎产出的计划条与两条纯函数逐位相等：证明 `make` 没有另算一份。
    @Test func engineBarsUseTheSharedConversion() throws {
        let projectStart = utcDate(2026, 3, 2)
        let tasks = [
            makeTask("设计", duration: 4, start: projectStart),
            makeTask("实现", duration: 6, start: utcDate(2026, 3, 10))
        ]
        let schedule = ScheduleEngine.compute(
            tasks: tasks,
            projectStart: projectStart,
            projectEnd: nil,
            calendar: utc
        )
        let layout = GanttLayoutEngine.make(
            tasks: tasks,
            schedule: schedule,
            calendar: utc,
            locale: Locale(identifier: "zh_CN"),
            zoom: .day,
            viewWidth: 800
        )
        #expect(!layout.bars.isEmpty)
        let scheduled = try #require(
            schedule.tasks.first { $0.taskID == layout.bars[0].taskID }
        )
        for bar in layout.bars {
            let task = try #require(schedule.tasks.first { $0.taskID == bar.taskID })
            #expect(bar.x == GanttLayoutEngine.x(
                for: task.scheduledStart,
                windowStart: layout.windowStart,
                dayWidth: layout.dayWidth
            ))
            #expect(bar.width == GanttLayoutEngine.width(
                from: task.scheduledStart,
                to: task.scheduledFinish,
                dayWidth: layout.dayWidth
            ))
        }
        // 顺带确认夹具非空且首条确实从窗口起点开始。
        #expect(scheduled.scheduledStart == layout.windowStart)
    }

    /// 今天线也用同一换算（D-024：今天线与条体共尺）。
    @Test func todayLineUsesTheSharedConversion() throws {
        let projectStart = utcDate(2026, 3, 2)
        let today = utcDate(2026, 3, 5)
        let tasks = [makeTask("设计", duration: 4, start: projectStart)]
        let schedule = ScheduleEngine.compute(
            tasks: tasks,
            projectStart: projectStart,
            projectEnd: nil,
            calendar: utc
        )
        let layout = GanttLayoutEngine.make(
            tasks: tasks,
            schedule: schedule,
            calendar: utc,
            locale: Locale(identifier: "zh_CN"),
            zoom: .day,
            viewWidth: 800,
            today: today
        )
        let todayX = try #require(layout.todayX)
        #expect(todayX == GanttLayoutEngine.x(
            for: today,
            windowStart: layout.windowStart,
            dayWidth: layout.dayWidth
        ))
        // 3 天后 → 3 × 32 = 96。
        #expect(todayX == 96)
    }
}

import Foundation
import Testing
@testable import ZenoCore

// H-1：引擎日期算术按「日历日」而非 86 400 秒折算（跨夏令时切换仍落在本地零点）。
// 时区固定 America/New_York：2025-11-02 02:00 DST 结束、2025-03-09 02:00 DST 开始，
// 两段切换都落在下面用例的区间内。期望值为字面日期，不用被测函数现算（避免 D-009）。

private let ny: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "America/New_York")!
    return c
}()

/// 纽约时区的某天零点。
private func nyDay(_ y: Int, _ m: Int, _ d: Int) -> Date {
    ny.date(from: DateComponents(year: y, month: m, day: d))!
}

/// 本地零点断言：DST 漂移的典型症状是落到前一天 23:00 或次日 01:00。
private func isLocalMidnight(_ date: Date) -> Bool {
    ny.dateComponents([.hour, .minute, .second], from: date) == DateComponents(hour: 0, minute: 0, second: 0)
}

/// 两日期之间的日历日差（测试侧独立用 Foundation 计算，不复用引擎内部实现）。
private func calendarDayGap(_ from: Date, _ to: Date) -> Int {
    ny.dateComponents([.day], from: from, to: to).day ?? .min
}

private func compute(_ tasks: [TaskItem], start: Date, end: Date? = nil) -> ScheduleResult {
    ScheduleEngine.compute(tasks: tasks, projectStart: start, projectEnd: end, calendar: ny)
}

struct ScheduleDaylightSavingTests {
    // DST 结束：2025-11-01 起排，选定安排的结束必须落在所选日历日（不得少一天）。
    @Test func fallBackScheduledFinishLandsOnCalendarDay() throws {
        let cases: [(duration: Double, finish: Date)] = [
            (1, nyDay(2025, 11, 2)),
            (3, nyDay(2025, 11, 4)),
            (5, nyDay(2025, 11, 6)),
        ]

        for c in cases {
            let start = nyDay(2025, 11, 1)
            let t = TaskItem(title: "跨 DST 结束", startDate: start, durationDays: c.duration)

            let s = try #require(compute([t], start: start).scheduled(t.id))

            #expect(s.scheduledStart == start)
            #expect(s.scheduledFinish == c.finish)
            #expect(isLocalMidnight(s.scheduledFinish))
            #expect(calendarDayGap(s.scheduledStart, s.scheduledFinish) == Int(c.duration))
            // 最早窗口与选定安排同口径。
            #expect(s.earliestFinish == c.finish)
        }
    }

    // DST 开始：2025-03-09 起排，结束同样按日历日推进（不得落到次日 01:00）。
    @Test func springForwardScheduledFinishLandsOnCalendarDay() throws {
        let cases: [(duration: Double, finish: Date)] = [
            (1, nyDay(2025, 3, 10)),
            (3, nyDay(2025, 3, 12)),
            (5, nyDay(2025, 3, 14)),
        ]

        for c in cases {
            let start = nyDay(2025, 3, 9)
            let t = TaskItem(title: "跨 DST 开始", startDate: start, durationDays: c.duration)

            let s = try #require(compute([t], start: start).scheduled(t.id))

            #expect(s.scheduledStart == start)
            #expect(s.scheduledFinish == c.finish)
            #expect(isLocalMidnight(s.scheduledFinish))
            #expect(calendarDayGap(s.scheduledStart, s.scheduledFinish) == Int(c.duration))
        }
    }

    // 相关性前导时间与后向传播同样按日历日：跨 DST 结束的链不得错位到 23:00。
    @Test func dependencyLagAndBackwardPassSpanDstByCalendarDay() throws {
        let start = nyDay(2025, 11, 1)
        let a = TaskItem(title: "A", durationDays: 2) // 11-01 → 11-03（跨 DST 结束）
        let b = TaskItem(
            title: "B", durationDays: 1,
            dependencies: [TaskDependency(predecessorID: a.id, type: .fs, lagDays: 1)]
        )

        let result = compute([a, b], start: start, end: nyDay(2025, 11, 10))
        let sa = try #require(result.scheduled(a.id))
        let sb = try #require(result.scheduled(b.id))

        #expect(sa.earliestFinish == nyDay(2025, 11, 3))
        #expect(isLocalMidnight(sa.earliestFinish))
        // FS + lag 1：B 最早开始 = A 结束 + 1 日历日。
        #expect(sb.earliestStart == nyDay(2025, 11, 4))
        #expect(sb.earliestFinish == nyDay(2025, 11, 5))
        #expect(isLocalMidnight(sb.earliestFinish))
        // 后向传播：项目结束锚点 11-10，B 持续 1 天 → 最晚开始 11-09；
        // A 最晚结束 = B 最晚开始 − lag 1 = 11-08，最晚开始 = 11-06。
        #expect(sb.latestStart == nyDay(2025, 11, 9))
        #expect(sa.latestFinish == nyDay(2025, 11, 8))
        #expect(sa.latestStart == nyDay(2025, 11, 6))
        #expect(isLocalMidnight(sa.latestStart))
    }

    // 宽延按日历日计数：跨 DST 结束的一周差异不得被算成 8 天。
    @Test func totalSlackCountsCalendarDaysAcrossFallBack() throws {
        let start = nyDay(2025, 11, 1)
        let a = TaskItem(title: "A", durationDays: 5) // 11-01 → 11-06（跨 DST 结束）
        let b = TaskItem(title: "B", durationDays: 1, dependencies: [TaskDependency(predecessorID: a.id)])

        let result = compute([a, b], start: start, end: nyDay(2025, 11, 10))
        let sa = try #require(result.scheduled(a.id))

        // A 最早 11-01，最晚 11-04（受 B 最晚开始 11-09 反推）→ 3 天宽延；
        // 若按 86 400 秒折算，11-01→11-04 会被算成 3.04 天。
        #expect(sa.earliestStart == start)
        #expect(sa.latestStart == nyDay(2025, 11, 4))
        #expect(sa.totalSlackDays == 3)
        #expect(sa.freeSlackDays == 0)
    }

    // 时限换算（startNoLaterThan → 结束上界）按日历日：持续 3 天不应落在 23:00。
    @Test func constraintEndBoundSpanningDstLandsOnCalendarDay() throws {
        let start = nyDay(2025, 10, 30)
        let t = TaskItem(
            title: "时限跨 DST", durationDays: 3,
            constraint: .startNoLaterThan(nyDay(2025, 10, 31))
        )

        let s = try #require(compute([t], start: start, end: nyDay(2025, 11, 20)).scheduled(t.id))

        // 上界 = 10-31 + 3 日历日 = 11-03（DST 结束后仍是零点）。
        #expect(s.latestFinish == nyDay(2025, 11, 3))
        #expect(isLocalMidnight(s.latestFinish))
        #expect(s.latestStart == nyDay(2025, 10, 31))
    }
}

import Foundation
import Testing
@testable import KairoCore

// 排期锚点推导（ADR-013 / D-003）：项目未设开始日期时，禁止从 1970 纪元起排。
// 优先级：项目开始日期 → 最早任务意图开始日期 → 今天。

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()

private func day(_ y: Int, _ m: Int, _ d: Int) -> Date {
    utc.date(from: DateComponents(year: y, month: m, day: d))!
}

private let now = day(2026, 10, 18)

struct ScheduleAnchorTests {
    @Test func explicitProjectStartWins() {
        let anchor = ScheduleAnchor.derive(
            tasks: [TaskItem(title: "A", startDate: day(2026, 11, 2))],
            projectStart: day(2026, 12, 1),
            now: now,
            calendar: utc
        )

        #expect(anchor.date == day(2026, 12, 1))
        #expect(anchor.source == .projectStart)
        #expect(!anchor.isDerived)
    }

    @Test func earliestTaskIntentStartIsUsedWhenProjectStartMissing() {
        let anchor = ScheduleAnchor.derive(
            tasks: [
                TaskItem(title: "后", startDate: day(2026, 11, 9)),
                TaskItem(title: "前", startDate: day(2026, 11, 2)),
                TaskItem(title: "无日期")
            ],
            projectStart: nil,
            now: now,
            calendar: utc
        )

        #expect(anchor.date == day(2026, 11, 2))
        #expect(anchor.source == .earliestTaskStart)
        #expect(anchor.isDerived)
    }

    @Test func todayIsFallbackWhenNoProjectOrTaskDate() {
        let anchor = ScheduleAnchor.derive(
            tasks: [TaskItem(title: "A")],
            projectStart: nil,
            now: now.addingTimeInterval(3600 * 13),
            calendar: utc
        )

        #expect(anchor.date == day(2026, 10, 18))
        #expect(anchor.source == .today)
        #expect(anchor.isDerived)
    }

    @Test func dueDateDoesNotDriveAnchor() {
        let anchor = ScheduleAnchor.derive(
            tasks: [TaskItem(title: "A", dueDate: day(2026, 9, 1))],
            projectStart: nil,
            now: now,
            calendar: utc
        )

        #expect(anchor.date == day(2026, 10, 18))
        #expect(anchor.source == .today)
    }

    @Test func anchorIsNormalizedToStartOfDay() {
        let anchor = ScheduleAnchor.derive(
            tasks: [],
            projectStart: day(2026, 12, 1).addingTimeInterval(3600 * 17),
            now: now,
            calendar: utc
        )

        #expect(anchor.date == day(2026, 12, 1))
    }
}

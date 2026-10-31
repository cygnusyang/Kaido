import Foundation
import Testing
import ZenoPresentation

/// 定位滚动单测（D-042）：目标在窗口内不动，出窗口后落到窗口左侧 1/4 处。
struct RevealWindowTests {
    private let day: TimeInterval = 86_400

    private func interval(startDay: Int, lengthDays: Double) -> DateInterval {
        let start = makeDate(2025, 3, 1).addingTimeInterval(Double(startDay) * day)
        return DateInterval(start: start, duration: lengthDays * day)
    }

    @Test func targetInsideWindowDoesNotScroll() {
        let window = interval(startDay: 0, lengthDays: 7)
        let target = interval(startDay: 2, lengthDays: 3)
        #expect(RevealWindow.scrolledStart(target: target, window: window) == nil)
    }

    /// 与窗口端点重合也算「在内」：定位已可见的任务不该再跳一下。
    @Test func targetTouchingWindowEdgesDoesNotScroll() {
        let window = interval(startDay: 0, lengthDays: 7)
        #expect(RevealWindow.scrolledStart(
            target: interval(startDay: 0, lengthDays: 7), window: window
        ) == nil)
        #expect(RevealWindow.scrolledStart(
            target: interval(startDay: 7, lengthDays: 0), window: window
        ) == nil)
    }

    @Test func targetBeforeWindowScrollsToQuarterLead() {
        let window = interval(startDay: 30, lengthDays: 7)
        let target = interval(startDay: 10, lengthDays: 2)
        let expected = interval(startDay: 10, lengthDays: 0).start
            .addingTimeInterval(-7 * day * RevealWindow.leadFraction)
        #expect(RevealWindow.scrolledStart(target: target, window: window) == expected)
        // 目标起点落在新窗口的 1/4 处。
        #expect(RevealWindow.leadFraction == 0.25)
    }

    @Test func targetAfterWindowScrollsToQuarterLead() {
        let window = interval(startDay: 0, lengthDays: 7)
        let target = interval(startDay: 20, lengthDays: 1)
        let newStart = RevealWindow.scrolledStart(target: target, window: window)
        let expected = interval(startDay: 20, lengthDays: 0).start.addingTimeInterval(-7 * day * 0.25)
        #expect(newStart == expected)
    }

    /// 部分可见也算「要滚」：目标被窗口切掉一半时，读者看不到它的全貌。
    @Test func partiallyVisibleTargetScrolls() {
        let window = interval(startDay: 5, lengthDays: 7)
        let target = interval(startDay: 3, lengthDays: 4)
        #expect(RevealWindow.scrolledStart(target: target, window: window) != nil)
    }

    /// 零宽窗口没有比例可言：保持原状，让调用方不要写回一个凭空算出的起点。
    @Test func zeroLengthWindowDoesNotScroll() {
        let window = DateInterval(start: makeDate(2025, 3, 1), duration: 0)
        let target = interval(startDay: 20, lengthDays: 1)
        #expect(RevealWindow.scrolledStart(target: target, window: window) == nil)
    }

    /// 零宽目标（里程碑）在窗口右侧之外：同样滚到 1/4 处，不退化成「已在窗内」。
    @Test func milestoneAfterWindowScrollsToQuarterLead() {
        let window = interval(startDay: 0, lengthDays: 7)
        let at = makeDate(2025, 3, 1).addingTimeInterval(20 * day)
        let milestone = DateInterval(start: at, duration: 0)
        let newStart = RevealWindow.scrolledStart(target: milestone, window: window)
        #expect(newStart == at.addingTimeInterval(-7 * day * 0.25))
    }
}

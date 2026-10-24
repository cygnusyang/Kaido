import Foundation
import Testing
import KairoCommands
import KairoCore
@testable import KairoMacApp

/// 横向平移上下文：亚日余量累积与窗口起点的整天推进（F-14-18）。
@MainActor
struct HorizontalPanContextTests {

    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        Calendar.current.startOfDay(
            for: Calendar.current.date(from: DateComponents(year: year, month: month, day: day))!
        )
    }

    private func makeContext(dayWidth: Double = 10, windowStart: Date) -> HorizontalPanContext {
        let context = HorizontalPanContext()
        context.sync(dayWidth: dayWidth, windowStart: windowStart)
        return context
    }

    @Test func slowScrollAccumulatesWholeDays() {
        // 日宽 10pt：4px 不足一天，跨整天才提交，慢速滑动不丢位移也不「一天天蹦」。
        let context = makeContext(windowStart: date(2026, 10, 24))
        #expect(context.consumeScroll(deltaX: 4) == 0)
        #expect(context.consumeScroll(deltaX: 4) == 0)
        #expect(context.consumeScroll(deltaX: 4) == 1)
    }

    @Test func scrollingRightMovesWindowToEarlierDates() {
        let context = makeContext(windowStart: date(2026, 10, 24))
        let target = context.advance(byDays: 3)
        #expect(target == date(2026, 10, 21))
        #expect(context.windowStart == date(2026, 10, 21))
    }

    @Test func scrollingLeftMovesWindowToLaterDates() {
        let context = makeContext(windowStart: date(2026, 10, 24))
        #expect(context.advance(byDays: -2) == date(2026, 10, 26))
    }

    @Test func consecutiveAdvancesCompose() {
        // 连续滚动事件之间 SwiftUI 可能还没回灌新快照，本地起点必须自己往前走。
        let context = makeContext(windowStart: date(2026, 10, 24))
        _ = context.advance(byDays: 1)
        #expect(context.advance(byDays: 1) == date(2026, 10, 22))
    }

    @Test func zeroDaysKeepsWindowStart() {
        let context = makeContext(windowStart: date(2026, 10, 24))
        #expect(context.advance(byDays: 0) == date(2026, 10, 24))
    }

    @Test func resettingAccumulatorDropsRemainder() {
        let context = makeContext(windowStart: date(2026, 10, 24))
        _ = context.consumeScroll(deltaX: 9)
        context.resetAccumulator()
        // 余量清零后单次 9px 不再凑够一天。
        #expect(context.consumeScroll(deltaX: 9) == 0)
        #expect(context.consumeScroll(deltaX: 1) == 1)
    }

    @Test func applyScrollDispatchesWholeDayPan() {
        // 端到端（不涉视图）：像素位移 → 整天 → store 的窗口起点真的前移。
        let suite = "kairo.apptests.pan.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KairoFile.read(from: $0) }
        )
        let context = HorizontalPanContext()
        context.attach(store: store)
        context.sync(dayWidth: 10, windowStart: store.snapshot.gantt.windowStart)
        let before = store.snapshot.gantt.windowStart

        context.applyScroll(deltaX: 30) // 30pt / 10pt 每天 = 3 天

        let after = store.snapshot.gantt.windowStart
        let movedDays = Calendar.current.dateComponents([.day], from: after, to: before).day
        #expect(movedDays == 3, "向右滑看更早日期：窗口起点应前移 3 天")
    }

    @Test func tinyDayWidthFallsBackToHalfPoint() {
        // 日宽异常（<0.5）时按 0.5 兜底，避免除零导致的无穷大位移。
        let context = makeContext(dayWidth: 0, windowStart: date(2026, 10, 24))
        #expect(context.consumeScroll(deltaX: 1) == 2)
    }
}

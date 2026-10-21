import Foundation
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

// F-14-18 拖拽平移状态机单测：方向、取整、同值抑制、生命周期。

@MainActor
@Suite struct PanDragSessionTests {
    private let base = makePanDate(2025, 3, 15)

    private func makeSession() -> PanDragSession {
        let session = PanDragSession()
        session.begin(windowStart: base, dayWidth: 10)
        return session
    }

    @Test func dragRightMovesWindowEarlier() {
        let session = makeSession()
        // 右拖 25pt / 10 = 2.5 → 3 天：内容右移 ⇒ 窗口起点减 3 天。
        #expect(session.update(translationX: 25) == makePanDate(2025, 3, 12))
    }

    @Test func dragLeftMovesWindowLater() {
        let session = makeSession()
        #expect(session.update(translationX: -40) == makePanDate(2025, 3, 19))
    }

    @Test func sameDayCountIsSuppressed() {
        let session = makeSession()
        #expect(session.update(translationX: 25) != nil)
        // 26pt 仍落在 3 天：不重复提交。
        #expect(session.update(translationX: 26) == nil)
        #expect(session.update(translationX: 35) == makePanDate(2025, 3, 11))
    }

    @Test func endAndCancelDeactivate() {
        let session = makeSession()
        session.end()
        #expect(!session.isActive)
        #expect(session.update(translationX: 50) == nil)

        session.begin(windowStart: base, dayWidth: 10)
        #expect(session.isActive)
        session.cancel()
        #expect(!session.isActive)
    }

    @Test func zeroDayWidthFallsBack() {
        let session = PanDragSession()
        session.begin(windowStart: base, dayWidth: 0)
        // 兜底 0.5：1pt ≈ 2 天。
        #expect(session.update(translationX: 1) == makePanDate(2025, 3, 13))
    }

    // MARK: - 滚动上下文（引用语义，长生命周期监听用）

    @Test func contextUsesLatestGeometry() {
        let context = HorizontalPanContext()
        context.sync(dayWidth: 10, windowStart: base)
        // 切档到日宽 5：同一像素位移换算出的天数翻倍。
        context.sync(dayWidth: 5, windowStart: base)
        #expect(context.consumeScroll(deltaX: 10) == 2)
        #expect(context.windowStart == base)
    }

    @Test func contextClampsDayWidthAndResetsRemainder() {
        let context = HorizontalPanContext()
        context.sync(dayWidth: 0, windowStart: base)
        // 兜底 0.5：1pt = 2 天。
        #expect(context.consumeScroll(deltaX: 1) == 2)
        context.resetAccumulator()
        #expect(context.consumeScroll(deltaX: 0.2) == 0)
    }
}

private func makePanDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.current.startOfDay(for: Calendar.current.date(from: components)!)
}

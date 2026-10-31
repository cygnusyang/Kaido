import Foundation
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// F-14-18 / D-049 拖拽平移状态机单测：方向、亚日精度、同值抑制、生命周期。

@MainActor
@Suite struct PanDragSessionTests {
    private let base = makePanDate(2025, 3, 15)

    private func makeSession() -> PanDragSession {
        let session = PanDragSession()
        session.begin(windowStart: base, dayWidth: 10)
        return session
    }

    /// 右拖 25pt / 10 = 2.5 天 ⇒ 窗口起点前移 2.5 天。
    /// 亚日精度是刻意的（v1.3.7 / D-049）：取整到整天会让鼠标拖拽一格一格跳。
    @Test func dragRightMovesWindowEarlierContinuously() {
        let session = makeSession()
        #expect(session.update(translationX: 25) == base.addingTimeInterval(-2.5 * 86_400))
    }

    @Test func dragLeftMovesWindowLater() {
        let session = makeSession()
        #expect(session.update(translationX: -40) == base.addingTimeInterval(4 * 86_400))
    }

    @Test func identicalTranslationIsSuppressed() {
        let session = makeSession()
        #expect(session.update(translationX: 25) != nil)
        // 同一位移重复到达（同一帧多次回调）：不重复 dispatch。
        #expect(session.update(translationX: 25) == nil)
        #expect(session.update(translationX: 35) == base.addingTimeInterval(-3.5 * 86_400))
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
        // 兜底 0.5：1pt = 2 天。
        #expect(session.update(translationX: 1) == base.addingTimeInterval(-2 * 86_400))
    }
}

private func makePanDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
    var components = DateComponents()
    components.year = year
    components.month = month
    components.day = day
    return Calendar.current.startOfDay(for: Calendar.current.date(from: components)!)
}

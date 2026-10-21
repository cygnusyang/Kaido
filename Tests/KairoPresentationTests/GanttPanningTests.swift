import Foundation
import Testing
import KairoCore
import KairoPresentation

// F-14-18 横向平移余量累积器单测。
//
// 契约：窗口起点整天归一 ⇒ 亚日位移留余量，跨整天才释放；方向正 = 内容右移；
// dayWidth 下限 0.5 兜底（与 pannedWindowStart 同式）。

@Suite struct GanttPanningTests {
    @Test func subDayDeltasAccumulateUntilWholeDay() {
        var accumulator = HorizontalPanAccumulator()
        // 日宽 10：每次 5pt = 0.5 天，两次才凑满一天。
        #expect(accumulator.consume(deltaX: 5, dayWidth: 10) == 0)
        #expect(accumulator.consume(deltaX: 5, dayWidth: 10) == 1)
        #expect(accumulator.remainderDays == 0)
    }

    @Test func remainderIsPreservedAcrossCalls() {
        var accumulator = HorizontalPanAccumulator()
        #expect(accumulator.consume(deltaX: 3, dayWidth: 10) == 0)
        #expect(accumulator.remainderDays == 0.3)
        #expect(accumulator.consume(deltaX: 8, dayWidth: 10) == 1)
        #expect(abs(accumulator.remainderDays - 0.1) < 0.0001)
    }

    @Test func negativeDeltasMoveContentLeft() {
        var accumulator = HorizontalPanAccumulator()
        #expect(accumulator.consume(deltaX: -30, dayWidth: 10) == -3)
        #expect(accumulator.consume(deltaX: -25, dayWidth: 10) == -2)
        #expect(abs(accumulator.remainderDays + 0.5) < 0.0001)
    }

    @Test func largeDeltaReleasesMultipleDays() {
        var accumulator = HorizontalPanAccumulator()
        #expect(accumulator.consume(deltaX: 95, dayWidth: 10) == 9)
        #expect(abs(accumulator.remainderDays - 0.5) < 0.0001)
    }

    @Test func zeroDayWidthFallsBackToHalfPoint() {
        var accumulator = HorizontalPanAccumulator()
        // 日宽兜底 0.5：1pt = 2 天。
        #expect(accumulator.consume(deltaX: 1, dayWidth: 0) == 2)
    }

    @Test func resetClearsRemainder() {
        var accumulator = HorizontalPanAccumulator()
        _ = accumulator.consume(deltaX: 7, dayWidth: 10)
        accumulator.reset()
        #expect(accumulator.remainderDays == 0)
    }
}

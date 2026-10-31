import Foundation
import Testing
import ZenoCore
import ZenoPresentation

// F-14-18 / D-049 横向平移的像素 → 天换算。
//
// 契约：亚日精度（连续滚动）、正 = 内容右移、日宽下限 0.5 兜底（与布局夹取同式）。
// 旧实现是「攒满整天再提交」的累积器，跨度模式一天 171pt，画面一言不发然后整格跳，
// 用户体验就是拖不动；换成无状态换算后每一帧都推进。

@Suite struct GanttPanningTests {
    @Test func pixelsConvertToFractionalDays() {
        #expect(HorizontalPan.days(deltaX: 5, dayWidth: 10) == 0.5)
        #expect(HorizontalPan.days(deltaX: 1, dayWidth: 100) == 0.01)
    }

    @Test func negativeDeltasMoveContentLeft() {
        #expect(HorizontalPan.days(deltaX: -30, dayWidth: 10) == -3)
        #expect(HorizontalPan.days(deltaX: -25, dayWidth: 10) == -2.5)
    }

    @Test func largeDeltaKeepsWholeAndFraction() {
        #expect(HorizontalPan.days(deltaX: 95, dayWidth: 10) == 9.5)
    }

    @Test func zeroDayWidthFallsBackToHalfPoint() {
        // 日宽兜底 0.5：1pt = 2 天。
        #expect(HorizontalPan.days(deltaX: 1, dayWidth: 0) == 2)
        #expect(HorizontalPan.minimumDayWidth == 0.5)
    }

    /// 换算必须与布局的「日宽 → 米」同源：同一天数在两端抵出同样的像素。
    @Test func roundTripDaysAndPixelsAgree() {
        let dayWidth = 74.0
        let pixels = 45.0
        let days = HorizontalPan.days(deltaX: pixels, dayWidth: dayWidth)
        #expect(abs(days * dayWidth - pixels) < 1e-9)
    }
}

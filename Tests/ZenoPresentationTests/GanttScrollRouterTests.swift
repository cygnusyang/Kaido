import Testing
@testable import ZenoPresentation

/// 横向滚动输入的处置规则（F-14-18 / D-027）。
///
/// 这组用例覆盖「为什么这条滚动事件没有平移画布」的全部分支：分量方向、几何是否
/// 就绪、窗口归属、文本编辑、视口命中。真机双指手势本身无法在离屏测试里复现，
/// 因此把判定抽成纯函数后在这里逐条锁死。
@Suite("甘特横向滚动处置")
struct GanttScrollRouterTests {
    private func input(
        deltaX: Double = 0,
        deltaY: Double = 0,
        shift: Bool = false,
        hasViewport: Bool = true,
        hasCursor: Bool = true,
        cursorInsideViewport: Bool = true,
        isEditingText: Bool = false
    ) -> GanttScrollInput {
        GanttScrollInput(
            deltaX: deltaX,
            deltaY: deltaY,
            shift: shift,
            hasViewport: hasViewport,
            hasCursor: hasCursor,
            cursorInsideViewport: cursorInsideViewport,
            isEditingText: isEditingText
        )
    }

    @Test func horizontalDominantPansByDeltaX() {
        #expect(GanttScrollRouter.decide(input(deltaX: 12, deltaY: 3)) == .pan(pixels: 12))
    }

    @Test func reverseSwipePansBackwards() {
        #expect(GanttScrollRouter.decide(input(deltaX: -9, deltaY: -2)) == .pan(pixels: -9))
    }

    /// 斜向手势：纵向分量更大时，横向分量**仍然生效**（横纵叠加，v1.3.6 起）。
    /// 纵向由调用方原样放行给滚动容器，两轴同时工作。
    @Test func diagonalGestureStillPansHorizontally() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 2, deltaY: 20))
                == .pan(pixels: 2)
        )
    }

    /// 纯纵向（无横向分量）不产生平移。
    @Test func pureVerticalScrollProducesNoPan() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 0, deltaY: 20))
                == .ignore(reason: .verticalOnly)
        )
    }

    @Test func shiftTurnsVerticalIntoHorizontal() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 0, deltaY: 18, shift: true))
                == .pan(pixels: 18)
        )
    }

    @Test func shiftWithoutVerticalDeltaIsNotHorizontal() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 0, deltaY: 0, shift: true))
                == .ignore(reason: .verticalOnly)
        )
    }

    @Test func unmeasuredCanvasIsIgnored() {
        // 视图还没上报视口/光标（挂载中或已卸载）时不得消费事件。
        #expect(
            GanttScrollRouter.decide(input(deltaX: 12, hasViewport: false))
                == .ignore(reason: .windowUnavailable)
        )
        #expect(
            GanttScrollRouter.decide(input(deltaX: 12, hasCursor: false))
                == .ignore(reason: .windowUnavailable)
        )
    }

    @Test func cursorOutsideViewportIsPassedThrough() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 12, cursorInsideViewport: false))
                == .ignore(reason: .outsideViewport)
        )
    }

    @Test func textEditingKeepsScroll() {
        #expect(
            GanttScrollRouter.decide(input(deltaX: 12, isEditingText: true))
                == .ignore(reason: .editingText)
        )
    }
}

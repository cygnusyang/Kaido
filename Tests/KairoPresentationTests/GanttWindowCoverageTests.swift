import Foundation
import Testing
import KairoPresentation

// D-040 / D-043 窗口覆盖度纯函数单测：外溢计数、侧别判定、边界取等与退化窗口。
// 边界语义（由 `GanttWindowCoverage.compute` 钉住）：条与窗口「相交且投影宽 > 0」
// 才算窗口内，因此右边缘正好落在 0、左边缘正好落在 windowWidth 的形状都算窗口外。

private func makeBar(
    rowIndex: Int = 0,
    x: Double,
    width: Double,
    kind: GanttBar.Kind = .task
) -> GanttBar {
    GanttBar(taskID: UUID(), rowIndex: rowIndex, x: x, width: width, kind: kind)
}

@Suite struct GanttWindowCoverageTests {
    private let windowWidth = 100.0

    @Test("全部条在窗口左侧之外 → 全外 + before")
    func allBefore() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: -60, width: 20),
                makeBar(rowIndex: 1, x: -30, width: 10),
                makeBar(rowIndex: 2, x: -200, width: 120),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 3)
        #expect(coverage.side == .before)
    }

    @Test("全部条在窗口右侧之外 → 全外 + after")
    func allAfter() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: 120, width: 30),
                makeBar(rowIndex: 1, x: 400, width: 10),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 2)
        #expect(coverage.side == .after)
    }

    @Test("两侧各有外溢 → 全外 + both")
    func bothSides() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: -50, width: 20),
                makeBar(rowIndex: 1, x: 20, width: 30),
                makeBar(rowIndex: 2, x: 150, width: 30),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 2)
        #expect(coverage.side == .both)
    }

    @Test("部分外溢：只算窗口外的条，侧别取外溢方向")
    func partiallyOutside() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: 10, width: 40),
                makeBar(rowIndex: 1, x: 30, width: 5),
                makeBar(rowIndex: 2, x: 140, width: 20),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 1)
        #expect(coverage.side == .after)
    }

    @Test("全部在窗口内 → 计数 0，侧别取确定值 both")
    func allInside() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: 0, width: 40),
                makeBar(rowIndex: 1, x: 50, width: 50),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 0)
        // 无方向可言时 side 恒为 .both：视图按计数 0 隐藏提示，不依赖侧别。
        #expect(coverage.side == .both)
    }

    @Test("边界取等：右边缘贴 0 / 左边缘贴 windowWidth 都算窗口外")
    func boundaryTouchingCountsAsOutside() {
        let rightEdgeAtZero = GanttWindowCoverage.compute(
            bars: [makeBar(x: -20, width: 20)],
            windowWidth: windowWidth
        )
        #expect(rightEdgeAtZero.offWindowCount == 1)
        #expect(rightEdgeAtZero.side == .before)

        let leftEdgeAtWidth = GanttWindowCoverage.compute(
            bars: [makeBar(x: windowWidth, width: 10)],
            windowWidth: windowWidth
        )
        #expect(leftEdgeAtWidth.offWindowCount == 1)
        #expect(leftEdgeAtWidth.side == .after)
    }

    @Test("边界内侧一格仍算窗口内")
    func justInsideKeepsVisible() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: -19, width: 20),
                makeBar(rowIndex: 1, x: windowWidth - 1, width: 10),
                makeBar(rowIndex: 2, x: 0, width: 10),
                makeBar(rowIndex: 3, x: 90, width: 10),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 0)
        #expect(coverage.side == .both)
    }

    @Test("空条集合 → 计数 0 + both")
    func emptyBars() {
        let coverage = GanttWindowCoverage.compute(bars: [], windowWidth: windowWidth)
        #expect(coverage.offWindowCount == 0)
        #expect(coverage.side == .both)
    }

    @Test("退化窗口（宽度 0 / 负数 / 非有限）→ 全部计为外溢")
    func degenerateWindow() {
        let bars = [
            makeBar(rowIndex: 0, x: -20, width: 20),
            makeBar(rowIndex: 1, x: 5, width: 10),
        ]
        for width in [0, -100, Double.nan, Double.infinity] {
            let coverage = GanttWindowCoverage.compute(bars: bars, windowWidth: width)
            #expect(coverage.offWindowCount == 2, "windowWidth=\(width)")
            #expect(coverage.side == .both, "windowWidth=\(width)")
        }
    }

    @Test("条类型不影响判定：群组与里程碑同规则")
    func kindDoesNotMatter() {
        let coverage = GanttWindowCoverage.compute(
            bars: [
                makeBar(rowIndex: 0, x: -40, width: 40, kind: .group),
                makeBar(rowIndex: 1, x: 150, width: 0, kind: .milestone),
            ],
            windowWidth: windowWidth
        )
        #expect(coverage.offWindowCount == 2)
        #expect(coverage.side == .both)
    }

    @Test("等值可比较：同输入两次计算相等")
    func equalityIsStable() {
        let bars = [makeBar(x: -10, width: 5)]
        #expect(
            GanttWindowCoverage.compute(bars: bars, windowWidth: windowWidth)
                == GanttWindowCoverage.compute(bars: bars, windowWidth: windowWidth)
        )
    }
}

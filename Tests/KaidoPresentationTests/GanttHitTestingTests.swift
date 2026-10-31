import Foundation
import Testing
import KaidoCore
import KaidoPresentation

// F-14-09 命中测试纯函数单测：覆盖设计稿 §1 命中区域表全分支、
// 三条类型适配（普通/里程碑/群组）、优先级、日粒度换算与兜底。

private let taskID = UUID()
private let dep0 = UUID()
private let dep1 = UUID()

private func makeBar(
    id: UUID = taskID,
    rowIndex: Int,
    x: Double,
    width: Double,
    kind: GanttBar.Kind = .task
) -> GanttBar {
    GanttBar(taskID: id, rowIndex: rowIndex, x: x, width: width, kind: kind)
}

@Suite struct GanttHitTestingTests {
    private let rowHeight = 28.0
    private let dayWidth = 10.0

    private func hit(
        _ x: Double,
        _ y: Double,
        offset: Double = 0,
        bars: [GanttBar],
        dependencies: [GanttDependency] = [],
        lanes: BaselineLaneLayout = BaselineLanes.layout(visibleCount: 0)
    ) -> GanttDragTarget {
        GanttHitTesting.hitTest(
            pointX: x, pointY: y, canvasOffset: offset,
            bars: bars, dependencies: dependencies,
            rowHeight: rowHeight, dayWidth: dayWidth,
            lanes: lanes
        )
    }

    // MARK: - 普通任务条：区域表全分支

    @Test func bodyHit() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        #expect(hit(150, 10, bars: bars) == .body(taskID))
    }

    @Test func startAndEndHandles() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        #expect(hit(103, 10, bars: bars) == .startHandle(taskID))
        #expect(hit(297, 10, bars: bars) == .endHandle(taskID))
    }

    @Test func narrowBarHandlesResolveToNearestEnd() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 8)]
        // 宽 8pt < 2×6：两端手柄区重叠，取更近的一端。
        #expect(hit(101, 10, bars: bars) == .startHandle(taskID))
        #expect(hit(107, 10, bars: bars) == .endHandle(taskID))
    }

    @Test func linkZones() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        #expect(hit(95, 10, bars: bars) == .dependencyStart(taskID))
        #expect(hit(305, 10, bars: bars) == .dependencyEnd(taskID))
        // 环带外为空白。
        #expect(hit(80, 10, bars: bars) == .none)
        #expect(hit(320, 10, bars: bars) == .none)
    }

    @Test func emptySpaceAndOtherRows() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        #expect(hit(50, 10, bars: bars) == .none)
        // 行下界之外（第二行无条）。
        #expect(hit(150, 40, bars: bars) == .none)
    }

    @Test func canvasOffsetShiftsRowHit() {
        let bars = [
            makeBar(id: dep0, rowIndex: 0, x: 100, width: 200),
            makeBar(id: dep1, rowIndex: 1, x: 100, width: 200),
        ]
        // 视口 y=10、滚动偏移 28 ⇒ 内容 y=38 ⇒ 第 1 行。
        #expect(hit(150, 10, offset: 28, bars: bars) == .body(dep1))
    }

    // MARK: - 里程碑 / 群组适配

    @Test func milestoneDegradesHandlesToBody() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 1, kind: .milestone)]
        // 菱形本体（有效宽 10pt）内一律算条体；端点手柄退化。
        #expect(hit(105, 10, bars: bars) == .body(taskID))
        #expect(hit(101, 10, bars: bars) == .body(taskID))
        // 环带仍可用（有效宽 10：起点 100、终点 110）。
        #expect(hit(95, 10, bars: bars) == .dependencyStart(taskID))
        #expect(hit(115, 10, bars: bars) == .dependencyEnd(taskID))
    }

    @Test func groupBarIsNotDraggableButLinks() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200, kind: .group)]
        #expect(hit(150, 10, bars: bars) == .none)
        #expect(hit(103, 10, bars: bars) == .none)
        // 可作依赖端点。
        #expect(hit(95, 10, bars: bars) == .dependencyStart(taskID))
        #expect(hit(305, 10, bars: bars) == .dependencyEnd(taskID))
    }

    // MARK: - 依赖线命中与优先级

    @Test func dependencyLineHitAndTolerance() {
        let dependency = GanttDependency(
            predecessorID: dep0, successorID: dep1,
            type: .fs,
            segments: [GanttSegment(startX: 0, startY: 50, endX: 300, endY: 50)]
        )
        #expect(hit(150, 50, bars: [], dependencies: [dependency]) == .dependencyLine(0))
        // 3pt 容差内命中，4pt 外不命中。
        #expect(hit(150, 53, bars: [], dependencies: [dependency]) == .dependencyLine(0))
        #expect(hit(150, 55, bars: [], dependencies: [dependency]) == .none)
    }

    @Test func dependencyLineTakesPriorityOverBar() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        // 线穿过条体所在行：命中线而非条。
        let dependency = GanttDependency(
            predecessorID: dep0, successorID: dep1,
            type: .fs,
            segments: [GanttSegment(startX: 0, startY: 14, endX: 300, endY: 14)]
        )
        #expect(hit(150, 14, bars: bars, dependencies: [dependency]) == .dependencyLine(0))
    }

    // MARK: - 日期换算

    @Test func dateAtXSnapsToDay() {
        let windowStart = makeDate(2025, 3, 10)
        #expect(GanttHitTesting.date(atX: 150, windowStart: windowStart, dayWidth: 10) == makeDate(2025, 3, 25))
        // 15.5 天四舍五入到 16 天（远离零）。
        #expect(GanttHitTesting.date(atX: 155, windowStart: windowStart, dayWidth: 10) == makeDate(2025, 3, 26))
    }

    @Test func daysFromTranslation() {
        #expect(GanttHitTesting.days(fromTranslationX: 55, dayWidth: 10) == 6)
        #expect(GanttHitTesting.days(fromTranslationX: -45, dayWidth: 10) == -5)
        // dayWidth=0 兜底 0.5（与 pannedWindowStart 同式）。
        #expect(GanttHitTesting.days(fromTranslationX: 1, dayWidth: 0) == 2)
    }

    @Test func distanceToDegenerateSegment() {
        let segment = GanttSegment(startX: 10, startY: 10, endX: 10, endY: 10)
        #expect(GanttHitTesting.distance(pointX: 13, pointY: 14, segment: segment) == 5)
    }

    // MARK: - v0.14 命中闸门：基线轨只读（设计稿 §10.9）

    // n=3 的分轨（§3 表）：计划轨 3…10、基线轨 11…15 / 16…20 / 21…25。
    private let lanes3 = BaselineLanes.layout(visibleCount: 3)

    @Test func baselineLanesMissForTaskBar() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        // 三条基线轨内、水平位置正落在条体上，也必须 miss。
        for y in [11.0, 13.0, 15.0, 16.0, 18.0, 20.0, 21.0, 23.0, 25.0] {
            #expect(hit(150, y, bars: bars, lanes: lanes3) == .none, "基线轨 y=\(y) 不应命中")
        }
        // 轨下留白同样 miss。
        #expect(hit(150, 27, bars: bars, lanes: lanes3) == .none)
    }

    @Test func planLaneStillHitsWithThreeBaselines() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        // 计划轨 3…10：x 方向语义不变（条体 / 端点 / 环带）。
        #expect(hit(150, 5, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(150, 3, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(150, 10, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(103, 6, bars: bars, lanes: lanes3) == .startHandle(taskID))
        #expect(hit(297, 6, bars: bars, lanes: lanes3) == .endHandle(taskID))
        #expect(hit(95, 6, bars: bars, lanes: lanes3) == .dependencyStart(taskID))
        #expect(hit(305, 6, bars: bars, lanes: lanes3) == .dependencyEnd(taskID))
    }

    @Test func groupLinkZonesGatedToPlanLane() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200, kind: .group)]
        // 计划轨内仍可作依赖端点（群组不可拖体）。
        #expect(hit(95, 5, bars: bars, lanes: lanes3) == .dependencyStart(taskID))
        #expect(hit(305, 5, bars: bars, lanes: lanes3) == .dependencyEnd(taskID))
        // 基线轨内连环带也不命中。
        #expect(hit(95, 13, bars: bars, lanes: lanes3) == .none)
        #expect(hit(150, 13, bars: bars, lanes: lanes3) == .none)
    }

    @Test func milestoneGatedToDiamondFrame() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 1, kind: .milestone)]
        // n=3：中心 y=6.5、边长 7 ⇒ 纵向窗口 3…10。
        #expect(hit(105, 3, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(105, 6, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(105, 10, bars: bars, lanes: lanes3) == .body(taskID))
        #expect(hit(105, 11, bars: bars, lanes: lanes3) == .none)
        #expect(hit(105, 14, bars: bars, lanes: lanes3) == .none)
    }

    @Test func zeroBaselinesKeepsLegacyWindow() {
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        // 默认值必须与显式 n=0 等价：任务条 7…21。
        #expect(hit(150, 7, bars: bars) == GanttDragTarget.body(taskID))
        #expect(hit(150, 7, bars: bars, lanes: BaselineLanes.layout(visibleCount: 0))
            == GanttDragTarget.body(taskID))
        #expect(hit(150, 21, bars: bars, lanes: BaselineLanes.layout(visibleCount: 0))
            == GanttDragTarget.body(taskID))
        // 行内计划轨之外（整行仍在本行）不再命中。
        #expect(hit(150, 25, bars: bars) == .none)
        #expect(hit(150, 2, bars: bars) == .none)
    }

    @Test func oneBaselineGatesToItsPlanLane() {
        let lanes1 = BaselineLanes.layout(visibleCount: 1)
        let bars = [makeBar(rowIndex: 0, x: 100, width: 200)]
        // n=1：计划轨 3…17，基线轨 19…25。
        #expect(hit(150, 17, bars: bars, lanes: lanes1) == .body(taskID))
        #expect(hit(150, 19, bars: bars, lanes: lanes1) == .none)
        #expect(hit(150, 25, bars: bars, lanes: lanes1) == .none)
    }

    private func makeDate(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.hour = 9
        return Calendar.current.date(from: components)!
    }
}

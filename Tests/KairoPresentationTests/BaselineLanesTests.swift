import Foundation
import Testing
import KairoPresentation

// v0.14 G2：行内分轨几何（docs/features/10-multi-baseline-gantt.md §3 表）。
//
// 锁定的口径：
// ① 表驱动：n = 0…3 的 计划轨 top / 计划轨高 / 基线轨高 / 各基线轨 top / 末端
//    与 §3 表逐项相等；n ≥ 1 末端恒 25，n = 0 末端 = 计划轨底边 21（行内居中，
//    上下各 7pt 留白，与 v0.13 现状一致）；
// ② n 越界夹取到 0…3（旧偏好可能存了 4+ 条）；
// ③ `planBarFrame` 轨内居中且高 = min(轨高, kind 高度)；`milestoneFrame` 边长 =
//    min(10, 轨高)，中心对齐轨中线；
// ④ n = 0 的几何必须逐位等于 v0.13 硬编码：任务 14pt @ y=7、群组 10pt @ y=9、
//    里程碑 10pt 中心 y=14（A7 黄金布局基准）。

/// §3 表的一行（期望值写字面量，不用被测函数现算，D-009）。
private struct ExpectedLane {
    let n: Int
    let planTop: Double
    let planHeight: Double
    let baselineHeight: Double
    let baselineTops: [Double]
    let endY: Double
}

private let table: [ExpectedLane] = [
    ExpectedLane(n: 0, planTop: 7, planHeight: 14, baselineHeight: 0, baselineTops: [], endY: 21),
    ExpectedLane(n: 1, planTop: 3, planHeight: 14, baselineHeight: 6, baselineTops: [19], endY: 25),
    ExpectedLane(n: 2, planTop: 3, planHeight: 9, baselineHeight: 5, baselineTops: [13.5, 20], endY: 25),
    ExpectedLane(n: 3, planTop: 3, planHeight: 7, baselineHeight: 4, baselineTops: [11, 16, 21], endY: 25)
]

@Suite("多基线分轨几何（v0.14）")
struct BaselineLanesTests {
    // MARK: - §3 表

    @Test func layoutMatchesDesignTable() {
        for expected in table {
            let layout = BaselineLanes.layout(visibleCount: expected.n)
            #expect(layout.plan.top == expected.planTop, "n=\(expected.n) plan.top")
            #expect(layout.plan.height == expected.planHeight, "n=\(expected.n) plan.height")
            #expect(layout.baselineHeight == expected.baselineHeight, "n=\(expected.n) baselineHeight")
            #expect(layout.baselineTops == expected.baselineTops, "n=\(expected.n) baselineTops")
            #expect(layout.endY == expected.endY, "n=\(expected.n) endY")
            // 基线条数与 lane 数一致：下标即 lane。
            #expect(layout.baselineTops.count == expected.n, "n=\(expected.n) lane count")
        }
    }

    /// n ≥ 1 时最后一轨底边恒 25：行间节奏不随显示条数变化。
    @Test func paintedLanesEndAtTwentyFiveWhenAnyBaselineVisible() {
        for expected in table where expected.n > 0 {
            let layout = BaselineLanes.layout(visibleCount: expected.n)
            let lastTop = layout.baselineTops.last ?? 0
            #expect(lastTop + layout.baselineHeight == 25, "n=\(expected.n)")
        }
    }

    /// 基线轨严格升序且互不重叠（同一条目不会跨轨压线）。
    @Test func baselineTopsAreAscendingAndNonOverlapping() {
        for expected in table {
            let layout = BaselineLanes.layout(visibleCount: expected.n)
            for (lane, top) in layout.baselineTops.enumerated() {
                if lane > 0 {
                    let previousBottom = layout.baselineTops[lane - 1] + layout.baselineHeight
                    #expect(top >= previousBottom, "n=\(expected.n) lane=\(lane) 轨重叠")
                }
                // 顺序轨道：车道 top 必须落在计划轨之下。
                #expect(top >= layout.plan.top + layout.plan.height, "n=\(expected.n) lane=\(lane)")
                // 不越出行高 28。
                #expect(top + layout.baselineHeight <= 28, "n=\(expected.n) lane=\(lane)")
            }
        }
    }

    @Test func visibleCountClampsOutOfRange() {
        #expect(BaselineLanes.layout(visibleCount: -5) == BaselineLanes.layout(visibleCount: 0))
        #expect(BaselineLanes.layout(visibleCount: 4) == BaselineLanes.layout(visibleCount: 3))
        #expect(BaselineLanes.layout(visibleCount: 99) == BaselineLanes.layout(visibleCount: 3))
    }

    @Test func maxVisibleIsThree() {
        #expect(BaselineLanes.maxVisible == 3)
    }

    // MARK: - n = 0 必须与 v0.13 逐像素一致（A7）

    @Test func zeroBaselinesKeepLegacyPlanBarGeometry() {
        let layout = BaselineLanes.layout(visibleCount: 0)
        let task = BaselineLanes.planBarFrame(kind: .task, layout: layout)
        #expect(task.top == 7)
        #expect(task.height == 14)
        let group = BaselineLanes.planBarFrame(kind: .group, layout: layout)
        #expect(group.top == 9)
        #expect(group.height == 10)
        let milestone = BaselineLanes.milestoneFrame(layout: layout)
        #expect(milestone.centerY == 14)
        #expect(milestone.side == 10)
    }

    // MARK: - 轨内居中与高度收缩

    @Test func planBarFrameCentersInsidePlanLane() {
        let cases: [(GanttBar.Kind, Double)] = [(.task, 14), (.group, 10), (.milestone, 14)]
        for expected in table {
            let layout = BaselineLanes.layout(visibleCount: expected.n)
            for (kind, naturalHeight) in cases {
                let frame = BaselineLanes.planBarFrame(kind: kind, layout: layout)
                let expectedHeight = min(layout.plan.height, naturalHeight)
                #expect(frame.height == expectedHeight, "n=\(expected.n) kind=\(kind)")
                #expect(
                    frame.top == layout.plan.top + (layout.plan.height - expectedHeight) / 2,
                    "n=\(expected.n) kind=\(kind) 未居中"
                )
                // 轨内始终装得下。
                #expect(frame.top >= layout.plan.top, "n=\(expected.n) kind=\(kind)")
                #expect(
                    frame.top + frame.height <= layout.plan.top + layout.plan.height,
                    "n=\(expected.n) kind=\(kind)"
                )
            }
        }
    }

    /// 3 条基线时计划轨高 7：任务条与群组条都被压到 7（群组不再更细，否则不可见）。
    @Test func threeBaselinesCompressPlanBarToLaneHeight() {
        let layout = BaselineLanes.layout(visibleCount: 3)
        #expect(BaselineLanes.planBarFrame(kind: .task, layout: layout).height == 7)
        #expect(BaselineLanes.planBarFrame(kind: .group, layout: layout).height == 7)
        #expect(BaselineLanes.planBarFrame(kind: .task, layout: layout).top == 3)
    }

    /// 2 条基线时计划轨高 9：群组仍 10 → 压到 9。
    @Test func twoBaselinesCompressGroupBarToNine() {
        let layout = BaselineLanes.layout(visibleCount: 2)
        #expect(BaselineLanes.planBarFrame(kind: .group, layout: layout).height == 9)
        #expect(BaselineLanes.planBarFrame(kind: .task, layout: layout).height == 9)
    }

    @Test func milestoneSideNeverExceedsTenAndStaysInLane() {
        for expected in table {
            let layout = BaselineLanes.layout(visibleCount: expected.n)
            let frame = BaselineLanes.milestoneFrame(layout: layout)
            #expect(frame.side == min(10, layout.plan.height), "n=\(expected.n)")
            #expect(frame.centerY == layout.plan.top + layout.plan.height / 2, "n=\(expected.n)")
            #expect(frame.centerY - frame.side / 2 >= layout.plan.top, "n=\(expected.n) 菱形出上界")
            #expect(
                frame.centerY + frame.side / 2 <= layout.plan.top + layout.plan.height,
                "n=\(expected.n) 菱形出下界"
            )
        }
        #expect(BaselineLanes.milestoneFrame(layout: BaselineLanes.layout(visibleCount: 3)).side == 7)
    }
}

// v0.14 G7：基线图层的两条查询（轨下标 + 轨内框）。
//
// 图层的口径难点在「某行缺某条基线条目」：轨位必须由 `visibleBaselineIDs` 决定，
// 不能按行内基线条数组的下标压缩，否则第 3 条会顶到第 2 条的轨上。
@Suite("基线图层轨位（v0.14）")
struct BaselineLaneSlotTests {
    private let a = UUID()
    private let b = UUID()
    private let c = UUID()

    @Test func laneIndexFollowsVisibleOrder() {
        let visible = [a, b, c]
        #expect(BaselineLanes.laneIndex(of: a, in: visible) == 0)
        #expect(BaselineLanes.laneIndex(of: b, in: visible) == 1)
        #expect(BaselineLanes.laneIndex(of: c, in: visible) == 2)
        // 不在可见集：不画（快照不会给出这种条，但视图侧不能错位顶替）。
        #expect(BaselineLanes.laneIndex(of: UUID(), in: visible) == nil)
        #expect(BaselineLanes.laneIndex(of: a, in: []) == nil)
    }

    /// 某行缺中间那条基线时，第 3 条仍留在第 3 轨（不压缩到第 2 轨）。
    @Test func missingMiddleBaselineKeepsRemainingLanes() {
        let visible = [a, b, c]
        let rowBaselineIDs = [a, c]
        let lanes = rowBaselineIDs.compactMap { BaselineLanes.laneIndex(of: $0, in: visible) }
        #expect(lanes == [0, 2])
    }

    @Test func baselineFrameMatchesLaneTops() throws {
        for n in 1...BaselineLanes.maxVisible {
            let layout = BaselineLanes.layout(visibleCount: n)
            for lane in 0..<n {
                let frame = try #require(layout.baselineFrame(lane: lane))
                #expect(frame.top == layout.baselineTops[lane], "n=\(n) lane=\(lane) top")
                #expect(frame.height == layout.baselineHeight, "n=\(n) lane=\(lane) height")
                // 轨必然在计划轨下方、且不越出行高（§2「基线恒在计划条下方」）。
                #expect(frame.top >= layout.plan.top + layout.plan.height, "n=\(n) lane=\(lane)")
                #expect(frame.top + frame.height <= 28, "n=\(n) lane=\(lane)")
            }
        }
    }

    /// 越界与无基线轨：返回 nil，调用方据此跳过（不硬取数组下标）。
    @Test func baselineFrameIsNilOutsideVisibleLanes() {
        #expect(BaselineLanes.layout(visibleCount: 0).baselineFrame(lane: 0) == nil)
        let three = BaselineLanes.layout(visibleCount: 3)
        #expect(three.baselineFrame(lane: 3) == nil)
        #expect(three.baselineFrame(lane: -1) == nil)
    }
}

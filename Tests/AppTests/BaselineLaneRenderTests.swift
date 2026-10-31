import Foundation
import SwiftUI
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

// v0.14 G7：甘特基线轨图层（离屏渲染验收，docs/features/10-multi-baseline-gantt.md §2）。
//
// 画面事实断言（不靠肉眼）：
// ① 3 条基线时，同一任务行的计划轨下方（§3 表 lane top = 11/16/21）各自画出细条，
//    颜色分别等于调色板 0/1/2 的浅色值，三条互不同色；
// ② 基线条不出行（28pt 下沿之外没有基线色）；
// ③ 全部隐藏（N = 0）时画面里一个基线色像素都不剩 —— 空态零改动的反向证据。
//
// 说明：整图像素差在本套件里只用在「有 / 无」量级判断上（> 0.002），因为同一状态
// 前后两次渲染之间会出现约 0.09% 的文本抗锯齿噪声，逐像素相等不成立；颜色计数与
// 定点取样不受该噪声影响，故结构性结论都走这两条。

/// 像素缓冲 → 画面坐标的取样器：`GUIRenderer` 直接 draw 进 CGBitmapContext，
/// 缓冲首行是画面顶部还是底部由绘制方向决定，故先用探针图定方向，不把结论写死。
@MainActor
private enum PixelProbe {
    /// 缓冲首行是画面顶部 → true（上红下蓝探针图的第 0 字节为红）。
    static let bufferIsTopDown: Bool = {
        let probe = VStack(spacing: 0) {
            Color.red.frame(width: 8, height: 8)
            Color.blue.frame(width: 8, height: 8)
        }
        guard let snapshot = GUIRenderer.snapshot(probe, width: 8, height: 16) else { return true }
        return Int(snapshot.pixels[0]) > Int(snapshot.pixels[2])
    }()

    /// 画面坐标（y 自顶部计）取像素 RGB。
    static func rgb(_ snapshot: RenderedSnapshot, x: Int, topY: Int) -> (r: Int, g: Int, b: Int) {
        let row = bufferIsTopDown ? topY : snapshot.height - 1 - topY
        return rgb(snapshot, x: x, bufferRow: row)
    }

    static func rgb(_ snapshot: RenderedSnapshot, x: Int, bufferRow: Int) -> (r: Int, g: Int, b: Int) {
        let base = (bufferRow * snapshot.width + x) * 4
        return (Int(snapshot.pixels[base]), Int(snapshot.pixels[base + 1]), Int(snapshot.pixels[base + 2]))
    }
}

@MainActor
@Suite("甘特基线轨渲染（v0.14）")
struct BaselineLaneRenderTests {
    private let width: CGFloat = 900
    private let height: CGFloat = 700
    /// 调色板 0/1/2 的浅色值（`DesignTokens.baselineLane0…2` 的 light 档）。
    private let paletteLight: [(r: Int, g: Int, b: Int)] = [
        (0x0E, 0x7C, 0x7C), (0xA8, 0x68, 0x00), (0x2E, 0x7D, 0x46)
    ]
    /// 取色容差：含抗锯齿边缘与色彩管理取整，纯色块中心实测偏差 ≤ 2。
    private let tolerance = 12

    private func makeStore() -> WorkspaceStore {
        let suite = "kaido.baseline-lane-render.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    /// 建 3 条基线（各自存下当前排期为条目）并全部设为「在甘特图中显示」。
    private func showThreeBaselines(_ store: WorkspaceStore) throws {
        for _ in 0..<3 {
            store.dispatch(.createBaseline(nil))
            let created = try #require(store.baselines.last)
            store.dispatch(.setBaselineVisible(created.id, true))
        }
    }

    private func renderCanvas(_ store: WorkspaceStore) throws -> RenderedSnapshot {
        let snapshot = store.snapshot
        let body = TimelineBody(
            store: store,
            rows: snapshot.outline.rows,
            gantt: snapshot.gantt,
            width: width,
            viewportHeight: height
        )
        return try #require(GUIRenderer.snapshot(body, width: width, height: height))
    }

    private func matchesPalette(_ pixel: (r: Int, g: Int, b: Int)) -> Int? {
        paletteLight.firstIndex { expected in
            abs(pixel.r - expected.r) <= tolerance
                && abs(pixel.g - expected.g) <= tolerance
                && abs(pixel.b - expected.b) <= tolerance
        }
    }

    /// 画面里等于任一基线色的像素个数。
    private func palettePixelCount(_ snapshot: RenderedSnapshot) -> Int {
        var count = 0
        for row in 0..<snapshot.height {
            for column in 0..<snapshot.width {
                if matchesPalette(PixelProbe.rgb(snapshot, x: column, bufferRow: row)) != nil { count += 1 }
            }
        }
        return count
    }

    /// 取样行：视口内的普通任务行，且三条基线都有足够宽的条 —— 返回每轨自己的取样 x。
    private func sampleRow(_ store: WorkspaceStore) throws -> (row: Int, xs: [Int]) {
        let gantt = store.snapshot.gantt
        for bar in gantt.bars where bar.kind == .task {
            let laneBars = gantt.baselineBars[bar.taskID] ?? []
            guard laneBars.count == 3, Double(bar.rowIndex + 1) * 28 <= Double(height) else { continue }
            var xs = [Int](repeating: -1, count: 3)
            var usable = true
            for laneBar in laneBars {
                guard let lane = BaselineLanes.laneIndex(
                    of: laneBar.baselineID, in: gantt.visibleBaselineIDs
                ), laneBar.width >= 8, laneBar.x >= 2, laneBar.x + 5 <= Double(width) - 2 else {
                    usable = false
                    break
                }
                xs[lane] = Int(laneBar.x) + 4
            }
            if usable { return (bar.rowIndex, xs) }
        }
        throw SampleError.noRow
    }

    private enum SampleError: Error { case noRow }

    // MARK: - 图层

    /// 三条基线轨都在计划轨下方，颜色 = 调色板 0/1/2，且三条互不同色。
    @Test func threeLanesPaintBelowPlanRailWithPaletteColors() throws {
        let store = makeStore()
        try showThreeBaselines(store)
        let gantt = store.snapshot.gantt
        #expect(gantt.visibleBaselineIDs.count == 3)
        #expect(gantt.baselineLanes.baselineTops == [11, 16, 21])

        let sample = try sampleRow(store)
        let rendered = try renderCanvas(store)
        let planRail = gantt.baselineLanes.plan

        for lane in 0..<3 {
            let laneTop = gantt.baselineLanes.baselineTops[lane]
            let laneMid = Double(sample.row) * 28 + laneTop + gantt.baselineLanes.baselineHeight / 2
            let pixel = PixelProbe.rgb(rendered, x: sample.xs[lane], topY: Int(laneMid.rounded()))
            #expect(matchesPalette(pixel) == lane, "lane \(lane) 取样得 \(pixel)，应为调色板 \(lane)")
            // 轨位在计划轨下方（§2「基线恒在计划条下方」）。
            #expect(laneTop >= planRail.top + planRail.height, "lane \(lane) 跑到计划轨上方")
        }
    }

    /// 基线条不越出行：行底（28pt 下沿）内外 1pt 都没有基线色。
    @Test func lanesStayInsideTheirRow() throws {
        let store = makeStore()
        try showThreeBaselines(store)
        let sample = try sampleRow(store)
        let rendered = try renderCanvas(store)
        let rowBottom = (sample.row + 1) * 28 - 1
        for lane in 0..<3 {
            let pixel = PixelProbe.rgb(rendered, x: sample.xs[lane], topY: rowBottom)
            #expect(matchesPalette(pixel) == nil, "第 \(sample.row) 行底出现 lane \(lane) 颜色 \(pixel)")
        }
    }

    /// N = 0：画布上一条基线色都不剩，且分轨几何回到 v0.13（layout(0)）。
    @Test func hidingAllBaselinesLeavesNoLanePixels() throws {
        let store = makeStore()
        let plain = try renderCanvas(store)
        #expect(palettePixelCount(plain) == 0, "无基线时画布不该出现基线色")

        try showThreeBaselines(store)
        let withLanes = try renderCanvas(store)
        // 至少三行 × 三条轨都该有实心像素（≥ 100 起步，远高于噪声量级）。
        #expect(palettePixelCount(withLanes) > 100)
        #expect(withLanes.differenceRatio(from: plain) > 0.002)

        for id in store.snapshot.gantt.visibleBaselineIDs {
            store.dispatch(.setBaselineVisible(id, false))
        }
        #expect(store.snapshot.gantt.baselineBars.isEmpty)
        #expect(store.snapshot.gantt.baselineLanes == BaselineLanes.layout(visibleCount: 0))
        let hidden = try renderCanvas(store)
        #expect(palettePixelCount(hidden) == 0, "隐藏全部基线后仍画出基线色")
    }
}

import AppKit
import CoreGraphics
import SwiftUI
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// D-033「大纲行点选不灵 + 列交界拖宽只在大纲表头可达」的回归用例（issue #13）。
//
// 三块契约：
//   ① 命中带口径：交界热区 ≥ 8pt（表头 6pt 实测抓不住），表头与行区域共用同一个常量；
//   ② 行区域交界带几何：与表头同一列右缘、内缩进列内、末列避开大纲/画布分界手柄、
//      聚焦标签栏不提供调宽、裁切到视口外的交界不出带；
//   ③ 拖拽握把：重排手势只挂在握把上（行本身只留 onDrop），握把落在无交互的序号列，
//      12–16pt 宽，不侵占状态列菜单。
//
// 手势仲裁本身（点击不再被拖拽接管）由「行不再注册 onDrag」从结构上保证，
// 单测只能锁几何与入口存在性；真人手感仍走验收 Demo。

@MainActor
@Suite("大纲行点选与列宽拖拽可达性（D-033）")
struct OutlineRowInteractionTests {
    private func layout(
        width: CGFloat,
        focused: Bool = false,
        overrides: [OutlineColumn: Double] = [:]
    ) -> OutlineColumnLayout {
        OutlineColumnLayout(
            columns: OutlineColumnPreferences.visibleColumns(
                outlineWidth: Double(width),
                hidden: [],
                focused: focused
            ),
            totalWidth: width,
            focused: focused,
            widthOverrides: overrides
        )
    }

    // MARK: - ① 命中带口径

    /// 交界热区下限 8pt：6pt 时用户「怎么也对不准」（D-033 实测）。
    @Test func resizeHotZoneIsWideEnoughToGrab() {
        #expect(OutlineColumnResizeMetrics.hotZone >= 8)
        // 提交阈值保持 2pt：小于它的位移算抖动，单击手柄不得写入粘滞宽度。
        #expect(OutlineColumnResizeMetrics.commitThreshold == 2)
    }

    /// 握把宽度 12–16pt：太窄抓不住，太宽会吃掉序号列。
    @Test func reorderGripWidthStaysInErgonomicRange() {
        #expect(OutlineReorderMetrics.gripWidth >= 12)
        #expect(OutlineReorderMetrics.gripWidth <= 16)
    }

    // MARK: - ② 行区域交界带几何

    /// 交界 x 落在列右缘：逐列累加宽度，顺序与列集合一致。
    @Test func boundariesSitOnColumnRightEdges() {
        let layout = layout(width: 480)
        let boundaries = layout.resizeBoundaries()
        // 480pt 时生效列：[status, violation, number, title, start, finish, progress]
        #expect(boundaries.map(\.column) == [.status, .violation, .number, .start, .finish, .progress])

        var expectedX: CGFloat = 0
        var cursor = 0
        for column in layout.columns {
            expectedX += layout.width(of: column)
            guard cursor < boundaries.count, boundaries[cursor].column == column else { continue }
            #expect(boundaries[cursor].x == expectedX, "\(column) 交界 x 应等于累加列宽")
            cursor += 1
        }
        #expect(cursor == boundaries.count)
    }

    /// 弹性列（任务说明）不参与调宽：表头与行区域都不出交界。
    @Test func titleColumnExposesNoBoundary() {
        let boundaries = layout(width: 480).resizeBoundaries()
        #expect(!boundaries.contains { $0.column == .title })
    }

    /// 聚焦标签栏没有调宽：交界面与表头手柄同时消失。
    @Test func focusedLayoutHasNoBoundaries() {
        #expect(layout(width: 480, focused: true).resizeBoundaries().isEmpty)
    }

    /// 热区内缩进列内（不超过列右缘），宽度正好等于 hotZone —— 与表头手柄同一口径。
    @Test func bandWidthMatchesHotZone() {
        for boundary in layout(width: 480).resizeBoundaries() where !boundary.isLast {
            #expect(boundary.band.upperBound == boundary.x)
            #expect(boundary.band.lowerBound == boundary.x - OutlineColumnResizeMetrics.hotZone)
        }
    }

    /// 末列右缘就是大纲/画布分界手柄：整带内缩一个热区，不与分界手柄抢热区。
    @Test func lastBoundaryStepsBackFromPaneSplitter() {
        let boundaries = layout(width: 480).resizeBoundaries()
        #expect(!boundaries.isEmpty)
        guard let last = boundaries.last else { return }
        #expect(last.isLast, "列集合末列才允许贴分界手柄")
        #expect(last.band.upperBound <= last.x - OutlineColumnResizeMetrics.hotZone)
    }

    /// 相邻交界带不重叠：否则拖一个列宽会命中另一个列。
    @Test func bandsDoNotOverlap() {
        let boundaries = layout(width: 480).resizeBoundaries()
        for (lhs, rhs) in zip(boundaries, boundaries.dropFirst()) {
            #expect(lhs.band.upperBound <= rhs.band.lowerBound, "\(lhs.column) 与 \(rhs.column) 的命中带重叠")
        }
    }

    /// 被裁到视口外的交界不生成命中带：列宽合计溢出大纲宽时右侧拖不到。
    @Test func boundariesOutsideViewportAreDropped() {
        let layout = layout(width: 600)   // 标题 120pt 下限使总宽 642 > 600
        let boundaries = layout.resizeBoundaries()
        #expect(boundaries.allSatisfy { $0.x <= layout.totalWidth })
        #expect(!boundaries.contains { $0.column == .progress }, "超出大纲宽的末列交界不可达")
    }

    /// 交界随用户覆盖值重算：拖宽某一列后，交界仍严格等于累加列宽。
    ///
    /// 大纲总宽固定、标题列吃余量，所以列宽变化被标题吸收，标题之后的交界位置不变；
    /// 会变的是标题列自身宽度。这里锁住这条不变量，避免将来把交界算成「默认宽累加」。
    @Test func boundariesFollowWidthOverrides() {
        let base = layout(width: 480)
        let widened = layout(width: 480, overrides: [.start: 120])
        #expect(widened.width(of: .start) == 120)
        #expect(widened.width(of: .title) < base.width(of: .title), "余量由标题列吸收")

        var expectedX: CGFloat = 0
        var cursor = 0
        let boundaries = widened.resizeBoundaries()
        for column in widened.columns {
            expectedX += widened.width(of: column)
            guard cursor < boundaries.count, boundaries[cursor].column == column else { continue }
            #expect(boundaries[cursor].x == expectedX, "\(column) 交界 x 应等于覆盖值累加")
            cursor += 1
        }
        #expect(cursor == boundaries.count)
    }

    // MARK: - ③ 拖拽握把

    /// 握把落在序号列左缘：序号格无交互（单击即选中），握把占它不损失任何操作；
    /// 状态列只有 18pt，覆盖它会让状态菜单点不到。
    @Test func dragGripSitsOnInertNumberColumn() {
        let layout = layout(width: 480)
        let expected = layout.width(of: .status) + layout.width(of: .violation)
        #expect(layout.dragGripOffset == expected)
    }

    /// 聚焦标签栏没有序号列：握把退回违例列左缘，仍不侵占状态列。
    @Test func dragGripFallsBackToViolationColumnWhenNumberHidden() {
        let layout = layout(width: 480, focused: true)
        #expect(layout.columns == [.status, .violation, .title])
        #expect(layout.dragGripOffset == layout.width(of: .status))
    }

    // MARK: - 端到端：拖宽 → 布局 → 复位

    /// 行区域交界带走的回调与表头同一条链路：提交后布局变宽，复位后回落默认宽。
    @Test func resizeRoundTripThroughStoreAndLayout() {
        let suite = "zeno.apptests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)

        func currentLayout() -> OutlineColumnLayout {
            var overrides: [OutlineColumn: Double] = [:]
            for (raw, width) in store.viewState.outlineColumnWidths {
                guard let column = OutlineColumn(rawValue: raw) else { continue }
                overrides[column] = width
            }
            return OutlineColumnLayout(
                columns: OutlineColumnPreferences.visibleColumns(
                    outlineWidth: 480, hidden: [], focused: false
                ),
                totalWidth: 480,
                focused: false,
                widthOverrides: overrides
            )
        }

        let defaultStart = currentLayout().width(of: .start)
        store.dispatch(.setOutlineColumnWidth(.start, 140))
        #expect(currentLayout().width(of: .start) == 140)
        #expect(currentLayout().width(of: .start) != defaultStart)

        store.dispatch(.setOutlineColumnWidth(.start, nil))
        #expect(currentLayout().width(of: .start) == defaultStart, "复位回落默认宽")
    }

    // MARK: - 不回归：列宽与列集合

    /// 加了交界覆盖层后行列表节距不变：总高仍严格等于 行数 × rowHeight（与画布对齐）。
    @Test func resizeOverlayKeepsRowPitch() throws {
        let suite = "zeno.apptests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)

        let rows = (0..<12).map { index in
            PlanRow(
                id: UUID(),
                depth: 0,
                outlineNumber: "\(index + 1)",
                kind: .task,
                title: "任务 \(index + 1)",
                status: .pending,
                priority: .normal
            )
        }
        let list = OutlineRowsList(
            store: store,
            rows: rows,
            layout: layout(width: 480),
            editingTaskID: .constant(nil),
            onResizeChanged: { _, _ in },
            onResizeEnded: { _ in },
            onResizeReset: { _ in }
        )

        let host = NSHostingView(rootView: list)
        host.sizingOptions = .intrinsicContentSize
        host.layoutSubtreeIfNeeded()

        let measured = try #require(host.intrinsicContentSize.height > 0 ? host.intrinsicContentSize.height : nil)
        #expect(measured == CGFloat(rows.count) * DesignTokens.rowHeight)
    }
}

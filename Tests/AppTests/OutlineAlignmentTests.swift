import AppKit
import SwiftUI
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

/// 大纲与画布纵向对齐回归：
/// 左列每行严格 `DesignTokens.rowHeight`（28pt），行列表总高必须等于行数 × 行高，
/// 与 `TimelineBody.contentHeight`（同一定义式）共用节距。历史上每行后多渲染一条
/// 占布局空间的 `Divider`，实际节距 ≈29pt，错位随行号线性累积（越往下越歪）。
@MainActor
@Suite("大纲纵向对齐")
struct OutlineAlignmentTests {
    /// 渲染 N 行后断言 Outline 行列表实测总高 == N × rowHeight == Timeline contentHeight。
    @Test func outlineRowsListHeightMatchesTimelinePitch() throws {
        let suiteName = "zeno.apptests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName) ?? .standard
        defaults.removePersistentDomain(forName: suiteName)
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: false)

        let rows = (0..<40).map { index in
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
        let layout = OutlineColumnLayout(
            columns: OutlineColumn.visibleColumns(outlineWidth: 480),
            totalWidth: 480,
            focused: false
        )
        let list = OutlineRowsList(
            store: store,
            rows: rows,
            layout: layout,
            editingTaskID: .constant(nil)
        )

        // 离屏布局（不进窗口）：intrinsicContentSize 按「不指定高度」的提案求值，
        // 返回 LazyVStack 的内容高度，即全部行的实际节距之和。
        let host = NSHostingView(rootView: list)
        host.sizingOptions = .intrinsicContentSize
        host.layoutSubtreeIfNeeded()

        let measured = try #require(host.intrinsicContentSize.height > 0 ? host.intrinsicContentSize.height : nil)
        let expected = CGFloat(rows.count) * DesignTokens.rowHeight
        // TimelineBody.contentHeight 定义即 CGFloat(rows.count) × rowHeight，此处直接断言同一定义式。
        #expect(measured == expected, "左列实测总高 \(measured) 应等于 行数×rowHeight \(expected)")
    }
}

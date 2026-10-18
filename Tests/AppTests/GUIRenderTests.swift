import Foundation
import SwiftUI
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// GUI 离屏渲染测试：`ImageRenderer` 无窗口渲染视图，按像素差异判断画面变化。
/// 视觉美观与真人操作手感仍需人工验收；本套件保证视图确实绘制内容，
/// 且模式、缩放、查找栏、命令面板与检查器页签会改变画面。
@MainActor
@Suite("GUI 离屏渲染")
struct GUIRenderTests {
    private enum Threshold {
        /// 内容增删（任务行、命令行）造成的最小画面差异。
        static let contentChange = 0.002
        /// 整块区域显隐（画布、面板、覆盖层）造成的最小画面差异。
        static let regionChange = 0.05
        /// 非空画面至少应出现的颜色数；纯色空白画面为 1。
        static let distinctColors = 20
    }

    private let defaultWidth: CGFloat = 1000
    private let defaultHeight: CGFloat = 700

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults)
    }

    private func makeWorkspace(_ store: WorkspaceStore) -> WorkspaceView {
        WorkspaceView(
            store: store,
            commands: KairoCommandCatalog.make(
                store: store,
                requestOpen: {},
                requestSave: {}
            )
        )
    }

    private func snapshot(
        _ view: some View,
        width: CGFloat? = nil,
        height: CGFloat? = nil
    ) throws -> RenderedSnapshot {
        try #require(
            GUIRenderer.snapshot(
                view,
                width: width ?? defaultWidth,
                height: height ?? defaultHeight
            )
        )
    }

    // MARK: - 工作台

    @Test func planModeRendersWorkspaceChrome() throws {
        let store = makeStore()
        let rendered = try snapshot(makeWorkspace(store))
        #expect(rendered.width == Int(defaultWidth))
        #expect(rendered.height == Int(defaultHeight))
        #expect(rendered.distinctColorCount > Threshold.distinctColors)
    }

    @Test func filterWithoutMatchesReplacesRowsWithEmptyState() throws {
        let store = makeStore()
        let populated = try snapshot(makeWorkspace(store))

        store.dispatch(.setFilter("zzz-nothing-matches"))
        let empty = try snapshot(makeWorkspace(store))

        #expect(populated.differenceRatio(from: empty) > Threshold.contentChange)
    }

    @Test func switchingToOutlineModeChangesRender() throws {
        let store = makeStore()
        let plan = try snapshot(makeWorkspace(store))

        store.dispatch(.setMode(.outline))
        let outline = try snapshot(makeWorkspace(store))

        #expect(outline.distinctColorCount > 10)
        #expect(plan.differenceRatio(from: outline) > Threshold.contentChange)
    }

    @Test func zoomLevelsRenderDistinctCharts() throws {
        let store = makeStore()
        store.dispatch(.setZoom(.day))
        let day = try snapshot(makeWorkspace(store))
        store.dispatch(.setZoom(.month))
        let month = try snapshot(makeWorkspace(store))

        #expect(day.differenceRatio(from: month) > Threshold.contentChange)
    }

    @Test func findBarChangesRenderWhenOpened() throws {
        let store = makeStore()
        let withoutBar = try snapshot(makeWorkspace(store))

        store.showFindBar = true
        let withBar = try snapshot(makeWorkspace(store))

        #expect(withBar.differenceRatio(from: withoutBar) > Threshold.contentChange)
    }

    // MARK: - 覆盖层与检查器

    @Test func commandPaletteOverlayChangesRender() throws {
        let store = makeStore()
        let base = try snapshot(makeWorkspace(store))

        store.showCommandPalette = true
        let palette = try snapshot(makeWorkspace(store))

        #expect(palette.distinctColorCount > 30)
        #expect(palette.differenceRatio(from: base) > Threshold.regionChange)
    }

    @Test func commandPaletteRowsDependOnCommandList() throws {
        let store = makeStore()
        let commands = KairoCommandCatalog.make(
            store: store,
            requestOpen: {},
            requestSave: {}
        )
        let populated = try snapshot(CommandPalette(commands: commands, onDismiss: {}))
        let empty = try snapshot(CommandPalette(commands: [], onDismiss: {}))

        // 遮罩层相同；差异只能来自命令行与「无匹配命令」空态。
        #expect(populated.differenceRatio(from: empty) > Threshold.contentChange)
    }

    @Test func inspectorTabAndLockChangeRender() throws {
        let store = makeStore()
        let backend = try #require(
            store.snapshot.outline.rows.first { $0.title == "实现搜索后端" }
        )
        store.dispatch(.select(backend.id))
        let taskTab = try snapshot(makeWorkspace(store))

        store.dispatch(.setInspectorTab(.violations))
        let violationsTab = try snapshot(makeWorkspace(store))
        #expect(taskTab.differenceRatio(from: violationsTab) > Threshold.contentChange)

        store.dispatch(.setInspectorVisible(false))
        let hidden = try snapshot(makeWorkspace(store))
        #expect(hidden.differenceRatio(from: violationsTab) > Threshold.contentChange)
    }
}

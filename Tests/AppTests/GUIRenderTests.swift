import Foundation
import SwiftUI
import Testing
import KairoCore
@testable import KairoMacApp

/// GUI 离屏渲染测试：`ImageRenderer` 无窗口渲染视图，按像素差异判断画面切换。
/// 视觉美观与真人操作手感仍需人工验收；本套件保证界面确实绘制了内容，
/// 且视图切换、缩放、平移、命令面板与违例面板会改变画面。
@MainActor
@Suite("GUI 离屏渲染")
struct GUIRenderTests {
    private let defaultWidth: CGFloat = 900
    private let defaultHeight: CGFloat = 600

    private func makeContentView(_ store: ProjectStore) -> ContentView {
        let find = FindModel()
        let commands = KairoCommandCatalog.make(
            store: store,
            find: find,
            requestOpen: {},
            requestSave: {}
        )
        return ContentView(
            store: store,
            find: find,
            commands: commands,
            deepLinkTaskID: .constant(nil)
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

    private func ganttView(
        _ store: ProjectStore,
        zoom: GanttZoom = .week,
        fitsToWidth: Bool = false,
        windowStart: Date? = nil
    ) -> GanttView {
        GanttView(
            tasks: store.project.tasks,
            schedule: store.schedule,
            selection: nil,
            violationIDs: [],
            onSelect: { _ in },
            initialZoom: zoom,
            fitsToWidth: fitsToWidth,
            initialWindowStart: windowStart
        )
    }

    // MARK: - 主界面

    @Test func outlineModeRendersTaskContent() throws {
        let shot = try snapshot(makeContentView(ProjectStore()))
        #expect(shot.width == 900)
        #expect(shot.height == 600)
        // 纯色空白画面只有 1 种颜色；大纲含标题、图标与控件。
        #expect(shot.distinctColorCount > 20)
    }

    @Test func switchingToGanttChangesRenderedContent() throws {
        let store = ProjectStore()
        let outline = try snapshot(makeContentView(store))

        store.viewMode = .gantt
        let gantt = try snapshot(makeContentView(store))

        #expect(gantt.distinctColorCount > 10)
        #expect(outline.differenceRatio(from: gantt) > 0.05)
    }

    @Test func findBarChangesRenderWhenOpened() throws {
        let store = ProjectStore()
        let withoutBar = try snapshot(makeContentView(store))

        store.showFindBar = true
        let withBar = try snapshot(makeContentView(store))

        #expect(withBar.differenceRatio(from: withoutBar) > 0.005)
    }

    // MARK: - 甘特视图（US-E4-04）

    @Test func ganttZoomLevelsRenderDistinctCharts() throws {
        let store = ProjectStore()
        let day = try snapshot(ganttView(store, zoom: .day), width: 800, height: 300)
        let week = try snapshot(ganttView(store, zoom: .week), width: 800, height: 300)
        let month = try snapshot(ganttView(store, zoom: .month), width: 800, height: 300)

        #expect(day.distinctColorCount > 20)
        #expect(day.differenceRatio(from: week) > 0.01)
        #expect(week.differenceRatio(from: month) > 0.01)
    }

    @Test func panningWindowStartChangesRenderedChart() throws {
        let store = ProjectStore()
        let base = try snapshot(ganttView(store, zoom: .week), width: 800, height: 300)
        let shifted = try snapshot(
            ganttView(
                store,
                zoom: .week,
                windowStart: Date().addingTimeInterval(7 * 86_400)
            ),
            width: 800,
            height: 300
        )
        #expect(base.differenceRatio(from: shifted) > 0.01)
    }

    // MARK: - 命令面板与违例面板（US-E4-05 / US-E4-07）

    @Test func commandPaletteOverlayChangesRender() throws {
        let store = ProjectStore()
        let base = try snapshot(makeContentView(store))

        store.showCommandPalette = true
        let palette = try snapshot(makeContentView(store))

        #expect(palette.distinctColorCount > 50)
        #expect(palette.differenceRatio(from: base) > 0.05)
    }

    @Test func violationsPanelAppearsWhenShown() throws {
        let store = ProjectStore()
        var release = try #require(store.project.tasks.first { $0.title == "发布 v1.0" })
        release.constraint = .endNoLaterThan(Date().addingTimeInterval(-86_400))
        store.update(release)
        #expect(!store.violations.isEmpty)

        let hidden = try snapshot(makeContentView(store))
        store.showViolations = true
        let shown = try snapshot(makeContentView(store))

        #expect(shown.differenceRatio(from: hidden) > 0.05)
    }
}

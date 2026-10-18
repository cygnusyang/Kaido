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
    private enum Threshold {
        /// 内容增删（任务行、命令行、违例行）造成的最小画面差异。
        static let contentChange = 0.01
        /// 整块区域显隐（甘特、面板、覆盖层）造成的最小画面差异。
        static let regionChange = 0.05
        /// 非空画面至少应出现的颜色数；纯色空白画面为 1。
        static let distinctColors = 20
    }

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

    @Test func outlineModeRendersInterfaceChrome() throws {
        let store = ProjectStore()
        let populated = try snapshot(makeContentView(store))
        #expect(populated.width == 900)
        #expect(populated.height == 600)
        #expect(populated.distinctColorCount > Threshold.distinctColors)
    }

    @Test func ganttDrawsTaskBarsFromTaskData() throws {
        let store = ProjectStore()
        let withBars = try snapshot(ganttView(store), width: 800, height: 300)
        // 负向对照：同样的甘特外壳、无任务与排期时不得出现任务条。
        // 大纲的 List 行由 AppKit 表格承载，`ImageRenderer` 不绘制其单元格，
        // 因而任务数据落图在纯 SwiftUI 绘制的甘特上验证。
        let empty = GanttView(
            tasks: [],
            schedule: nil,
            selection: nil,
            violationIDs: [],
            onSelect: { _ in },
            initialZoom: .week,
            fitsToWidth: false
        )
        let withoutBars = try snapshot(empty, width: 800, height: 300)
        #expect(withBars.distinctColorCount > Threshold.distinctColors)
        #expect(withBars.differenceRatio(from: withoutBars) > Threshold.contentChange)
    }

    @Test func switchingToGanttChangesRenderedContent() throws {
        let store = ProjectStore()
        let outline = try snapshot(makeContentView(store))

        store.viewMode = .gantt
        let gantt = try snapshot(makeContentView(store))

        #expect(gantt.distinctColorCount > 10)
        #expect(outline.differenceRatio(from: gantt) > Threshold.regionChange)
    }

    @Test func findBarChangesRenderWhenOpened() throws {
        let store = ProjectStore()
        let withoutBar = try snapshot(makeContentView(store))

        store.showFindBar = true
        let withBar = try snapshot(makeContentView(store))

        #expect(withBar.differenceRatio(from: withoutBar) > Threshold.contentChange)
    }

    // MARK: - 甘特视图（US-E4-04）

    @Test func ganttZoomLevelsRenderDistinctCharts() throws {
        let store = ProjectStore()
        let day = try snapshot(ganttView(store, zoom: .day), width: 800, height: 300)
        let week = try snapshot(ganttView(store, zoom: .week), width: 800, height: 300)
        let month = try snapshot(ganttView(store, zoom: .month), width: 800, height: 300)

        #expect(day.distinctColorCount > Threshold.distinctColors)
        #expect(day.differenceRatio(from: week) > Threshold.contentChange)
        #expect(week.differenceRatio(from: month) > Threshold.contentChange)
        #expect(day.differenceRatio(from: month) > Threshold.contentChange)
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
        #expect(base.differenceRatio(from: shifted) > Threshold.contentChange)
    }

    // MARK: - 命令面板与违例面板（US-E4-05 / US-E4-07）

    @Test func commandPaletteOverlayChangesRender() throws {
        let store = ProjectStore()
        let base = try snapshot(makeContentView(store))

        store.showCommandPalette = true
        let palette = try snapshot(makeContentView(store))

        #expect(palette.distinctColorCount > 50)
        #expect(palette.differenceRatio(from: base) > Threshold.regionChange)
    }

    @Test func commandPaletteRowsDependOnCommandList() throws {
        let store = ProjectStore()
        let find = FindModel()
        let commands = KairoCommandCatalog.make(
            store: store,
            find: find,
            requestOpen: {},
            requestSave: {}
        )
        let populated = try snapshot(CommandPalette(commands: commands, onDismiss: {}))
        let empty = try snapshot(CommandPalette(commands: [], onDismiss: {}))

        // 遮罩层相同；差异只能来自命令行与「无匹配命令」空态。
        #expect(populated.differenceRatio(from: empty) > Threshold.contentChange)
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
        #expect(shown.differenceRatio(from: hidden) > Threshold.regionChange)

        // 清除时限后同一面板内容改变，证明违例行确实由数据驱动。
        var cleared = release
        cleared.constraint = nil
        store.update(cleared)
        let emptyPanel = try snapshot(makeContentView(store))
        #expect(shown.differenceRatio(from: emptyPanel) > Threshold.contentChange)
    }
}

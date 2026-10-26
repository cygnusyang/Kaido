import Foundation
import SwiftUI
import Testing
import KairoCommands
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 项目设置面板的离屏渲染（F-22-06）：确认面板真的画出内容，
/// 且「自定义工作周」与「加一条例外日」这两个状态会改变画面——
/// 光有 store 侧断言看不出界面是否根本没接上草稿。
@MainActor
@Suite("项目设置面板渲染")
struct ProjectSettingsRenderTests {
    private let width: CGFloat = 620
    private let height: CGFloat = 560

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.settingsrender.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KairoFile.read(from: $0) }
        )
    }

    private func render(_ store: WorkspaceStore) throws -> RenderedSnapshot {
        try #require(
            GUIRenderer.snapshot(ProjectSettingsPanel(store: store), width: width, height: height)
        )
    }

    @Test func panelRendersItsContent() throws {
        let rendered = try render(makeStore())
        #expect(rendered.width == Int(width))
        #expect(rendered.height == Int(height))
        #expect(rendered.distinctColorCount > 10, "面板应画出图标、标题与分区卡片，而不是一片空白")
    }

    @Test func customWeekExposesWeekdayToggles() throws {
        let store = makeStore()
        let preset = try render(store)

        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: [2, 4, 6])))
        let custom = try render(store)

        // 自定义模板多出 7 个星期开关，画面必然不同（同一面板、同一尺寸）。
        #expect(custom.differenceRatio(from: preset) > 0.002)
    }

    @Test func exceptionListChangesTheRender() throws {
        let store = makeStore()
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))
        let empty = try render(store)

        store.dispatch(.setWorkCalendar(WorkCalendar(
            workingWeekdays: WorkCalendar.mondayToFriday,
            exceptions: [CalendarException(date: Date(), isWorking: false, note: "国庆")]
        )))
        let withException = try render(store)

        #expect(withException.differenceRatio(from: empty) > 0.002)
    }
}

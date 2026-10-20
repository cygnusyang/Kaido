import Foundation
import Testing
import KairoCore
import KairoCommands
import KairoPresentation
@testable import KairoMacApp

/// Sprint 7 技术债核销测试（D-012 / D-014 / D-016）。
@MainActor
@Suite("Sprint 7 技术债")
struct Sprint7DebtTests {
    private func makeDefaults(_ name: String) -> UserDefaults {
        let suite = "kairo.sprint7.\(name).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    // MARK: - D-012：偏好载入路径与写入口径对称（夹取 + 取整 0.1）

    @Test func loadedCustomDayWidthIsRoundedToTenth() throws {
        let defaults = makeDefaults("d012")
        let stored = """
        {
          "outlineWidth": 480, "outlineVisible": true, "expandedTaskIDs": [],
          "zoom": "week", "usesFitZoom": true, "customDayWidth": 12.34,
          "windowStart": null, "inspectorWidth": 320, "inspectorTab": "inspector"
        }
        """
        defaults.set(Data(stored.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults)
        // 写入路径提交值取整到 0.1：载入路径口径一致（12.34 → 12.3）。
        #expect(store.viewState.customDayWidth == 12.3)
    }

    @Test func loadedOutOfRangeCustomDayWidthStillClamped() throws {
        let defaults = makeDefaults("d012clamp")
        let stored = """
        {
          "outlineWidth": 480, "outlineVisible": true, "expandedTaskIDs": [],
          "zoom": "week", "usesFitZoom": true, "customDayWidth": 12.367,
          "windowStart": null, "inspectorWidth": 320, "inspectorTab": "inspector"
        }
        """
        defaults.set(Data(stored.utf8), forKey: WorkspaceStore.preferencesKey)
        let store = WorkspaceStore(defaults: defaults)
        #expect(store.viewState.customDayWidth == 12.4)
    }

    // MARK: - D-014：纯视图动作不再触发排期重算

    @Test func dayWidthCommitReusesScheduleCache() throws {
        let defaults = makeDefaults("d014")
        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)
        let session = store.sessionForTesting

        let afterOpen = session.scheduleComputeCount
        #expect(afterOpen >= 1, "打开后首次快照应已计算一次排期")

        store.dispatch(.setCustomDayWidth(20))
        store.dispatch(.setCustomDayWidth(24))
        store.dispatch(.nudgeCustomDayWidth(by: 1))
        #expect(
            session.scheduleComputeCount == afterOpen,
            "纯视图动作（日宽调整）不得触发排期重算（D-014）")

        // 数据写操作仍须置空缓存并重算。
        let leaf = try #require(store.exportProject.tasks.first { $0.kind == .task })
        store.dispatch(.setDuration(leaf.id, 3))
        #expect(session.scheduleComputeCount == afterOpen + 1, "任务数据变更应重算排期")
    }

    // MARK: - D-016：偏好逐字段容错解码

    @Test func missingSingleFieldKeepsOtherPreferences() throws {
        let defaults = makeDefaults("d016")
        // 删除 inspectorTab 字段：该字段回落默认，其余偏好完整保留（D-016 前
        // 行为是整体解码失败 → 全部回落）。
        let stored = """
        {
          "outlineWidth": 480, "outlineVisible": false, "expandedTaskIDs": [],
          "zoom": "day", "usesFitZoom": false,
          "windowStart": null, "inspectorWidth": 444
        }
        """
        defaults.set(Data(stored.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults)
        #expect(store.viewState.outlineWidth == 480)
        #expect(store.viewState.outlineVisible == false)
        #expect(store.viewState.zoom == .day)
        #expect(store.viewState.inspectorWidth == 444)
        #expect(store.viewState.inspectorTab == .inspector, "缺失字段回落默认")
    }

    @Test func corruptedFieldTypeDegradesGracefully() throws {
        let defaults = makeDefaults("d016type")
        // outlineWidth 类型错误（字符串）：该字段回落，其余保留。
        let stored = """
        {
          "outlineWidth": "not-a-number", "outlineVisible": true, "expandedTaskIDs": [],
          "zoom": "month", "usesFitZoom": false, "customDayWidth": 20,
          "windowStart": null, "inspectorWidth": 350, "inspectorTab": "inspector"
        }
        """
        defaults.set(Data(stored.utf8), forKey: WorkspaceStore.preferencesKey)

        let store = WorkspaceStore(defaults: defaults)
        #expect(store.viewState.outlineWidth == 600, "类型不符字段回落默认")
        #expect(store.viewState.zoom == .month)
        #expect(store.viewState.customDayWidth == 20)
    }
}

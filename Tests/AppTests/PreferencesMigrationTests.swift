import Foundation
import Testing
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 偏好迁移的应用层用例（D-045）：**按版本**迁移，不再用「版本相等」当门。
///
/// 为什么要这一组：相等门 `stored?.schema == currentPreferencesSchema` 的失效方式
/// 极其隐蔽——把常量从 2 改成 3，v2 用户的窗口偏好会被整块重置（自定义日宽被清、
/// 窗口跳回默认跨度），而改动看起来只是动了一个 Int。这里逐版本钉住「保留 / 重置」
/// 的分界，并用真实 store 走一遍「写偏好 JSON → 启动」的完整路径。
///
/// 本文件只能 CI 跑（AppTests 依赖 App target）；纯函数层的同一口径在
/// `Tests/KairoPresentationTests/PreferencesMigrationPlanTests.swift` 本地可验证。
@MainActor
@Suite("偏好迁移（D-045）")
struct PreferencesMigrationTests {
    /// 独立 UserDefaults suite：不依赖别人文件里的 private helper，用完即丢。
    private func makeDefaults(_ tag: String) -> UserDefaults {
        let suite = "kairo.apptests.migration.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func writePreferences(_ json: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: WorkspaceStore.preferencesKey)
    }

    /// 带窗口三项的偏好 JSON；`schema` 传 nil 表示「旧数据没有该键」（= v1）。
    private func windowPreferences(
        schema: Int?,
        zoom: String,
        usesFitZoom: Bool,
        customDayWidth: Double?
    ) -> String {
        let schemaLine = schema.map { "\"schema\": \($0)," } ?? ""
        let customLine = customDayWidth.map { "\"customDayWidth\": \($0)," } ?? ""
        return """
        {
          \(schemaLine)
          "outlineWidth": 600,
          "outlineVisible": true,
          "expandedTaskIDs": [],
          "zoom": "\(zoom)",
          "usesFitZoom": \(usesFitZoom),
          \(customLine)
          "inspectorWidth": 320,
          "inspectorTab": "inspector"
        }
        """
    }

    // MARK: - 常量与计划

    @Test func currentSchemaIsThree() {
        // v3 = 窗口宽度来源单一化（D-041）：结构未变，2 → 3 不重置窗口偏好。
        #expect(WorkspaceStore.currentPreferencesSchema == 3)
    }

    @Test func currentAndV2NeedNoMigrationSteps() {
        #expect(WorkspaceStore.migrationPlan(from: 2) == [])
        #expect(WorkspaceStore.migrationPlan(from: WorkspaceStore.currentPreferencesSchema) == [])
    }

    @Test func legacyVersionsResetWindowWidth() {
        // 无 schema 键（= v1）与显式 v1 都整块重置日宽三项。
        #expect(WorkspaceStore.migrationPlan(from: nil) == [.resetWindowWidth])
        #expect(WorkspaceStore.migrationPlan(from: 1) == [.resetWindowWidth])
    }

    @Test func migrationIsIdempotent() {
        for schema in [nil, 1, 2, 3] as [Int?] {
            let first = WorkspaceStore.migrationPlan(from: schema)
            let second = WorkspaceStore.migrationPlan(from: schema)
            #expect(first == second)
        }
    }

    // MARK: - v2 → v3 不重置（D-045 的核心）

    @Test func v2CustomDayWidthSurvivesUpgradeToV3() {
        let defaults = makeDefaults("v2custom")
        writePreferences(
            windowPreferences(schema: 2, zoom: "week", usesFitZoom: true, customDayWidth: 20),
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        // v2 已是修复后口径：升级到 v3 必须原样保留窗口偏好。
        #expect(store.viewState.customDayWidth == 20, "v2 的自定义日宽不得被升级清掉")
        #expect(store.viewState.windowSpanDays == nil, "有自定义日宽时不得注入默认跨度")
        #expect(store.viewState.widthMode == .custom(dayWidth: 20, base: .week))
        #expect(!store.viewState.usesFitZoom, "自定义日宽是唯一权威日宽")
    }

    @Test func v2WithoutCustomDayWidthStartsInDefaultSpan() {
        let defaults = makeDefaults("v2span")
        writePreferences(
            windowPreferences(schema: 2, zoom: "month", usesFitZoom: false, customDayWidth: nil),
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        #expect(store.viewState.widthMode == .span(
            days: WorkspaceViewState.defaultWindowSpanDays,
            base: .month
        ))
    }

    // MARK: - v1 整块重置（与上一条成对）

    @Test func v1WindowPreferencesAreDropped() {
        let defaults = makeDefaults("v1")
        // 无 schema 键 = v1：日宽三项都是非默认值，迁移后必须整块回默认。
        writePreferences(
            windowPreferences(schema: nil, zoom: "day", usesFitZoom: true, customDayWidth: 20),
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        #expect(store.viewState.customDayWidth == nil, "v1 的自定义日宽必须丢弃")
        #expect(store.viewState.zoom == .week, "档位回到默认")
        #expect(store.viewState.windowSpanDays == WorkspaceViewState.defaultWindowSpanDays)
        #expect(store.viewState.widthMode == .span(
            days: WorkspaceViewState.defaultWindowSpanDays,
            base: .week
        ))
    }

    @Test func foreignPreferencesSurviveEitherMigration() {
        let defaults = makeDefaults("foreign")
        writePreferences(
            windowPreferences(schema: nil, zoom: "day", usesFitZoom: true, customDayWidth: 20),
            to: defaults
        )

        let store = WorkspaceStore(defaults: defaults, seedsDemoData: true)

        // 迁移只碰窗口三项：其余偏好原样保留（此处 outlineWidth 仍是 JSON 里的 600）。
        #expect(store.viewState.outlineWidth == 600)
    }
}

import Foundation
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// v1.4.0 跨组验收用例（组 B：偏好迁移 / D-045）。
//
// 用户视角：升级到新版本之后，自定义日宽必须还在，窗口不能跳回 7 天跨度；
// 只有「真正没带 schema 的老数据」才允许整块重置窗口偏好。
//
// 为什么这里用字面量 2 而不是 WorkspaceStore.currentPreferencesSchema：
// 本用例要钉的是**历史数据**（上一版真实写出的 v2 JSON）。若跟随常量走，
// 常量提到 3 之后用例自动变成「v3 JSON 读 v3」——恰好绕过了要拦的那个回归（D-045）。

@MainActor
@Suite("V140 偏好迁移验收")
struct V140PreferenceMigrationAcceptanceTests {
    /// 每个用例独立偏好域，避免污染开发者真实配置、避免用例间互相影响。
    private func makeDefaults(_ tag: String) -> UserDefaults {
        let suite = "zeno.v140.\(tag).\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func writePreferences(_ json: String, to defaults: UserDefaults) {
        defaults.set(Data(json.utf8), forKey: WorkspaceStore.preferencesKey)
    }

    private var fixedNow: Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: 2026, month: 10, day: 30))!
    }

    /// 验收判据：v2 偏好（含 customDayWidth=20）升级后，自定义日宽保留、窗口不跳回 7 天跨度。
    ///
    /// `usesFitZoom: true` 是刻意留的陷阱：v2 的写盘口径里 fit 与 custom 可以同时为真，
    /// 载入侧必须让 custom 胜出，而不是被 fit / 跨度覆盖。
    @Test func V140SchemaTwoPreferencesKeepCustomDayWidth() {
        let defaults = makeDefaults("schema2")
        writePreferences(
            """
            {
              "schema": 2,
              "outlineWidth": 480,
              "expandedTaskIDs": [],
              "zoom": "day",
              "usesFitZoom": true,
              "customDayWidth": 20
            }
            """,
            to: defaults
        )

        let store = WorkspaceStore(now: fixedNow, defaults: defaults, seedsDemoData: false)

        #expect(store.viewState.customDayWidth == 20, "v2 的自定义日宽必须保留，不得被整块重置")
        #expect(store.viewState.windowSpanDays == nil, "有自定义日宽时不得再注入 7 天跨度")
        #expect(store.viewState.usesFitZoom == false, "自定义日宽与「适合项目」互斥，custom 胜出")
        // 用户可见的那一层：画布日宽读数就是 20，而不是「画布宽 / 7」。
        #expect(store.snapshot.gantt.dayWidth == 20, "画布日宽必须等于保留的自定义值")
    }

    /// 验收判据：无 schema（= v1 老数据）时窗口偏好整块重置为启动口径（7 天跨度）。
    @Test func V140LegacyPreferencesWithoutSchemaResetWindowWidthPreferences() {
        let defaults = makeDefaults("legacy")
        writePreferences(
            """
            {
              "outlineWidth": 480,
              "expandedTaskIDs": [],
              "zoom": "day",
              "usesFitZoom": true,
              "customDayWidth": 20
            }
            """,
            to: defaults
        )

        let store = WorkspaceStore(now: fixedNow, defaults: defaults, seedsDemoData: false)

        #expect(store.viewState.customDayWidth == nil, "v1 的自定义日宽必须重置")
        #expect(store.viewState.windowSpanDays == WorkspaceViewState.defaultWindowSpanDays,
                "v1 数据必须回到启动的 7 天跨度口径")
        #expect(store.snapshot.gantt.dayWidth != 20, "重置后不得残留旧自定义日宽")
        // 与窗口无关的偏好不受牵连（迁移只重置窗口三项）。
        #expect(store.viewState.outlineWidth == 480)
    }

    /// 验收判据（端到端）：窗口平移到全在未来的区间后，快照报告「有任务在窗口外」；
    /// 点「适合项目」之后归零——用户能据此把丢失的任务找回来。
    ///
    /// 只跑在 CI（本机缺 SwiftUIMacros，App target 不可编译）。
    @Test func V140OffWindowPromptClearsAfterFit() {
        let defaults = makeDefaults("offwindow")
        let store = WorkspaceStore(now: fixedNow, defaults: defaults, seedsDemoData: true)
        // 先把窗口挪到一年后：演示数据的条全部落在窗口左侧。
        let farFuture = Calendar.current.date(byAdding: .day, value: 365, to: fixedNow)!
        store.dispatch(.panWindow(to: farFuture))

        let panned = store.snapshot.gantt.offWindow
        #expect(panned.offWindowCount > 0, "全部条都在窗口外时必须有提示计数，不能让用户以为任务丢了")
        #expect(panned.side == .before, "窗口在内容右侧 ⇒ 条都在左边")
        // 画布这时应该一条都画不出来：提示是用户唯一能看到的信号。
        #expect(store.snapshot.gantt.bars.isEmpty, "窗口平移到未来后画布应为空（本用例的前提）")

        // 一键适应：窗口回到内容范围，提示必须归零（否则提示会永远挂着）。
        store.dispatch(.setFitZoom(true))
        let fitted = store.snapshot.gantt.offWindow
        #expect(fitted.offWindowCount == 0, "适合项目之后不应再有窗外的条")
        #expect(!store.snapshot.gantt.bars.isEmpty, "适合项目之后画布上应能看见条")
    }
}

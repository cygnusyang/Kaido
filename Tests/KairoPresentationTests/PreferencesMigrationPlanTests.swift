import Foundation
import Testing
import KairoCore
import KairoPresentation

/// 偏好迁移计划单测（D-045）：按版本推导、幂等、以及「v2 保留 / v1 重置」成对判据。
///
/// 纯函数层在这里跑（本地可验证）；`WorkspaceStore` 侧的同一口径另有一条 App 层用例
/// （`Tests/AppTests/PreferencesMigrationTests.swift`）钉常量与 store 的接线。
struct PreferencesMigrationPlanTests {
    private let spanDays = WorkspaceViewState.defaultWindowSpanDays

    // MARK: - 计划推导

    @Test func currentAndLegacyRepairedVersionsNeedNoMigration() {
        // v2 起已是修复后口径：升到 3、4 也不产生任何步骤（D-045 的核心）。
        #expect(PreferencesMigrationPlan.steps(from: 2) == [])
        #expect(PreferencesMigrationPlan.steps(from: 3) == [])
        #expect(PreferencesMigrationPlan.steps(from: 4) == [])
    }

    @Test func missingSchemaAndV1ResetWindowWidth() {
        #expect(PreferencesMigrationPlan.steps(from: nil) == [.resetWindowWidth])
        #expect(PreferencesMigrationPlan.steps(from: 1) == [.resetWindowWidth])
    }

    /// 幂等：同一输入重复推导得到同一份计划，不因调用次数累积步骤。
    @Test func planIsIdempotent() {
        for schema in [nil, 1, 2, 3] as [Int?] {
            #expect(PreferencesMigrationPlan.steps(from: schema)
                == PreferencesMigrationPlan.steps(from: schema))
        }
    }

    // MARK: - 折算成宽度来源

    /// v2（含自定义日宽）⇒ 自定义保留，不注入跨度（与 C13 成对）。
    @Test func v2CustomDayWidthSurvivesUpgrade() {
        let mode = PreferencesMigrationPlan.widthMode(
            zoom: .week,
            usesFitZoom: true,
            customDayWidth: 20,
            schema: 2,
            defaultSpanDays: spanDays
        )
        #expect(mode == .custom(dayWidth: 20, base: .week))
        #expect(mode.spanDays == nil)
    }

    /// 常量升版（v2 → v3）不得重置 v2 用户的窗口偏好：同一份 v2 输入在 v3 口径下
    /// 仍要得到同一个模式。
    @Test func v2AndV3ProduceSameMode() {
        let v2 = PreferencesMigrationPlan.widthMode(
            zoom: .month, usesFitZoom: false, customDayWidth: 18, schema: 2,
            defaultSpanDays: spanDays
        )
        let v3 = PreferencesMigrationPlan.widthMode(
            zoom: .month, usesFitZoom: false, customDayWidth: 18, schema: 3,
            defaultSpanDays: spanDays
        )
        #expect(v2 == v3)
    }

    /// v1：日宽三项整块回默认（默认档位 + 无自定义），窗口回到默认跨度。
    @Test func v1ResetsToDefaultSpan() {
        let mode = PreferencesMigrationPlan.widthMode(
            zoom: .month,
            usesFitZoom: true,
            customDayWidth: 20,
            schema: nil,
            defaultSpanDays: spanDays
        )
        #expect(mode == .span(days: spanDays, base: .week))
        #expect(mode.customDayWidth == nil)
        #expect(mode.baseZoom == WorkspaceViewState().zoom)
    }

    /// 没有自定义日宽时，启动一律回到跨度（锚今天），档位作为基准保留。
    @Test func noCustomDayWidthAlwaysStartsInSpan() {
        let mode = PreferencesMigrationPlan.widthMode(
            zoom: .day, usesFitZoom: true, customDayWidth: nil, schema: 3,
            defaultSpanDays: spanDays
        )
        #expect(mode == .span(days: spanDays, base: .day))
        #expect(mode.anchorsToday)
    }

    /// 幂等（折算层）：同一个迁移答案是「稳定态」——再喂回去不会变成别的模式。
    @Test func widthModeIsStableAcrossMigration() {
        let once = PreferencesMigrationPlan.widthMode(
            zoom: .week, usesFitZoom: false, customDayWidth: nil, schema: 3,
            defaultSpanDays: spanDays
        )
        let twice = PreferencesMigrationPlan.widthMode(
            zoom: once.baseZoom,
            usesFitZoom: once.isFit,
            customDayWidth: once.customDayWidth,
            schema: 3,
            defaultSpanDays: spanDays
        )
        #expect(once == twice)
    }
}

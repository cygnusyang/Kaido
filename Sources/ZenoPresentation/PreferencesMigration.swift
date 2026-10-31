import Foundation
import ZenoCore

/// 偏好迁移步骤（D-045）。
public enum PreferencesMigration: Hashable, Sendable {
    /// 日宽三项（档位 / 适合项目 / 自定义日宽）整块回默认。
    case resetWindowWidth
}

/// 偏好 schema 迁移计划（D-045）：**按版本**推导要做什么，不再拿「版本相等」当门。
///
/// 相等门（`stored?.schema == currentPreferencesSchema`）的代价：常量从 2 改成 3，
/// 所有 v2 用户的窗口偏好就被整块重置——自定义日宽被清、窗口跳回默认跨度，属可感知
/// 回归；而改动看起来只是动一个 Int。按版本推导后，升版本只表示「多了可迁移的版本」，
/// 已经迁移过的用户不受影响。
///
/// 本类型是纯函数集合：不读时钟、不读默认值容器、不碰环境变量，同一输入恒得同一结果
/// （`migrationPlan` 幂等 —— 重复调用不会累积出不同的计划）。
public enum PreferencesMigrationPlan {
    /// 窗口偏好开始「可信」的版本号：v2 起存的是启动跨度口径，可直接回放。
    public static let windowPreferencesVersion = 2

    /// 由存储的 schema 版本推导迁移计划。
    ///
    /// - `nil`（JSON 里没有 schema 键）/ 1：v1 存的是「内容起点 + 旧档位」口径的读数，
    ///   回放会把启动窗口拖回历史位置，日宽三项整块重置；
    /// - ≥ 2：已是修复后口径，**不产生任何步骤**（升到 3、4 也照此保留）。
    public static func steps(from schema: Int?) -> [PreferencesMigration] {
        // 无 schema 键即 v1（与载入侧「缺键 = 旧偏好」同口径）。
        let version = schema ?? 1
        return version >= windowPreferencesVersion ? [] : [.resetWindowWidth]
    }

    /// 迁移后的窗口宽度来源：启动态的完整答案（含启动跨度注入）。
    ///
    /// - Parameters:
    ///   - zoom / usesFitZoom / customDayWidth: 解码出的持久化三项。
    ///   - schema: 存储的 schema 版本；nil = 无键（v1）。
    ///   - defaultSpanDays: 启动跨度天数（单源常量 `WorkspaceViewState.defaultWindowSpanDays`）。
    ///   - customDayWidth: 已按提交口径归一化（夹取 + 取整 0.1）的自定义日宽。
    public static func widthMode(
        zoom: GanttZoom,
        usesFitZoom: Bool,
        customDayWidth: Double?,
        schema: Int?,
        defaultSpanDays: Int
    ) -> WindowWidthMode {
        let planned = steps(from: schema)
        if planned.contains(.resetWindowWidth) {
            // v1：整块回默认（默认档位 + 无自定义 + 无 fit），窗口照常按默认跨度注入。
            let fresh = WindowWidthMode.fromPersisted(
                zoom: WorkspaceViewState().zoom,
                usesFitZoom: false,
                customDayWidth: nil
            )
            return injectingDefaultSpan(defaultSpanDays, into: fresh)
        }
        let restored = WindowWidthMode.fromPersisted(
            zoom: zoom,
            usesFitZoom: usesFitZoom,
            customDayWidth: customDayWidth
        )
        return injectingDefaultSpan(defaultSpanDays, into: restored)
    }

    /// 启动窗口恒为固定跨度：只有自定义日宽能压过它。
    ///
    /// 两者并存会让「宽度取 custom、起点取跨度」两套口径叠在一起，重启后一清 custom
    /// 就突然变成跨度窗口；载入侧与 `setCustomDayWidth` 动作分支必须是同一条口径。
    private static func injectingDefaultSpan(
        _ days: Int,
        into mode: WindowWidthMode
    ) -> WindowWidthMode {
        guard mode.customDayWidth == nil else { return mode }
        return .span(days: days, base: mode.baseZoom)
    }
}

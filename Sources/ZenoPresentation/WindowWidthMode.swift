import Foundation
import ZenoCore

/// 窗口宽度来源（D-041）：日宽口径的**单一**权威。
///
/// 合并前它是四个各自可写的字段（`zoom` / `usesFitZoom` / `customDayWidth` /
/// `windowSpanDays`），正确性依赖每个动作分支「记得」把其余几个清干净——漏一个
/// 即静默失效（同一区域第三次回归）。枚举把互斥关系写进类型：自定义 + 跨度、
/// 适合项目 + 自定义这些矛盾态**不可表示**，动作分支只回答「现在是哪种模式」。
///
/// 读侧（呈现层 / 菜单 / 状态栏）只从这里取口径，不再各自重编码优先级。
public enum WindowWidthMode: Hashable, Sendable {
    /// 档位默认日宽（`GanttZoom.dayWidth`）。
    case preset(GanttZoom)
    /// 适合项目：日宽 = 画布宽 / 内容天数。
    case fit(GanttZoom)
    /// 自定义日宽（点/天，动作层已夹取）；`base` = 清掉自定义后回落的档位。
    case custom(dayWidth: Double, base: GanttZoom)
    /// 固定跨度窗口（天）：日宽 = 画布宽 / `days`；`base` 同上。
    ///
    /// 跨度不持久化：启动窗口恒由 `WorkspaceViewState.defaultWindowSpanDays` 重新注入。
    case span(days: Int, base: GanttZoom)

    /// 基准档位：非档位模式下也保留「退出后回到哪一档」。
    ///
    /// 与合并前的 `viewState.zoom` 同义——它一直是「预设档位」，不随自定义日宽改写。
    public var baseZoom: GanttZoom {
        switch self {
        case .preset(let zoom): return zoom
        case .fit(let zoom): return zoom
        case .custom(_, let base): return base
        case .span(_, let base): return base
        }
    }

    /// 自定义日宽（点/天）；非自定义模式为 nil。
    public var customDayWidth: Double? {
        if case .custom(let dayWidth, _) = self { return dayWidth }
        return nil
    }

    /// 固定跨度天数；非跨度模式为 nil。
    public var spanDays: Int? {
        if case .span(let days, _) = self { return days }
        return nil
    }

    /// 是否「适合项目」。
    public var isFit: Bool {
        if case .fit = self { return true }
        return false
    }

    /// 是否固定跨度。
    public var isSpan: Bool {
        if case .span = self { return true }
        return false
    }

    /// 窗口默认起点是否锚定今天。
    ///
    /// 自定义日宽与固定跨度是用户主动「盯当下」的两条路径，回落到内容起点会让打开旧项目
    /// 的人直接看不见今天（D-039 根因 A）；适合项目与档位维持内容起点（A7 冻结口径）。
    public var anchorsToday: Bool {
        switch self {
        case .custom, .span: return true
        case .preset, .fit: return false
        }
    }

    /// 关掉「适合项目」：`.fit` 退回同基准档位，其余模式原样返回。
    ///
    /// 平移这类「只挪窗口」的动作需要它：合并前的写法是 `usesFitZoom = false`，
    /// 在自定义 / 跨度模式下本来就是 no-op，语义要逐字保留。
    public var withoutFit: WindowWidthMode {
        if case .fit(let zoom) = self { return .preset(zoom) }
        return self
    }

    /// 退回档位模式（清掉自定义 / 退出跨度），基准档位不变。
    public var asPreset: WindowWidthMode { .preset(baseZoom) }

    // MARK: - 持久化

    /// 持久化形态：与 v1.3.4 偏好 JSON 的三项同键同义，旧版本可原样读回。
    public struct Persisted: Hashable, Sendable {
        /// 基准档位。
        public var zoom: GanttZoom
        /// 是否「适合项目」：只在没有自定义日宽时才有意义。
        public var usesFitZoom: Bool
        /// 自定义日宽（点/天）；nil = 无自定义。
        public var customDayWidth: Double?

        public init(zoom: GanttZoom, usesFitZoom: Bool, customDayWidth: Double?) {
            self.zoom = zoom
            self.usesFitZoom = usesFitZoom
            self.customDayWidth = customDayWidth
        }
    }

    /// 落盘口径：跨度不写（见 `.span` 的说明），自定义日宽原样带出。
    public var persisted: Persisted {
        Persisted(zoom: baseZoom, usesFitZoom: isFit, customDayWidth: customDayWidth)
    }

    /// 由持久化三项还原模式：自定义 > 适合项目 > 档位。
    ///
    /// 优先级与合并前逐项一致：自定义日宽是**唯一权威日宽**（`usesFitZoom` 同真时也让位），
    /// 状态栏档位同样先报 `custom`。
    ///
    /// - Parameter customDayWidth: 合法区间内的自定义日宽；越界归一化由调用方（动作层
    ///   `committedDayWidth`）完成，这里不做夹取，保证「读回什么就是什么」。
    public static func fromPersisted(
        zoom: GanttZoom,
        usesFitZoom: Bool,
        customDayWidth: Double?
    ) -> WindowWidthMode {
        if let customDayWidth {
            return .custom(dayWidth: customDayWidth, base: zoom)
        }
        return usesFitZoom ? .fit(zoom) : .preset(zoom)
    }
}

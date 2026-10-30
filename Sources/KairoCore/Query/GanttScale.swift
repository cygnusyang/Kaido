import Foundation

/// 甘特时间轴的日宽策略：单一标量日宽驱动全轴，刻度粒度由日宽推导。
///
/// 设计要点：
/// - 本类型只提供**策略与常量**，不改变 `GanttLayoutEngine` 的任何行为；
///   未启用自定义时，调用方传给核心的参数与现状完全一致（逐位一致门禁）。
/// - `tickUnit(forDayWidth:)` 只决定**刻度集合**，不参与任何 x 坐标计算，
///   因此不会破坏「每一天等宽、每一周等宽」的等比性不变式。
/// - 夹取只作用于**自定义路径**；「适合项目」的 fit 宽度不受夹取影响，
///   否则会改变既有 fit 路径的输出。
public enum GanttScale {
    /// 逐日标注的日宽阈值（点/天）。
    public static let dayTickThreshold: Double = 18
    /// 逐周标注的日宽阈值（点/天）；低于此值走逐月。
    public static let weekTickThreshold: Double = 6
    /// 自定义日宽的合法区间（点/天）。
    public static let dayWidthRange: ClosedRange<Double> = 2.0...120.0
    /// 键盘步进粒度（点/天）。
    public static let dayWidthStep: Double = 1.0
    /// 布局引擎的日宽下限（点/天）。
    ///
    /// 须与 `GanttLayoutEngine` 内部 `max(dayWidth, 0.5)` 的下限保持一致：
    /// 两侧共用同一常量，核心改下限时不会与调用方静默失配。
    public static let minimumDayWidth: Double = 0.5

    /// 夹取到合法区间；NaN → 下界，+∞ → 上界，−∞ → 下界。
    ///
    /// 夹取不做取整；取整由动作层在提交时完成（核心保持调用方给定的精度）。
    public static func clampDayWidth(_ value: Double) -> Double {
        if value.isNaN { return dayWidthRange.lowerBound }
        if value == .infinity { return dayWidthRange.upperBound }
        if value == -.infinity { return dayWidthRange.lowerBound }
        return min(max(value, dayWidthRange.lowerBound), dayWidthRange.upperBound)
    }

    /// 日宽滑杆的可用区间（D-042）：下界恒为 `dayWidthRange.lowerBound`，
    /// 上界取 `max(dayWidthRange.upperBound, dayWidth)`。
    ///
    /// 固定跨度窗口的日宽 = 画布宽 / 跨度：1024pt 画布、7 天窗口即 146.3 点/天，
    /// 已经超出档位滑杆的 120 上界。若滑杆仍按 120 封顶，读数写着 146.3 而滑杆停在
    /// 最右端，一拖就被夹回 120 并静默退出跨度模式。把上界放宽到「至少容得下当前值」
    /// 后，滑杆位置与读数在同一把尺子上。
    ///
    /// - Parameter dayWidth: 当前生效日宽；非有限值（NaN / ±∞）时返回默认区间，
    ///   不让一个坏读数把滑杆尺度撑成无穷。
    public static func sliderRange(forDayWidth dayWidth: Double) -> ClosedRange<Double> {
        guard dayWidth.isFinite else { return dayWidthRange }
        return dayWidthRange.lowerBound...max(dayWidthRange.upperBound, dayWidth)
    }

    /// 由日宽推导刻度档位（逐日 / 逐周 / 逐月）。
    ///
    /// 阈值取自标签可读性推导：逐日标签 ≈ 12.4pt 宽，逐周标签 ≈ 22.6pt 宽；
    /// 阈值同时与档位默认值自洽（32 → 逐日、12 → 逐周、5 → 逐月）。
    /// NaN 回落最粗粒度（逐月），避免被误判为逐日而放大绘制量；
    /// +∞ 视为最宽 → 逐日；−∞ 与 NaN 同处理（逐月）。
    public static func tickUnit(forDayWidth dayWidth: Double) -> GanttZoom {
        if dayWidth >= dayTickThreshold { return .day }
        if dayWidth >= weekTickThreshold { return .week }
        return .month
    }
}

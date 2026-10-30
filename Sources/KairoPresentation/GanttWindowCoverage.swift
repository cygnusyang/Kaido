import Foundation

/// 窗口外任务覆盖度（D-040 / D-043）。
///
/// 启动窗口锚今天：项目整体在过去、或大量任务落在当前窗口之外时，画布一片空白，
/// 用户无从判断「条去哪了」。本类型把「有多少条看不见、在窗口哪一侧」算成
/// 两个字节级的值，供视图给出提示与「适合项目」入口。
///
/// 纯函数 + 无视图依赖（ADR-013：几何判定进呈现层）。
public struct GanttWindowCoverage: Hashable, Sendable {
    /// 外溢方向：条相对可见窗口的位置。
    public enum Side: Hashable, Sendable {
        /// 外溢条全部在窗口左侧（任务早于窗口起点）。
        case before
        /// 外溢条全部在窗口右侧（任务晚于窗口终点）。
        case after
        /// 两侧各有外溢条。
        ///
        /// 同时是「没有外溢条」时的取值：`offWindowCount == 0` 时方向无从谈起，
        /// 这里取一个确定值而不是 `Optional`，让快照保持 `Hashable` 且调用方无需解包；
        /// 视图按 `offWindowCount > 0` 决定是否展示，不读该值。
        case both
    }

    /// 完全落在可见窗口之外的条数。
    public let offWindowCount: Int
    /// 外溢方向（`offWindowCount == 0` 时为 `.both`，见上）。
    public let side: Side

    public init(offWindowCount: Int, side: Side) {
        self.offWindowCount = offWindowCount
        self.side = side
    }

    /// 按条几何统计外溢。
    ///
    /// - Parameters:
    ///   - bars: 当前快照任务条（`x` / `width` 为画布内容坐标，单位点）。
    ///   - windowWidth: 可见窗口宽度（点）；退化值（0、负数、非有限）按 0 处理。
    /// - Returns: 外溢条数与方向。
    ///
    /// **边界取等**：只统计「与窗口相交且投影宽 > 0」的条，因此
    /// 右边缘正好落在 `x = 0`（`x + width <= 0`）或左边缘正好落在
    /// `x = windowWidth`（`x >= windowWidth`）的条都算窗口外——这两处都
    /// 只碰到边界线、一个像素也画不出来，算「在窗口内」会让提示在真正空白的
    /// 画面上消失。
    public static func compute(bars: [GanttBar], windowWidth: Double) -> Self {
        // 退化窗口（0 宽、负数、NaN / 无穷）：没有任何像素能显示条，全部计为外溢。
        // 画布不会给出这种宽度（`DesignTokens.canvasMinWidth` = 320），属防御性兜底。
        guard windowWidth.isFinite, windowWidth > 0 else {
            guard !bars.isEmpty else { return Self(offWindowCount: 0, side: .both) }
            let allBefore = bars.allSatisfy { $0.x + $0.width <= 0 }
            let allAfter = bars.allSatisfy { $0.x >= 0 }
            return Self(
                offWindowCount: bars.count,
                side: allBefore ? .before : (allAfter ? .after : .both)
            )
        }

        var before = 0
        var after = 0
        for bar in bars {
            if bar.x + bar.width <= 0 {
                before += 1
            } else if bar.x >= windowWidth {
                after += 1
            }
        }
        let side: Side
        if before > 0 && after > 0 {
            side = .both
        } else if before > 0 {
            side = .before
        } else if after > 0 {
            side = .after
        } else {
            side = .both
        }
        return Self(offWindowCount: before + after, side: side)
    }
}

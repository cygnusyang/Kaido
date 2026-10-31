import Foundation

/// 计划条自己占的那条轨：`top` 是行内绝对偏移（行顶 = 0），`height` 是轨高。
public struct BaselinePlanLane: Hashable, Sendable {
    public var top: Double
    public var height: Double

    public init(top: Double, height: Double) {
        self.top = top
        self.height = height
    }
}

/// 一行 28pt 内的分轨结果（v0.14 多基线，docs/features/10-multi-baseline-gantt.md §3）。
///
/// 轨自上而下依次为：计划轨 → 基线轨 0 → 基线轨 1 → 基线轨 2。行高不变、行节奏
/// 只在「显示几条基线」这一维变化：`n ≥ 1` 时最后一轨底边恒为 25pt，故滚动时
/// 行间空白一致。
public struct BaselineLaneLayout: Hashable, Sendable {
    public var plan: BaselinePlanLane
    /// 单条基线轨高；`n == 0` 时为 0（没有基线轨）。
    public var baselineHeight: Double
    /// 各基线轨的绝对偏移，升序，下标即 lane；`n == 0` 时为空。
    public var baselineTops: [Double]

    public init(plan: BaselinePlanLane, baselineHeight: Double, baselineTops: [Double]) {
        self.plan = plan
        self.baselineHeight = baselineHeight
        self.baselineTops = baselineTops
    }

    /// 已占用的轨底边：`n == 0` 为计划轨底边（21），`n ≥ 1` 恒为 25。
    ///
    /// 行高 28 不变，剩余空间是行内上下留白；调用方按此值排布，不自己再算一遍。
    public var endY: Double {
        baselineTops.last.map { $0 + baselineHeight } ?? (plan.top + plan.height)
    }
}

/// 行内分轨几何（纯函数，无 UI 依赖）。
///
/// 数值表与 `docs/features/10-multi-baseline-gantt.md` §3 逐项对应，**不要在该表之外
/// 调参**：`n == 0` 必须与 v0.13 现状逐像素一致（计划条 14pt @ y=7、群组 10pt @ y=9、
/// 里程碑菱形 10pt 中心 y=14），A7 黄金布局用例即以此为基准。
public enum BaselineLanes {
    /// 同屏显示的基线上限。视图状态归一化与「另有 N 条未显示」提示都读它，
    /// 不各自另写字面量。
    public static let maxVisible = 3

    /// §3 表的单行：计划轨位置 + 轨间间隙 + 基线轨高与条数。
    private struct Row {
        let planTop: Double
        let planHeight: Double
        let gap: Double
        let baselineHeight: Double
        let baselineCount: Int
    }

    /// 下标即可见基线数（0…3），与 §3 表逐项对应。
    ///
    /// | n | 计划轨 top | 计划轨高 | 轨间隙 | 基线轨高 | 基线轨 top | 末端 |
    /// | 0 | 7 | 14 | — | — | — | 21 |
    /// | 1 | 3 | 14 | 2 | 6 | 19 | 25 |
    /// | 2 | 3 | 9 | 1.5 | 5 | 13.5 / 20 | 25 |
    /// | 3 | 3 | 7 | 1 | 4 | 11 / 16 / 21 | 25 |
    private static let rows: [Row] = [
        Row(planTop: 7, planHeight: 14, gap: 0, baselineHeight: 0, baselineCount: 0),
        Row(planTop: 3, planHeight: 14, gap: 2, baselineHeight: 6, baselineCount: 1),
        Row(planTop: 3, planHeight: 9, gap: 1.5, baselineHeight: 5, baselineCount: 2),
        Row(planTop: 3, planHeight: 7, gap: 1, baselineHeight: 4, baselineCount: 3)
    ]

    /// 按可见基线数取分轨几何；`n` 越界夹取到 0…`maxVisible`
    /// （旧偏好可能存了 4+ 条，读取侧不各自夹取）。
    ///
    /// 基线轨偏移：`baselineTop(i) = plan.top + plan.height + gap + i × (baselineHeight + gap)`。
    public static func layout(visibleCount n: Int) -> BaselineLaneLayout {
        let row = rows[min(max(n, 0), maxVisible)]
        let tops = (0 ..< row.baselineCount).map { lane in
            row.planTop + row.planHeight + row.gap
                + Double(lane) * (row.baselineHeight + row.gap)
        }
        return BaselineLaneLayout(
            plan: BaselinePlanLane(top: row.planTop, height: row.planHeight),
            baselineHeight: row.baselineHeight,
            baselineTops: tops
        )
    }

    /// 计划条在计划轨内的框：轨内居中，高 = `min(轨高, kind 高度)`。
    ///
    /// `n == 0` 时退化为 v0.13 的硬编码：任务 14pt @ 7、群组 10pt @ 9。
    public static func planBarFrame(
        kind: GanttBar.Kind,
        layout: BaselineLaneLayout
    ) -> (top: Double, height: Double) {
        let height = min(layout.plan.height, naturalHeight(kind))
        let top = layout.plan.top + (layout.plan.height - height) / 2
        return (top, height)
    }

    /// 计划里程碑菱形在计划轨内的框：中心对齐轨中线，边长 = `min(10, 轨高)`。
    ///
    /// `n == 0` 时为 10pt 边长、中心 y=14（与 v0.13 一致）；`n == 3` 时轨高 7，
    /// 边长随之缩到 7，菱形仍完整落在轨内。
    public static func milestoneFrame(
        layout: BaselineLaneLayout
    ) -> (centerY: Double, side: Double) {
        (layout.plan.top + layout.plan.height / 2, min(10, layout.plan.height))
    }

    /// 各类型计划条的自然高度（v0.13 既有视觉，A7 基准）。
    private static func naturalHeight(_ kind: GanttBar.Kind) -> Double {
        switch kind {
        case .task, .milestone: return 14
        case .group: return 10
        }
    }
}

extension BaselineLaneLayout {
    /// 基线轨的行内纵向框（行顶 = 0）：top = `baselineTops[lane]`、height = `baselineHeight`。
    ///
    /// `lane` 越界或当前没有基线轨时返回 nil —— 调用方据此跳过该条，不自己用数组下标
    /// 硬取，也不拿 `baselineTops.count` 二次换算（§3 数值只此一处）。
    public func baselineFrame(lane: Int) -> (top: Double, height: Double)? {
        guard baselineTops.indices.contains(lane) else { return nil }
        return (baselineTops[lane], baselineHeight)
    }
}

extension BaselineLanes {
    /// 基线细条落在哪条轨：本条基线在 `visibleBaselineIDs` 中的下标；nil = 不在可见集，不画。
    ///
    /// 下标口径取自快照的 `visibleBaselineIDs`（创建顺序、只含真正画出条的基线），
    /// **不是**行内基线条数组的下标：某行缺某条基线条目时，其余基线仍留在自己那条轨上。
    public static func laneIndex(of baselineID: UUID, in visibleIDs: [UUID]) -> Int? {
        visibleIDs.firstIndex(of: baselineID)
    }
}

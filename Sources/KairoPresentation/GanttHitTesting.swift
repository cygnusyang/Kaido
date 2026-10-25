import Foundation

/// 甘特画布命中测试与几何换算（F-14-09 甘特图直接编辑）。
///
/// 全部为纯函数：输入画布坐标（内容坐标系，纵向含滚动偏移）与快照几何，
/// 输出拖拽目标或换算日期；视图层不做任何几何判断（ADR-013：逻辑进呈现层）。
/// 命中优先级：依赖线 > 端点 > 依赖环带 > 条体 > 空白（设计稿 §1 命中区域表）。
public enum GanttDragTarget: Equatable, Sendable {
    /// 拖条体改期。
    case body(UUID)
    /// 拖左端点改开始（end 不变，duration 随动）。
    case startHandle(UUID)
    /// 拖右端点改持续（start 不变）。
    case endHandle(UUID)
    /// 从条首端外环带拖出建依赖（拖到目标 B ⇒ B 是该任务的前驱）。
    case dependencyStart(UUID)
    /// 从条尾端外环带拖出建依赖（拖到目标 B ⇒ 该任务是 B 的前驱）。
    case dependencyEnd(UUID)
    /// 依赖线命中（`GanttDependency` 下标），供点选删除。
    case dependencyLine(Int)
    /// 空白。
    case none
}

public enum GanttHitTesting {
    /// 条端点内算手柄的容差（点）。
    public static let handleWidth: Double = 6
    /// 条端点外侧建依赖的环带宽度（点）。
    public static let linkZoneWidth: Double = 8
    /// 点到依赖线段算命中的距离容差（点）。
    public static let lineWidthTolerance: Double = 4
    /// 里程碑菱形的最小命中宽度（菱形本体 10pt）。
    static let milestoneHitWidth: Double = 10

    /// 画布命中测试。
    ///
    /// - Parameters:
    ///   - pointX/pointY: 视口内坐标；pointY 需加 `canvasOffset` 得到内容纵坐标。
    ///   - bars: 当前快照任务条（`rowIndex` 与大纲行对齐）。
    ///   - dependencies: 当前快照依赖线（含路由线段）。
    ///   - rowHeight: 行高（与 `DesignTokens.rowHeight` 一致）。
    ///   - dayWidth: 生效日宽（下限 0.5 兜底，与 `pannedWindowStart` 同式）。
    ///   - lanes: 行内分轨几何；默认 `n == 0`，即无基线轨时与 v0.13 逐像素一致。
    ///     基线轨只读（设计稿 §2/§10.9）：纵向窗口收敛到计划轨，落在基线轨内一律 `.none`，
    ///     因此基线细条既不能拖动、也不能作为建依赖的起点。
    public static func hitTest(
        pointX: Double,
        pointY: Double,
        canvasOffset: Double,
        bars: [GanttBar],
        dependencies: [GanttDependency],
        rowHeight: Double,
        dayWidth: Double,
        lanes: BaselineLaneLayout = BaselineLanes.layout(visibleCount: 0)
    ) -> GanttDragTarget {
        let contentY = pointY + canvasOffset
        let effectiveRowHeight = max(rowHeight, 1)
        let row = Int(contentY / effectiveRowHeight)

        // 1) 依赖线优先：逐依赖逐线段做点到折线距离测试。
        for (index, dependency) in dependencies.enumerated() {
            for segment in dependency.segments {
                let distance = Self.distance(
                    pointX: pointX,
                    pointY: contentY,
                    segment: segment
                )
                if distance <= lineWidthTolerance {
                    return .dependencyLine(index)
                }
            }
        }

        // 2) 行内条命中。
        guard row >= 0, let bar = bars.first(where: { $0.rowIndex == row }) else {
            return .none
        }
        // 纵向窗口：基线轨只读，计划轨（里程碑取菱形上下沿）之外一律算空白。
        // `n == 0` 时窗口为 v0.13 的整行内条高（任务 7…21、群组 9…19、里程碑 9…19），
        // 故既有命中用例不受影响。
        let window = verticalHitWindow(kind: bar.kind, lanes: lanes)
        let localY = contentY - Double(row) * effectiveRowHeight
        guard localY >= window.minY, localY <= window.maxY else { return .none }

        let effectiveWidth = bar.kind == .milestone
            ? max(bar.width, milestoneHitWidth)
            : max(bar.width, 1)
        let startX = bar.x
        let endX = bar.x + effectiveWidth

        // 3) 端点外环带（建依赖起点；先于条体判断，因为两者互斥不冲突）。
        if pointX < startX, startX - pointX <= linkZoneWidth {
            return .dependencyStart(bar.taskID)
        }
        if pointX > endX, pointX - endX <= linkZoneWidth {
            return .dependencyEnd(bar.taskID)
        }

        // 4) 条体内：端点手柄（里程碑与群组不提供手柄）与条体。
        guard pointX >= startX, pointX <= endX else { return .none }
        switch bar.kind {
        case .task:
            if pointX - startX <= handleWidth || endX - pointX <= handleWidth {
                // 窄条两端手柄区重叠时取更近的一端。
                return pointX - startX <= endX - pointX
                    ? .startHandle(bar.taskID)
                    : .endHandle(bar.taskID)
            }
            return .body(bar.taskID)
        case .milestone:
            // 里程碑仅拖改期；端点命中退化为条体。
            return .body(bar.taskID)
        case .group:
            // 群组聚合条由子任务推导，不可拖（仅可点选，命中空白由视图按行点选兜底）。
            return .none
        }
    }

    /// 条在行内的纵向命中窗口（行顶 = 0，绝对值）。
    ///
    /// 任务/群组取 `BaselineLanes.planBarFrame(kind:layout:)` 的框；里程碑取菱形
    /// `milestoneFrame(layout:)` 的 `centerY ± side / 2`。两者都由分轨几何推导，
    /// 本函数不另写数值——基线轨因此天然落在窗口之外。
    static func verticalHitWindow(
        kind: GanttBar.Kind,
        lanes: BaselineLaneLayout
    ) -> (minY: Double, maxY: Double) {
        switch kind {
        case .milestone:
            let frame = BaselineLanes.milestoneFrame(layout: lanes)
            return (frame.centerY - frame.side / 2, frame.centerY + frame.side / 2)
        case .task, .group:
            let frame = BaselineLanes.planBarFrame(kind: kind, layout: lanes)
            return (frame.top, frame.top + frame.height)
        }
    }

    /// x 坐标 → 日粒度吸附日期（日宽换算后四舍五入到整天）。
    public static func date(atX x: Double, windowStart: Date, dayWidth: Double) -> Date {
        let days = (x / max(dayWidth, 0.5)).rounded()
        return windowStart.addingTimeInterval(days * 86_400)
    }

    /// 拖拽位移 → 整日位移（方向与 `pannedWindowStart` 相反约定：此处为画布内容位移）。
    public static func days(fromTranslationX translationX: Double, dayWidth: Double) -> Int {
        Int((translationX / max(dayWidth, 0.5)).rounded())
    }

    /// 点到线段的最短距离（点）。
    public static func distance(
        pointX: Double,
        pointY: Double,
        segment: GanttSegment
    ) -> Double {
        let dx = segment.endX - segment.startX
        let dy = segment.endY - segment.startY
        let lengthSquared = dx * dx + dy * dy
        if lengthSquared < 0.0001 {
            let ex = pointX - segment.startX
            let ey = pointY - segment.startY
            return (ex * ex + ey * ey).squareRoot()
        }
        let t = max(0, min(1, ((pointX - segment.startX) * dx + (pointY - segment.startY) * dy) / lengthSquared))
        let ex = pointX - (segment.startX + t * dx)
        let ey = pointY - (segment.startY + t * dy)
        return (ex * ex + ey * ey).squareRoot()
    }
}

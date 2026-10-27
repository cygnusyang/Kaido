import Foundation
import KairoCore

// 平台中立快照（ADR-013）：不含颜色、字号与 SwiftUI 类型。
// SwiftUI 只消费这些值并映射到设计 token。

/// 大纲列（DESIGN.md §5.4 / ui-redesign.md §4.1）。
public enum OutlineColumn: String, Codable, Hashable, CaseIterable, Sendable {
    case status
    case violation
    case number
    case title
    case predecessors
    case start
    case finish
    /// 实际开始（F-0719）：可选列，默认隐藏；只读，无值显示占位符。
    case actualStart
    /// 实际结束（F-0719）：可选列，默认隐藏；复用 `TaskItem.completedAt`。
    case actualFinish
    /// 基线开始（v0.13）：可选列，默认隐藏；所选基线条目的承诺开始（08-baselines §4.2）。
    case baselineStart
    /// 基线结束（v0.13）：可选列，默认隐藏；排他端点，与 `finish` 同口径。
    case baselineFinish
    /// 计划开始偏差（v0.13）：`P.start − B.start`，日历天，正 = 比承诺晚。
    case startVariance
    /// 计划结束偏差（v0.13）：`P.finish − B.finish`，大纲主指标。
    case finishVariance
    case duration
    case assignee
    case progress

    /// 列宽（点）；`title` 为弹性列，返回最小宽度。
    public func width(bodyFontSize: Double) -> Double {
        let scale = max(bodyFontSize, 13) / 13
        switch self {
        case .status, .violation: return 18
        // 44：要放下「10.12」这类三级序号（30pt 会被截断成「10…」或换行）。
        // 这只是**无内容测量时的回退值**：应用层按当前项目最宽序号量宽后覆盖它（#48）。
        case .number: return 44
        case .title: return 160 * scale
        case .predecessors: return 96 * scale
        case .start, .finish, .actualStart, .actualFinish,
             .baselineStart, .baselineFinish: return 78 * scale
        // 偏差列按数字列口径：只放得下 `+3` / `-1` 这类读数。
        case .startVariance, .finishVariance, .duration: return 56 * scale
        case .assignee: return 76 * scale
        case .progress: return 72 * scale
        }
    }

    /// 列降级阈值（缩放后总宽的下界）。
    public static func visibleColumns(
        outlineWidth: Double,
        bodyFontSize: Double = 13
    ) -> [OutlineColumn] {
        let scale = max(bodyFontSize, 13) / 13
        let width = outlineWidth / scale
        var columns: [OutlineColumn] = [.status, .violation, .number, .title]
        if width >= 510 { columns.append(.predecessors) }
        if width >= 376 { columns.append(.start) }
        if width >= 454 { columns.append(.finish) }
        if width >= 510 { columns.append(.duration) }
        if width >= 586 { columns.append(.assignee) }
        columns.append(.progress)
        return columns
    }
}

/// 无排期原因（画布行内「未排期」提示）。
public enum UnscheduledReason: String, Codable, Hashable, Sendable {
    case cycle
    case emptyGroup
    case unavailable
}

/// 大纲与画布共用的一行（ADR-013）：同一任务在两处的行索引一致。
public struct PlanRow: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var depth: Int
    public var outlineNumber: String
    public var kind: TaskKind
    public var title: String
    public var status: TaskStatus
    public var priority: TaskPriority
    public var scheduledStart: Date?
    public var scheduledFinish: Date?
    /// 意图起点（`TaskItem.startDate`）：用户设置的最早开始日；`nil` = 未设置，
    /// 完全由自动排期决定。群组行为 `nil`（聚合口径只有排期结果）。
    public var startDate: Date?
    /// 实际开始（`TaskItem.actualStart`，F-0719）；群组行恒为 nil（不做子任务聚合）。
    public var actualStart: Date?
    /// 实际结束（复用 `TaskItem.completedAt`，F-0719）；群组行恒为 nil。
    public var actualFinish: Date?
    /// 所选基线的承诺开始（`B.start`，v0.13）；未选基线或无基线条目为 nil。
    public var baselineStart: Date?
    /// 所选基线的承诺结束（`B.finish`，排他端点）。
    public var baselineFinish: Date?
    /// 计划开始偏差 `P.start − B.start`（日历天，正 = 晚）；无条目/无排期为 nil（不写 0）。
    public var planStartVariance: Int?
    /// 计划结束偏差 `P.finish − B.finish`（大纲主指标），口径同 `planStartVariance`。
    public var planFinishVariance: Int?
    /// 是否存在基线条目：`false` = 基线之后新增（四列显示占位符，不显示 0）。
    public var hasBaseline: Bool
    public var durationDays: Double?
    public var assignee: String?
    /// 前置任务摘要（`A8FC:fs` / `A8FC:fs+1.5`，逗号分隔）；空串表示无前置。
    public var predecessorsText: String
    public var progress: Double
    public var isAggregate: Bool
    public var hasChildren: Bool
    public var isExpanded: Bool
    public var isOverdue: Bool
    public var deadlineRisk: Bool
    public var violationSeverity: Violation.Severity?
    public var violationCount: Int
    public var isCritical: Bool
    public var hasSchedule: Bool
    public var unscheduledReason: UnscheduledReason?
    public var isHighlighted: Bool

    /// - Parameter startDate: 意图起点；追加在参数表末尾并带默认值，既有构造点无需改动。
    public init(
        id: UUID,
        depth: Int,
        outlineNumber: String,
        kind: TaskKind,
        title: String,
        status: TaskStatus,
        priority: TaskPriority,
        scheduledStart: Date? = nil,
        scheduledFinish: Date? = nil,
        durationDays: Double? = nil,
        assignee: String? = nil,
        predecessorsText: String = "",
        progress: Double = 0,
        isAggregate: Bool = false,
        hasChildren: Bool = false,
        isExpanded: Bool = false,
        isOverdue: Bool = false,
        deadlineRisk: Bool = false,
        violationSeverity: Violation.Severity? = nil,
        violationCount: Int = 0,
        isCritical: Bool = false,
        hasSchedule: Bool = false,
        unscheduledReason: UnscheduledReason? = nil,
        isHighlighted: Bool = false,
        startDate: Date? = nil,
        actualStart: Date? = nil,
        actualFinish: Date? = nil,
        baselineStart: Date? = nil,
        baselineFinish: Date? = nil,
        planStartVariance: Int? = nil,
        planFinishVariance: Int? = nil,
        hasBaseline: Bool = false
    ) {
        self.id = id
        self.depth = depth
        self.outlineNumber = outlineNumber
        self.kind = kind
        self.title = title
        self.status = status
        self.priority = priority
        self.scheduledStart = scheduledStart
        self.scheduledFinish = scheduledFinish
        self.startDate = startDate
        self.actualStart = actualStart
        self.actualFinish = actualFinish
        self.baselineStart = baselineStart
        self.baselineFinish = baselineFinish
        self.planStartVariance = planStartVariance
        self.planFinishVariance = planFinishVariance
        self.hasBaseline = hasBaseline
        self.durationDays = durationDays
        self.assignee = assignee
        self.predecessorsText = predecessorsText
        self.progress = progress
        self.isAggregate = isAggregate
        self.hasChildren = hasChildren
        self.isExpanded = isExpanded
        self.isOverdue = isOverdue
        self.deadlineRisk = deadlineRisk
        self.violationSeverity = violationSeverity
        self.violationCount = violationCount
        self.isCritical = isCritical
        self.hasSchedule = hasSchedule
        self.unscheduledReason = unscheduledReason
        self.isHighlighted = isHighlighted
    }
}

/// 空态原因（界面据此给出具体出口，不出现空白区）。
public enum EmptyReason: String, Codable, Hashable, Sendable {
    case noTasks
    case noMatches
    case noSchedule
}

/// 大纲快照。
public struct OutlineSnapshot: Hashable, Sendable {
    public var rows: [PlanRow]
    public var columns: [OutlineColumn]
    /// 生效筛选的语义摘要（F-0718）；nil = 未启用筛选（纯文本或空输入）。
    /// 旧字段 `filterSummary: String?` 携带中文整句，已删除（快照零自然语言）。
    public var filterExplanation: FilterExplanation?
    public var emptyReason: EmptyReason?
    public var hiddenByCollapseCount: Int
    public var hiddenByFilterCount: Int

    public init(
        rows: [PlanRow],
        columns: [OutlineColumn],
        filterExplanation: FilterExplanation? = nil,
        emptyReason: EmptyReason? = nil,
        hiddenByCollapseCount: Int = 0,
        hiddenByFilterCount: Int = 0
    ) {
        self.rows = rows
        self.columns = columns
        self.filterExplanation = filterExplanation
        self.emptyReason = emptyReason
        self.hiddenByCollapseCount = hiddenByCollapseCount
        self.hiddenByFilterCount = hiddenByFilterCount
    }
}

/// 画布任务条（不含颜色；视图映射 GanttBarKind 到设计 token）。
public struct GanttBar: Identifiable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case task
        case group
        case milestone
    }

    public var id: UUID { taskID }
    public var taskID: UUID
    /// 与大纲一致的行索引。
    public var rowIndex: Int
    public var x: Double
    public var width: Double
    public var kind: Kind
    public var progress: Double
    public var isCritical: Bool
    public var isOverdue: Bool
    public var violationCount: Int
    public var isCollapsedGroup: Bool
    public var childCount: Int

    public init(
        taskID: UUID,
        rowIndex: Int,
        x: Double,
        width: Double,
        kind: Kind,
        progress: Double = 0,
        isCritical: Bool = false,
        isOverdue: Bool = false,
        violationCount: Int = 0,
        isCollapsedGroup: Bool = false,
        childCount: Int = 0
    ) {
        self.taskID = taskID
        self.rowIndex = rowIndex
        self.x = x
        self.width = width
        self.kind = kind
        self.progress = progress
        self.isCritical = isCritical
        self.isOverdue = isOverdue
        self.violationCount = violationCount
        self.isCollapsedGroup = isCollapsedGroup
        self.childCount = childCount
    }
}

/// 依赖线几何（阶段 3 生成；阶段 2 为空数组）。
public struct GanttSegment: Hashable, Sendable {
    public var startX: Double
    public var startY: Double
    public var endX: Double
    public var endY: Double

    public init(startX: Double, startY: Double, endX: Double, endY: Double) {
        self.startX = startX
        self.startY = startY
        self.endX = endX
        self.endY = endY
    }
}

public struct GanttDependency: Identifiable, Hashable, Sendable {
    public var id: String { "\(predecessorID)-\(successorID)" }
    public var predecessorID: UUID
    public var successorID: UUID
    public var type: TaskDependency.DependencyType
    public var isCritical: Bool
    public var segments: [GanttSegment]

    public init(
        predecessorID: UUID,
        successorID: UUID,
        type: TaskDependency.DependencyType,
        isCritical: Bool = false,
        segments: [GanttSegment] = []
    ) {
        self.predecessorID = predecessorID
        self.successorID = successorID
        self.type = type
        self.isCritical = isCritical
        self.segments = segments
    }
}

/// 刻度（阶段 2 为单级；阶段 3 增加上层月/年）。
public struct GanttTick: Identifiable, Hashable, Sendable {
    public var id: String { "\(date.timeIntervalSince1970)-\(label)" }
    public var date: Date
    public var x: Double
    public var label: String
    public var isMajor: Bool

    public init(date: Date, x: Double, label: String, isMajor: Bool) {
        self.date = date
        self.x = x
        self.label = label
        self.isMajor = isMajor
    }
}

/// 非工作带。
public struct GanttBand: Hashable, Sendable {
    public var x: Double
    public var width: Double

    public init(x: Double, width: Double) {
        self.x = x
        self.width = width
    }
}

/// 甘特图上的基线细条（v0.14 / docs/features/10-multi-baseline-gantt.md §7）。
///
/// 与 `GanttBar` 完全分离：基线不可变、不参与命中与拖拽，行索引仍由外层字典的
/// 任务 ID 给出（与大纲一致，ADR-013）。快照只带调色板索引，不带颜色值。
///
/// `lane` 不落在结构里：轨道 = 本条基线在 `GanttSnapshot.visibleBaselineIDs` 中的下标。
/// 这样某行缺某条基线的条目时，其余基线仍画在自己的轨上，不会上移串轨。
public struct GanttBaselineBar: Hashable, Sendable {
    public var baselineID: UUID
    /// 调色板索引 0…7；已按 `BaselinePalette.resolve` 只读派生（缺 / 越界 / 重复已归一）。
    public var colorIndex: Int
    /// 与计划条同一换算（`GanttLayoutEngine.x`），基线不可拖拽。
    public var x: Double
    /// 排他端点口径（`finish − start`）；里程碑为 0，由视图画菱形。
    public var width: Double
    public var isMilestone: Bool

    public init(baselineID: UUID, colorIndex: Int, x: Double, width: Double, isMilestone: Bool) {
        self.baselineID = baselineID
        self.colorIndex = colorIndex
        self.x = x
        self.width = width
        self.isMilestone = isMilestone
    }
}

/// 基线图例项（§4：图例不进画布，由状态栏 / 菜单按此顺序取色点与名称）。
public struct BaselineLegendItem: Identifiable, Hashable, Sendable {
    public var id: UUID { baselineID }
    public var baselineID: UUID
    /// 基线名（用户数据，原样带入快照，不做本地化）。
    public var name: String
    public var colorIndex: Int
    public var createdAt: Date

    public init(baselineID: UUID, name: String, colorIndex: Int, createdAt: Date) {
        self.baselineID = baselineID
        self.name = name
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }
}

/// 时间画布快照。
public struct GanttSnapshot: Hashable, Sendable {
    public var windowStart: Date
    public var windowEnd: Date
    public var contentStart: Date?
    public var contentEnd: Date?
    public var dayWidth: Double
    /// 用户预设档位（保持既有语义，不随自定义日宽改写）。
    public var zoom: GanttZoom
    /// 生效刻度档位：决定表头下层刻度密度与条标签显隐。
    /// 自定义日宽路径下由实际生效日宽推导（`GanttScale.tickUnit`）；
    /// 预设档位与「适合项目」沿用 `zoom`（与本功能引入前的行为逐位一致）。
    public var tickGranularity: GanttZoom
    public var usesFitZoom: Bool
    public var today: Date
    public var todayX: Double?
    public var todayOutOfRange: Bool
    public var bars: [GanttBar]
    public var dependencies: [GanttDependency]
    public var ticks: [GanttTick]
    public var bands: [GanttBand]
    public var emptyReason: EmptyReason?
    public var projectStartDerived: Bool
    /// 推导来源（决定提示措辞）：项目开始日期 / 最早任务 / 项目创建日期 / 今天。
    public var projectStartSource: ScheduleAnchor.Source
    public var showsCriticalPath: Bool
    public var showsBarLabels: Bool
    /// 已画出的基线细条，按任务 ID 分组（v0.14 / §7）。
    ///
    /// 只为「可见基线 ∩ 可见行上有条目」生成：收起 / 被筛选的行天然不在字典里。
    /// 无基线（或一条都画不出来）时为空字典 —— 视图据此走 N=0 的既有渲染。
    public var baselineBars: [UUID: [GanttBaselineBar]]
    /// 实际参与绘制的基线 ID，**创建顺序**，≤ `BaselineLanes.maxVisible`。
    ///
    /// 只有画出了至少一条基线的基线才在其中：读取侧归一化（悬挂 ID / 超过 3 条）
    /// 在 Presenter 完成，视图按此数组下标取轨道位置，不再自己夹取。
    public var visibleBaselineIDs: [UUID]
    /// 行内分轨几何；条数 = `visibleBaselineIDs.count`（0 时与 v0.13 逐像素一致，A7 基准）。
    public var baselineLanes: BaselineLaneLayout
    /// 图例项（与 `visibleBaselineIDs` 同序）。
    public var baselineLegend: [BaselineLegendItem]

    /// - Parameters:
    ///   - tickGranularity: 生效刻度档位；缺省时由 `zoom` 派生（保持旧构造点源码兼容）。
    ///   - baselineBars / visibleBaselineIDs / baselineLanes / baselineLegend: 多基线叠加
    ///     （v0.14）；缺省值即 N=0，既有构造点与断言零改动。
    public init(
        windowStart: Date,
        windowEnd: Date,
        contentStart: Date? = nil,
        contentEnd: Date? = nil,
        dayWidth: Double,
        zoom: GanttZoom,
        usesFitZoom: Bool,
        today: Date,
        todayX: Double?,
        todayOutOfRange: Bool,
        bars: [GanttBar] = [],
        dependencies: [GanttDependency] = [],
        ticks: [GanttTick] = [],
        bands: [GanttBand] = [],
        emptyReason: EmptyReason? = nil,
        projectStartDerived: Bool = false,
        projectStartSource: ScheduleAnchor.Source = .projectStart,
        showsCriticalPath: Bool = false,
        showsBarLabels: Bool = true,
        tickGranularity: GanttZoom? = nil,
        baselineBars: [UUID: [GanttBaselineBar]] = [:],
        visibleBaselineIDs: [UUID] = [],
        baselineLanes: BaselineLaneLayout = BaselineLanes.layout(visibleCount: 0),
        baselineLegend: [BaselineLegendItem] = []
    ) {
        self.windowStart = windowStart
        self.windowEnd = windowEnd
        self.contentStart = contentStart
        self.contentEnd = contentEnd
        self.dayWidth = dayWidth
        self.zoom = zoom
        self.tickGranularity = tickGranularity ?? zoom
        self.usesFitZoom = usesFitZoom
        self.today = today
        self.todayX = todayX
        self.todayOutOfRange = todayOutOfRange
        self.bars = bars
        self.dependencies = dependencies
        self.ticks = ticks
        self.bands = bands
        self.emptyReason = emptyReason
        self.projectStartDerived = projectStartDerived
        self.projectStartSource = projectStartSource
        self.showsCriticalPath = showsCriticalPath
        self.showsBarLabels = showsBarLabels
        self.baselineBars = baselineBars
        self.visibleBaselineIDs = visibleBaselineIDs
        self.baselineLanes = baselineLanes
        self.baselineLegend = baselineLegend
    }
}

import Foundation
import KairoCore

/// 视图模式（ADR-013）：计划工作台 / 全宽大纲。
public enum WorkspaceMode: String, Codable, Hashable, Sendable {
    case plan
    case outline
}

/// 检查器标签页。
public enum InspectorTab: String, Codable, Hashable, Sendable {
    case inspector
    case violations
}

/// 被撤销/查找等定位的目标状态。
public enum RevealStatus: String, Codable, Hashable, Sendable {
    case visible
    /// 因筛选隐藏，界面已临时显示并提示。
    case temporarilyShown
    /// 目标不存在（已删除或外部重载后缺失）。
    case missing
}

/// 视图状态（ADR-013）：不进入项目模型；可持久化的偏好与本次会话状态分开由应用层管理。
public struct WorkspaceViewState: Hashable, Sendable {
    public var mode: WorkspaceMode
    public var chartFocused: Bool
    /// 大纲列显示/隐藏；隐藏时时间画布占满主区。
    public var outlineVisible: Bool
    /// 用户偏好大纲宽度（320–640），夹取不回写。
    public var outlineWidth: Double
    public var expandedTaskIDs: Set<UUID>
    public var selectedTaskID: UUID?
    public var zoom: GanttZoom
    /// 为 true 时使用「适合项目」日宽，忽略 `zoom.dayWidth` 的绘制宽度。
    public var usesFitZoom: Bool
    /// 自定义每日宽度（点/天）；非 nil 时为**唯一权威日宽**，覆盖 `zoom.dayWidth`。
    /// 与 `usesFitZoom` 互斥（最后写入者胜）；呈现层再做一次防御（自定义优先）。
    /// 动作层写入时夹取到合法区间；呈现层再次夹取兜底。
    /// 本字段为 public 可变，外部直写可能越界 / NaN。
    public var customDayWidth: Double?
    /// 自定义窗口起点；nil 时由布局取内容起点或今天。
    public var windowStart: Date?
    public var inspectorVisible: Bool
    public var inspectorWidth: Double
    public var inspectorTab: InspectorTab
    /// 锁定为视图状态，不写入任务模型。
    public var inspectorLocked: Bool
    public var showCriticalPath: Bool
    public var showBarLabels: Bool
    /// 是否在时间轴上标出非工作日（周末带）。默认关闭 —— Kairo 按日历天排期，
    /// 「一周 7 天都算工作日」才与排期一致；需要对照周末时再打开（F-14-14 / #10）。
    public var showsNonWorkingDays: Bool = false
    /// 大纲列宽覆盖值（键 = `OutlineColumn.rawValue`，值 = 用户设定的点宽）。
    /// 缺键 = 该列按默认派生宽度；无覆盖值时布局与引入本字段前逐位一致。
    public var outlineColumnWidths: [String: Double] = [:]
    /// 用户隐藏的大纲列（键 = `OutlineColumn.rawValue`）。
    /// 序号/任务说明固定显示，隐藏请求不生效（见 `OutlineColumnPreferences`）。
    public var hiddenOutlineColumns: Set<String> = []
    public var filterText: String
    /// 查找/定位目标（只高亮跳转，不改变筛选）。
    public var highlightedTaskID: UUID?
    public var revealStatus: RevealStatus?

    public init(
        mode: WorkspaceMode = .plan,
        chartFocused: Bool = false,
        outlineVisible: Bool = true,
        outlineWidth: Double = 600,
        expandedTaskIDs: Set<UUID> = [],
        selectedTaskID: UUID? = nil,
        zoom: GanttZoom = .week,
        usesFitZoom: Bool = true,
        customDayWidth: Double? = nil,
        windowStart: Date? = nil,
        inspectorVisible: Bool = true,
        inspectorWidth: Double = 320,
        inspectorTab: InspectorTab = .inspector,
        inspectorLocked: Bool = false,
        showCriticalPath: Bool = false,
        showBarLabels: Bool = true,
        showsNonWorkingDays: Bool = false,
        filterText: String = "",
        highlightedTaskID: UUID? = nil,
        revealStatus: RevealStatus? = nil,
        outlineColumnWidths: [String: Double] = [:],
        hiddenOutlineColumns: Set<String> = []
    ) {
        self.mode = mode
        self.chartFocused = chartFocused
        self.outlineVisible = outlineVisible
        self.outlineWidth = outlineWidth
        self.expandedTaskIDs = expandedTaskIDs
        self.selectedTaskID = selectedTaskID
        self.zoom = zoom
        self.usesFitZoom = usesFitZoom
        self.customDayWidth = customDayWidth
        self.windowStart = windowStart
        self.inspectorVisible = inspectorVisible
        self.inspectorWidth = inspectorWidth
        self.inspectorTab = inspectorTab
        self.inspectorLocked = inspectorLocked
        self.showCriticalPath = showCriticalPath
        self.showBarLabels = showBarLabels
        self.showsNonWorkingDays = showsNonWorkingDays
        self.filterText = filterText
        self.highlightedTaskID = highlightedTaskID
        self.revealStatus = revealStatus
        self.outlineColumnWidths = outlineColumnWidths
        self.hiddenOutlineColumns = hiddenOutlineColumns
    }
}

/// 画布实际可用尺寸（由布局夹取后传入）。
public struct WorkspaceViewport: Hashable, Sendable {
    public var canvasWidth: Double
    public var canvasHeight: Double

    public init(canvasWidth: Double, canvasHeight: Double) {
        self.canvasWidth = canvasWidth
        self.canvasHeight = canvasHeight
    }
}

/// 保存状态（状态栏与项目页同源）。
public enum SaveState: String, Codable, Hashable, Sendable {
    case saved
    case unsaved
    case failed
}

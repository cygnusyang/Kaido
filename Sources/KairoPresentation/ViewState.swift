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
    /// 自定义窗口起点；nil 时由布局取内容起点或今天。
    public var windowStart: Date?
    public var inspectorVisible: Bool
    public var inspectorWidth: Double
    public var inspectorTab: InspectorTab
    /// 锁定为视图状态，不写入任务模型。
    public var inspectorLocked: Bool
    public var showCriticalPath: Bool
    public var showBarLabels: Bool
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
        windowStart: Date? = nil,
        inspectorVisible: Bool = true,
        inspectorWidth: Double = 320,
        inspectorTab: InspectorTab = .inspector,
        inspectorLocked: Bool = false,
        showCriticalPath: Bool = false,
        showBarLabels: Bool = true,
        filterText: String = "",
        highlightedTaskID: UUID? = nil,
        revealStatus: RevealStatus? = nil
    ) {
        self.mode = mode
        self.chartFocused = chartFocused
        self.outlineVisible = outlineVisible
        self.outlineWidth = outlineWidth
        self.expandedTaskIDs = expandedTaskIDs
        self.selectedTaskID = selectedTaskID
        self.zoom = zoom
        self.usesFitZoom = usesFitZoom
        self.windowStart = windowStart
        self.inspectorVisible = inspectorVisible
        self.inspectorWidth = inspectorWidth
        self.inspectorTab = inspectorTab
        self.inspectorLocked = inspectorLocked
        self.showCriticalPath = showCriticalPath
        self.showBarLabels = showBarLabels
        self.filterText = filterText
        self.highlightedTaskID = highlightedTaskID
        self.revealStatus = revealStatus
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

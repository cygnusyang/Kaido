import Foundation
import KairoCore

/// 状态栏快照（ADR-013 §3.3）：健康点、加权进度、计数、剩余天数与保存状态同源。
public struct StatusBarSnapshot: Hashable, Sendable {
    public var health: ProjectSummary.Health
    public var weightedProgress: Double
    public var overdueCount: Int
    public var violationErrorCount: Int
    public var violationWarningCount: Int
    public var criticalPathCount: Int
    public var remainingDays: Int?
    public var saveState: SaveState
    public var visibleStart: Date?
    public var visibleEnd: Date?
    public var todayVisible: Bool
    public var hiddenTaskCount: Int
    public var selectionSummary: String?
    public var zoomLabel: String
    /// 实际日宽读数（点/天），如 "12 点/天" / "12.5 点/天"；与 `zoomLabel` 配合展示。
    public var zoomDetail: String?

    public init(
        health: ProjectSummary.Health,
        weightedProgress: Double,
        overdueCount: Int,
        violationErrorCount: Int,
        violationWarningCount: Int,
        criticalPathCount: Int,
        remainingDays: Int?,
        saveState: SaveState,
        visibleStart: Date? = nil,
        visibleEnd: Date? = nil,
        todayVisible: Bool = false,
        hiddenTaskCount: Int = 0,
        selectionSummary: String? = nil,
        zoomLabel: String,
        zoomDetail: String? = nil
    ) {
        self.health = health
        self.weightedProgress = weightedProgress
        self.overdueCount = overdueCount
        self.violationErrorCount = violationErrorCount
        self.violationWarningCount = violationWarningCount
        self.criticalPathCount = criticalPathCount
        self.remainingDays = remainingDays
        self.saveState = saveState
        self.visibleStart = visibleStart
        self.visibleEnd = visibleEnd
        self.todayVisible = todayVisible
        self.hiddenTaskCount = hiddenTaskCount
        self.selectionSummary = selectionSummary
        self.zoomLabel = zoomLabel
        self.zoomDetail = zoomDetail
    }
}

/// 完整工作台快照。
public struct WorkspaceSnapshot: Hashable, Sendable {
    public var outline: OutlineSnapshot
    public var gantt: GanttSnapshot
    public var inspector: InspectorSnapshot
    public var statusBar: StatusBarSnapshot
    public var generatedAt: Date

    public init(
        outline: OutlineSnapshot,
        gantt: GanttSnapshot,
        inspector: InspectorSnapshot,
        statusBar: StatusBarSnapshot,
        generatedAt: Date
    ) {
        self.outline = outline
        self.gantt = gantt
        self.inspector = inspector
        self.statusBar = statusBar
        self.generatedAt = generatedAt
    }
}

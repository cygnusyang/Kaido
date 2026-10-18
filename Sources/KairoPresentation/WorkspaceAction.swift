import Foundation
import KairoCore

/// 视图动作（ADR-013）：视图只发出动作，不直接读写 `Project`。
/// 应用层 `WorkspaceStore` 负责把动作路由到 `KairoSession` 与视图状态。
public enum WorkspaceAction: Equatable, Sendable {
    // 选择与导航
    case select(UUID?)
    case reveal(UUID)
    case highlight(UUID?)
    case copyTaskLink(UUID)
    case toggleExpanded(UUID)
    case setExpanded(Set<UUID>)
    case setMode(WorkspaceMode)
    case toggleChartFocus
    case setZoom(GanttZoom)
    case setFitZoom(Bool)
    case panWindow(to: Date)
    case goToToday

    // 筛选
    case setFilter(String)

    // 显示开关
    case toggleCriticalPath
    case toggleBarLabels
    case setInspectorVisible(Bool)
    case setInspectorTab(InspectorTab)
    case setInspectorLocked(Bool)
    case setInspectorWidth(Double)
    case setOutlineWidth(Double)

    // 任务编辑（经会话）
    case createTask(parentID: UUID?, kind: TaskKind)
    case createSibling(after: UUID)
    case rename(UUID, String)
    case setStatus(UUID, TaskStatus)
    case setPriority(UUID, TaskPriority)
    case setNotes(UUID, String)
    case setProgress(UUID, Double)
    case setDueDate(UUID, Date?)
    case setAssignee(UUID, String?)
    case setDuration(UUID, Double?)
    case move(UUID, parentID: UUID?, index: Int)
    case indent(UUID)
    case outdent(UUID)
    /// 删除任务及其全部子任务；界面在存在子项时先确认。
    case delete(UUID)

    // 依赖
    case addDependency(
        taskID: UUID,
        predecessorID: UUID,
        type: TaskDependency.DependencyType,
        lagDays: Double
    )
    case removeDependency(taskID: UUID, predecessorID: UUID)

    // 项目元数据
    case setProjectTitle(String)
    case setProjectStart(Date?)
    case setProjectEnd(Date?)
    case setProjectDirection(ScheduleDirection)

    // 历史与文件
    case undo
    case redo
    case save
    case reloadExternal
    case keepLocal
}

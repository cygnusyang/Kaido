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
    /// 设定自定义日宽（内部夹取到 `GanttScale.dayWidthRange`）；进入自定义模式并退出「适合项目」。
    case setCustomDayWidth(Double)
    /// 相对步进自定义日宽（基准 = 当前生效日宽；fit 模式下以 fit 宽度为基准）。
    case nudgeCustomDayWidth(by: Double)
    /// 清除自定义日宽，回落到当前档位默认宽度（fit 开启时回落到 fit 宽度）。
    case clearCustomDayWidth
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
    case setOutlineVisible(Bool)
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
    /// 甘特画布直接编辑（F-14-09）：拖条改期（仅 startDate）/ 拖端点改持续
    /// （仅 durationDays）/ 拖左端（两者同时，end 不变）。视图层日粒度吸附后提交。
    case canvasEditSchedule(UUID, startDate: Date?, durationDays: Double?)
    /// 大纲「前置」列的人工输入：`任务ID[:fs|ff|ss|sf[:延隔]]`，逗号/空格分隔多项。
    case setPredecessors(UUID, String)
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

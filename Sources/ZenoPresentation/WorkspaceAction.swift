import Foundation
import ZenoCore

/// 视图动作（ADR-013）：视图只发出动作，不直接读写 `Project`。
/// 应用层 `WorkspaceStore` 负责把动作路由到 `ZenoSession` 与视图状态。
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
    /// 窗口整体落在排期区间之外时的「回到排期」（D-054）：只平移窗口起点，
    /// 不改宽度档位（宽度是用户的缩放选择），也不产生撤销点。
    ///
    /// 目标起点由 `GanttSchedulePlacement.returnStart` 按 `GanttSnapshot.navigation`
    /// 的侧别算出；入口不在排期之外时（导航为 nil 或 `.offWindow`）应用层不动状态。
    case returnToSchedule

    // 筛选
    case setFilter(String)

    // 显示开关
    case toggleCriticalPath
    case toggleBarLabels
    /// 标出非工作日（周末带）。默认关闭：Zeno 按日历天排期，一周 7 天都算工作日（#10）。
    case toggleNonWorkingDays
    case setInspectorVisible(Bool)
    case setInspectorTab(InspectorTab)
    case setInspectorLocked(Bool)
    case setInspectorWidth(Double)
    case setOutlineVisible(Bool)
    case setOutlineWidth(Double)
    /// 大纲单列宽度覆盖（F-14-20）：`nil` = 删除该列覆盖值（回落默认宽）；
    /// 非 `nil` 按 `OutlineColumnPreferences.widthRange` 夹取后写入。不改显隐。
    case setOutlineColumnWidth(OutlineColumn, Double?)
    /// 大纲列显隐切换（F-14-20）：序号/任务说明直接忽略；不产生撤销点。
    case toggleOutlineColumn(OutlineColumn)
    /// 大纲列顺序（v0.16 / #12）：拖拽表头重排后的完整顺序，或「重置列顺序」传入默认顺序。
    ///
    /// 固定列（序号 / 任务说明）不参与显隐但**可以**换位置；写入前由应用层归一化
    /// （去重 + 补齐缺失列），不产生撤销点、不置脏。
    case setOutlineColumnOrder([OutlineColumn])

    // 基线（v0.13 / 08-baselines §8）
    /// 切换对比基线：`nil` = 不比较；纯视图状态（不产生撤销点、不置脏、不写文件）。
    case setBaseline(UUID?)
    /// 对当前排期拍一次快照；`nil` 名称 = 默认名「基线 N · yyyy-MM-dd」。进撤销栈。
    case createBaseline(String?)
    /// 基线改名（只改名字，条目不可变）。进撤销栈。
    case renameBaseline(UUID, String)
    /// 删除基线：界面必须先二次确认（08 §11），确认后由应用层执行。
    case deleteBaseline(UUID)
    /// 甘特图显示 / 隐藏某条基线（v0.14 §6）：纯视图状态（不产生撤销点、不置脏、不写文件）。
    ///
    /// 已显示满 `BaselineLanes.maxVisible` 条时新增请求被拒绝（不替换、不插队），状态不变。
    case setBaselineVisible(UUID, Bool)
    /// 改基线颜色（v0.14 §4）：写 `Baseline.colorIndex` 并进撤销栈；索引越界由会话拒绝。
    case setBaselineColor(UUID, Int)

    // 任务编辑（经会话）
    case createTask(parentID: UUID?, kind: TaskKind)
    case createSibling(after: UUID)
    case rename(UUID, String)
    case setStatus(UUID, TaskStatus)
    /// 状态改为「已取消」（v0.16 D）：`reason` 必须是非空白文本。
    ///
    /// 与 `setStatus` 分开的原因：原因只属于该终态，请求必须带着它一起提交。
    /// 空白原因由应用层先拦（提示、不写库），会话层再兜一次
    /// `model_cancel_reason_required`；成功写入时按首尾去空白归一。
    case cancelTask(UUID, reason: String)
    case setPriority(UUID, TaskPriority)
    case setNotes(UUID, String)
    case setProgress(UUID, Double)
    case setDueDate(UUID, Date?)
    case setAssignee(UUID, String?)
    case setDuration(UUID, Double?)
    /// 「开始」字段：写 startDate（用户意图锚点，与画布拖条同一字段）。nil = 清除。
    case setTaskStart(UUID, Date?)
    /// 「实际开始」字段（F-0719）：写 TaskItem.actualStart；nil = 清除。
    case setActualStart(UUID, Date?)
    /// 「实际结束」字段（F-0719）：写 TaskItem.completedAt（实际结束复用该字段）；nil = 清除。
    case setActualFinish(UUID, Date?)
    /// 「结束」字段：finish 为排他端点；start 为本次换算采用的排期起点
    /// （视图传 scheduledStart ?? startDate，不自行做除法）。Store 折算后只写 durationDays。
    case setTaskFinish(UUID, finish: Date, start: Date)
    /// 甘特画布直接编辑（F-14-09）：拖条改期（仅 startDate）/ 拖端点改持续
    /// （仅 durationDays）/ 拖左端（两者同时，end 不变）。视图层日粒度吸附后提交。
    case canvasEditSchedule(UUID, startDate: Date?, durationDays: Double?)
    /// 切换排期方式：自动（依赖驱动）/ 手动（日期钉死）。
    case setSchedulingMode(UUID, TaskSchedulingMode)
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
    /// 项目工作日历（F-22-06）：整体替换（模板 / 每日工时 / 例外日都在这一个值里）。
    ///
    /// 传 `nil` = 等价「全周 7 天」：文件不写该键，排期与甘特渲染回到引入工作日历之前。
    /// 写入经会话快照恢复，进撤销栈（面板每一步可一步回退）。
    case setWorkCalendar(WorkCalendar?)
    /// 数据日期（v1.3 / 17-evm-status-date §2、§3）：`nil` = 未固定，每次查看按当天计算。
    ///
    /// 与工作日历同路径写入（进撤销栈、置脏）；写入前按项目日历归一到当日 00:00，
    /// 否则「同一天设两次」会得到不同时刻，PV 跟着小时漂移。
    case setStatusDate(Date?)

    // 历史与文件
    case undo
    case redo
    case save
    case reloadExternal
    case keepLocal
}

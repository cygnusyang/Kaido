import Foundation
import KairoCore

/// 依赖行（前置/后继只读列表）。
public struct DependencyRow: Identifiable, Hashable, Sendable {
    public var id: UUID { taskID }
    public var taskID: UUID
    public var title: String
    public var type: TaskDependency.DependencyType
    public var lagDays: Double
    public var isScheduled: Bool

    public init(
        taskID: UUID,
        title: String,
        type: TaskDependency.DependencyType,
        lagDays: Double,
        isScheduled: Bool
    ) {
        self.taskID = taskID
        self.title = title
        self.type = type
        self.lagDays = lagDays
        self.isScheduled = isScheduled
    }
}

/// 最近完成条目。
public struct CompletedTask: Identifiable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var completedAt: Date

    public init(id: UUID, title: String, completedAt: Date) {
        self.id = id
        self.title = title
        self.completedAt = completedAt
    }
}

/// 项目级基线面板（v0.13 / 08-baselines §5）。
///
/// 孤儿（条目在、任务已删）与「基线后新增」都收在这里，**不为它们插大纲行**——
/// 大纲行集合必须与任务树一致（ADR-013 行索引契约）。
public struct BaselinePanel: Hashable, Sendable {
    /// 孤儿条目：任务已删，只剩承诺时间，只读呈现在面板里。
    public struct OrphanEntry: Identifiable, Hashable, Sendable {
        public var id: UUID { taskID }
        public var taskID: UUID
        public var start: Date
        public var finish: Date

        public init(taskID: UUID, start: Date, finish: Date) {
            self.taskID = taskID
            self.start = start
            self.finish = finish
        }
    }

    public var baselineID: UUID
    public var name: String
    public var createdAt: Date
    /// 已删除任务对应的条目（按开始日升序，便于扫读）。
    public var orphans: [OrphanEntry]
    /// 基线之后新增的任务数（不计入项目偏差与平均值）。
    public var tasksWithoutBaseline: Int
    /// 已实际完成且晚于基线结束的任务数。
    public var lateTaskCount: Int
    /// 未完成且已过基线结束日的任务数。
    public var overdueOpenCount: Int
    /// 项目结束偏差 = 最晚 P.finish − 最晚 B.finish（不含孤儿）。
    public var projectFinishVariance: Int?

    public init(
        baselineID: UUID,
        name: String,
        createdAt: Date,
        orphans: [OrphanEntry] = [],
        tasksWithoutBaseline: Int = 0,
        lateTaskCount: Int = 0,
        overdueOpenCount: Int = 0,
        projectFinishVariance: Int? = nil
    ) {
        self.baselineID = baselineID
        self.name = name
        self.createdAt = createdAt
        self.orphans = orphans
        self.tasksWithoutBaseline = tasksWithoutBaseline
        self.lateTaskCount = lateTaskCount
        self.overdueOpenCount = overdueOpenCount
        self.projectFinishVariance = projectFinishVariance
    }
}

/// 项目页「与基线对比」区块（v0.15 / 09-baseline-version-plan §4）。
///
/// 与 `BaselineVarianceReport` 逐字段对应，只做字段改名与收口（孤儿明细不进这里，
/// 仍在 `BaselinePanel.orphans`），保证同一份报表在检查器与 CLI/MCP 上口径一致。
/// 正数 = 比承诺晚，负数 = 提前；空缺一律 nil，**不写 0**——0 是「准时」，与「没有数据」不是一回事。
public struct ProjectBaselineSummary: Hashable, Sendable {
    public var baselineID: UUID
    public var name: String
    public var createdAt: Date
    /// 项目结束偏差 = 最晚计划结束 − 最晚基线结束；任一侧无数据即 nil。
    public var finishVariance: Int?
    /// 已实际完成且晚于基线结束的任务数。
    public var lateTaskCount: Int
    /// 未完成且已过基线结束日的任务数。
    public var overdueOpenCount: Int
    /// 无基线条目数 = 基线之后新增（含基线时未排期）的任务数。
    public var tasksWithoutBaseline: Int
    /// 缺实际结束的已基线任务数：结束偏差按计划参与汇总时，这些是预测项而不是事实。
    public var predictedTaskCount: Int
    /// 已删除任务对应的条目数（明细见 `BaselinePanel.orphans`）。
    public var orphanCount: Int

    public init(
        baselineID: UUID,
        name: String,
        createdAt: Date,
        finishVariance: Int? = nil,
        lateTaskCount: Int = 0,
        overdueOpenCount: Int = 0,
        tasksWithoutBaseline: Int = 0,
        predictedTaskCount: Int = 0,
        orphanCount: Int = 0
    ) {
        self.baselineID = baselineID
        self.name = name
        self.createdAt = createdAt
        self.finishVariance = finishVariance
        self.lateTaskCount = lateTaskCount
        self.overdueOpenCount = overdueOpenCount
        self.tasksWithoutBaseline = tasksWithoutBaseline
        self.predictedTaskCount = predictedTaskCount
        self.orphanCount = orphanCount
    }
}

/// 项目页内容。
public struct ProjectInspector: Hashable, Sendable {
    public var title: String
    public var projectStart: Date?
    public var projectEnd: Date?
    public var direction: ScheduleDirection
    public var summary: ProjectSummary
    public var recentCompletions: [CompletedTask]
    public var saveState: SaveState
    /// 基线面板（v0.13）：未选基线时为 nil，整段不显示。孤儿明细在 `orphans`。
    public var baseline: BaselinePanel?
    /// 与基线对比（v0.15）：未选基线时为 nil，整段不显示。
    ///
    /// 与 `baseline` 同源同生命周期——两者都由同一份偏差报表派生，
    /// 后者只负责孤儿明细，数字一律以本字段为准。
    public var baselineSummary: ProjectBaselineSummary?
    /// 挣值块（v1.3 / 17-evm-status-date）：nil = 本次快照没有排期结果（项目尚无排期），
    /// 没有 PV 就没有读数——整块不显示，不画一排 0。
    public var earnedValue: EarnedValueSummary?

    public init(
        title: String,
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection,
        summary: ProjectSummary,
        recentCompletions: [CompletedTask] = [],
        saveState: SaveState,
        baseline: BaselinePanel? = nil,
        baselineSummary: ProjectBaselineSummary? = nil,
        earnedValue: EarnedValueSummary? = nil
    ) {
        self.title = title
        self.projectStart = projectStart
        self.projectEnd = projectEnd
        self.direction = direction
        self.summary = summary
        self.recentCompletions = recentCompletions
        self.saveState = saveState
        self.baseline = baseline
        self.baselineSummary = baselineSummary
        self.earnedValue = earnedValue
    }
}

/// 检查器基线段（v0.13 / 08-baselines §4.2、§8）。
///
/// 只在「已选对比基线且该任务有基线条目」时存在：无条目（基线后新增）整段不出现，
/// 由大纲列占位符 + 基线面板计数表达，不在检查器里塞一行「无数据」。
///
/// **两层偏差不对称是刻意的**（§4.3）：`planFinishVariance` 是预测层读数，
/// `actualFinishVariance` 是事实层读数；后者为空就是空，**不回落成 0，也不拿 plan 冒充 actual**。
public struct BaselineSection: Hashable, Sendable {
    public var baselineID: UUID
    /// 基线名（列头提示 / 检查器共用，§4.5 偏差必须带基线标识）。
    public var name: String
    /// 承诺开始（`B.start`）。
    public var start: Date
    /// 承诺结束（`B.finish`，排他端点）。
    public var finish: Date
    /// 计划结束偏差 `P.finish − B.finish`；当前无排期为 nil。
    public var planFinishVariance: Int?
    /// 实际结束偏差 `A.finish − B.finish`；未完成即 nil（不拿 plan 顶替）。
    public var actualFinishVariance: Int?
    /// 逾期天数 `max(0, today − B.finish)`；已完成即 nil。
    public var overdueDays: Int?

    public init(
        baselineID: UUID,
        name: String,
        start: Date,
        finish: Date,
        planFinishVariance: Int? = nil,
        actualFinishVariance: Int? = nil,
        overdueDays: Int? = nil
    ) {
        self.baselineID = baselineID
        self.name = name
        self.start = start
        self.finish = finish
        self.planFinishVariance = planFinishVariance
        self.actualFinishVariance = actualFinishVariance
        self.overdueDays = overdueDays
    }
}

/// 任务页内容。群组字段只读并标注聚合。
public struct TaskInspector: Hashable, Sendable {
    public var taskID: UUID
    public var title: String
    public var kind: TaskKind
    public var status: TaskStatus
    /// 取消原因（v0.16 D）：只有已取消任务有值，离开该状态即清空。
    public var cancelReason: String?
    public var priority: TaskPriority
    public var tags: [String]
    public var assignee: String?
    public var notes: String
    public var scheduledStart: Date?
    public var scheduledFinish: Date?
    /// 「开始」字段的用户意图（排期结果见 scheduledStart）；群组为 nil。
    public var startDate: Date?
    /// 实际开始（`TaskItem.actualStart`，F-0719）；群组为 nil。
    /// 实际结束复用下面的 `completedAt`，不另设字段。
    public var actualStart: Date?
    public var durationDays: Double?
    public var effortHours: Double?
    public var slackDays: Double?
    public var dueDate: Date?
    public var deadlineRisk: Bool
    public var isOverdue: Bool
    public var progress: Double
    public var completedAt: Date?
    public var constraint: SchedulingConstraint?
    public var schedulingPolicy: SchedulingPolicy
    /// 排期方式：自动（依赖驱动）/ 手动（日期钉死）。
    public var schedulingMode: TaskSchedulingMode
    public var isAggregate: Bool
    public var hasSchedule: Bool
    public var unscheduledReason: UnscheduledReason?
    public var predecessors: [DependencyRow]
    public var successors: [DependencyRow]
    public var violations: [Violation]
    public var assignmentNames: [String]
    /// 基线对比段（v0.13）；nil = 未选基线 / 基线后新增，视图整段不显示。
    public var baseline: BaselineSection?
    /// 工作日历留痕（F-22-06 / D3）：输入日期被顺延的记录，空 = 该任务没有顺延，整段不显示。
    public var calendarAdjustments: [CalendarAdjustmentRow]

    public init(
        taskID: UUID,
        title: String,
        kind: TaskKind,
        status: TaskStatus,
        priority: TaskPriority,
        tags: [String] = [],
        assignee: String? = nil,
        notes: String = "",
        scheduledStart: Date? = nil,
        scheduledFinish: Date? = nil,
        durationDays: Double? = nil,
        effortHours: Double? = nil,
        slackDays: Double? = nil,
        dueDate: Date? = nil,
        deadlineRisk: Bool = false,
        isOverdue: Bool = false,
        progress: Double = 0,
        completedAt: Date? = nil,
        constraint: SchedulingConstraint? = nil,
        schedulingPolicy: SchedulingPolicy = .asap,
        schedulingMode: TaskSchedulingMode = .auto,
        isAggregate: Bool = false,
        hasSchedule: Bool = false,
        unscheduledReason: UnscheduledReason? = nil,
        predecessors: [DependencyRow] = [],
        successors: [DependencyRow] = [],
        violations: [Violation] = [],
        assignmentNames: [String] = [],
        startDate: Date? = nil,
        actualStart: Date? = nil,
        baseline: BaselineSection? = nil,
        cancelReason: String? = nil,
        calendarAdjustments: [CalendarAdjustmentRow] = []
    ) {
        self.taskID = taskID
        self.title = title
        self.kind = kind
        self.status = status
        self.priority = priority
        self.tags = tags
        self.assignee = assignee
        self.notes = notes
        self.scheduledStart = scheduledStart
        self.scheduledFinish = scheduledFinish
        self.startDate = startDate
        self.durationDays = durationDays
        self.effortHours = effortHours
        self.slackDays = slackDays
        self.dueDate = dueDate
        self.deadlineRisk = deadlineRisk
        self.isOverdue = isOverdue
        self.progress = progress
        self.completedAt = completedAt
        self.constraint = constraint
        self.schedulingPolicy = schedulingPolicy
        self.schedulingMode = schedulingMode
        self.isAggregate = isAggregate
        self.hasSchedule = hasSchedule
        self.unscheduledReason = unscheduledReason
        self.predecessors = predecessors
        self.successors = successors
        self.violations = violations
        self.assignmentNames = assignmentNames
        self.actualStart = actualStart
        self.baseline = baseline
        self.cancelReason = cancelReason
        self.calendarAdjustments = calendarAdjustments
    }
}

/// 违例页条目（F-0704）：只带码 + 语义 + 参数，标题与原因文案由视图按 Catalog 渲染。
///
/// name / message 两个中文整句字段已删除——快照跨 UI / CLI / MCP 复用，
/// 携带文案会把接口层的语言策略绑死在呈现层（ADR-013）。
public struct ViolationItem: Identifiable, Hashable, Sendable {
    /// 同一任务可能出多条同码违例（如「结束不早于」同时触发两条冲突），
    /// 故 ID 带上 reason 的全部参数，不能只用码。
    public var id: String {
        "\(code.rawValue)-\(taskID?.uuidString ?? "project")-\(String(describing: reason))"
    }
    public var code: KairoErrorCode
    public var reason: ViolationReason
    public var severity: Violation.Severity
    public var taskID: UUID?
    public var taskTitle: String?

    public init(
        code: KairoErrorCode,
        reason: ViolationReason,
        severity: Violation.Severity,
        taskID: UUID? = nil,
        taskTitle: String? = nil
    ) {
        self.code = code
        self.reason = reason
        self.severity = severity
        self.taskID = taskID
        self.taskTitle = taskTitle
    }
}

/// 违例页内容：按 error / warning 分组；空态列出已检查规则类别。
public struct ViolationInspector: Hashable, Sendable {
    public struct Group: Identifiable, Hashable, Sendable {
        public var id: Violation.Severity { severity }
        public var severity: Violation.Severity
        public var items: [ViolationItem]

        public init(severity: Violation.Severity, items: [ViolationItem]) {
            self.severity = severity
            self.items = items
        }
    }

    public var groups: [Group]
    public var errorCount: Int
    public var warningCount: Int
    public var checkedRules: [ViolationEngine.RuleCategory]

    public init(
        groups: [Group],
        errorCount: Int,
        warningCount: Int,
        checkedRules: [ViolationEngine.RuleCategory] = ViolationEngine.ruleCategories
    ) {
        self.groups = groups
        self.errorCount = errorCount
        self.warningCount = warningCount
        self.checkedRules = checkedRules
    }
}

/// 检查器快照。
public struct InspectorSnapshot: Hashable, Sendable {
    public enum Content: Hashable, Sendable {
        case project(ProjectInspector)
        case task(TaskInspector)
        case violations(ViolationInspector)
    }

    public var content: Content
    public var tab: InspectorTab
    public var locked: Bool
    /// 选择漂移：锁定任务已删除或外部重载后缺失。
    public var selectionMissing: Bool

    public init(
        content: Content,
        tab: InspectorTab,
        locked: Bool = false,
        selectionMissing: Bool = false
    ) {
        self.content = content
        self.tab = tab
        self.locked = locked
        self.selectionMissing = selectionMissing
    }
}

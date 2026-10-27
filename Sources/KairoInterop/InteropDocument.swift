import Foundation

/// 互操作 IR（docs/features/14-interop-architecture.md §3）：供应商无关的计划文档。
///
/// 设计要点：
/// - **只描述「计划是什么」，不描述「哪个软件怎么存」**。字段单位取最能避免截断的口径
///   （时间用 `Date`，工期与前导时间用**秒**），具体格式的换算由适配器自己收口。
/// - 适配器只允许对 `InteropDocument` 说话（硬规则 2）；任何「工作日 ↔ 日历天」
///   「Summary ↔ 群组」这类语义换算都在 `KairoBridge` 一处实现。
/// - 所有 id 都是 `String`：MSPDI 用整数 UID，`.oplx` 用本地 id，IR 不做归一化编号。
/// - `ledger` 记录**读入本 IR 时已经发生的损失**；IR → Kairo 的损失由
///   `KairoBridge.Result.ledger` 追加，两者合并才是用户看到的预检报告。
public struct InteropDocument: Sendable, Equatable {
    /// 项目级元数据。
    public var metadata: InteropMetadata
    /// 任务清单，**按大纲顺序**排列（顺序即顺序，不另设 order 字段以外的排序键）。
    public var tasks: [InteropTask]
    /// 资源清单。
    public var resources: [InteropResource]
    /// 日历清单（缺失即「全周 7 天上班」，与 Kairo 默认一致）。
    public var calendars: [InteropCalendar]
    /// 资源分配（任务 ↔ 资源，只带单位）。
    public var assignments: [InteropAssignment]
    /// 基线快照。
    public var baselines: [InteropBaseline]
    /// 自定义域定义（MSPDI `ExtendedAttribute` 的别名表）。
    public var customFields: [InteropCustomFieldDefinition]
    /// 读入本 IR 时发生的有损登记。
    public var ledger: FidelityLedger

    public init(
        metadata: InteropMetadata = InteropMetadata(),
        tasks: [InteropTask] = [],
        resources: [InteropResource] = [],
        calendars: [InteropCalendar] = [],
        assignments: [InteropAssignment] = [],
        baselines: [InteropBaseline] = [],
        customFields: [InteropCustomFieldDefinition] = [],
        ledger: FidelityLedger = FidelityLedger()
    ) {
        self.metadata = metadata
        self.tasks = tasks
        self.resources = resources
        self.calendars = calendars
        self.assignments = assignments
        self.baselines = baselines
        self.customFields = customFields
        self.ledger = ledger
    }
}

/// 项目级元数据（IR）。
public struct InteropMetadata: Sendable, Equatable {
    /// 项目标题（来源缺失时为空串，由桥接层决定占位文案）。
    public var title: String
    public var author: String?
    public var createdAt: Date?
    /// 来源文件最后保存时刻：基线缺创建时间时用它兜底。
    public var lastSavedAt: Date?
    /// 计划起点 / 终点（来源声明值，可能是推算值，见 13-mapping §3）。
    public var plannedStart: Date?
    public var plannedFinish: Date?
    /// 默认日历 id（任务未指定日历时继承它）。
    public var defaultCalendarID: String?
    /// 排期方向。
    public var direction: InteropScheduleDirection

    public init(
        title: String = "",
        author: String? = nil,
        createdAt: Date? = nil,
        lastSavedAt: Date? = nil,
        plannedStart: Date? = nil,
        plannedFinish: Date? = nil,
        defaultCalendarID: String? = nil,
        direction: InteropScheduleDirection = .forward
    ) {
        self.title = title
        self.author = author
        self.createdAt = createdAt
        self.lastSavedAt = lastSavedAt
        self.plannedStart = plannedStart
        self.plannedFinish = plannedFinish
        self.defaultCalendarID = defaultCalendarID
        self.direction = direction
    }
}

/// 排期方向（向前 / 向后）。
public enum InteropScheduleDirection: String, Sendable, Equatable, CaseIterable {
    case forward
    case backward
}

/// 任务种类：任务 / 群组 / 里程碑。
public enum InteropTaskKind: String, Sendable, Equatable, CaseIterable {
    case task
    case group
    case milestone
}

/// 任务之间的相关性类型；枚举顺序与 Kairo 一致（FS/FF/SS/SF），
/// 与 MSPDI 的 0=FF / 1=FS / 2=SF / 3=SS **不同**，换算在适配器内完成。
public enum InteropDependencyType: String, Sendable, Equatable, CaseIterable {
    case finishToStart = "FS"
    case finishToFinish = "FF"
    case startToStart = "SS"
    case startToFinish = "SF"
}

/// 约束类型（IR 侧只表达「意图」，不表达「硬不硬」）。
///
/// MSPDI 的 SNET/SNLT/FNET/FNLT 是硬约束（会改期或报冲突），Kairo 的对应物是软约束
/// （只出违例）——这条语义差由 `KairoBridge` 写进 `FidelityLedger`，IR 本身不承载。
public enum InteropConstraint: Sendable, Equatable {
    case startNoEarlierThan(Date)
    case startNoLaterThan(Date)
    case endNoEarlierThan(Date)
    case endNoLaterThan(Date)
    case asSoonAsPossible
    case asLateAsPossible

    /// 约束日期；ASAP/ALAP 无日期。
    public var date: Date? {
        switch self {
        case .startNoEarlierThan(let d), .startNoLaterThan(let d),
             .endNoEarlierThan(let d), .endNoLaterThan(let d):
            return d
        case .asSoonAsPossible, .asLateAsPossible:
            return nil
        }
    }
}

/// 相关性（IR）：前驱 + 类型 + 前导时间。
///
/// `lagSeconds` 用秒而不是天：MSPDI 的 `LinkLag` 是十分之一分钟，来回换算成天会截断小数，
/// 关键路径判定可能因此翻转（13-mapping §3.5）。
public struct InteropDependency: Sendable, Equatable {
    public var predecessorID: String
    public var type: InteropDependencyType
    public var lagSeconds: TimeInterval

    public init(
        predecessorID: String,
        type: InteropDependencyType = .finishToStart,
        lagSeconds: TimeInterval = 0
    ) {
        self.predecessorID = predecessorID
        self.type = type
        self.lagSeconds = lagSeconds
    }
}

/// 任务节点（IR）。
///
/// 工期与投入的单位刻意分开：
/// - `durationSeconds` 是**工作日口径的工作时长**（MSPDI `Duration` 原值）；
/// - `effortHours` 是投入工时（MSPDI `Work` 原值）。
///
/// 换算成 Kairo 的「工作日数」必须知道来源日历的一天几小时，所以只在 `KairoBridge` 里做。
public struct InteropTask: Identifiable, Sendable, Equatable {
    /// 来源 id（MSPDI UID / `.oplx` 本地 id）。IR 内唯一。
    public var id: String
    public var title: String
    public var notes: String
    public var kind: InteropTaskKind
    /// 大纲层级（0 = 顶层）。
    public var outlineLevel: Int
    /// 大纲父节点 id；来源未声明时由 `outlineLevel` 推导（见 `KairoBridge`）。
    public var parentID: String?
    /// 大纲顺序（0 起）：写入时必须保序，否则父子关系会错位。
    public var sequence: Int
    public var plannedStart: Date?
    public var plannedFinish: Date?
    /// 工期（秒，工作日口径）。
    public var durationSeconds: TimeInterval?
    /// 投入（小时）。
    public var effortHours: Double?
    /// 完成度 0…1。
    public var progress: Double
    public var actualStart: Date?
    public var actualFinish: Date?
    public var dependencies: [InteropDependency]
    public var constraint: InteropConstraint?
    /// 任务级日历 id；nil = 继承项目默认日历。
    public var calendarID: String?
    /// 自定义域值：键为字段名（`Text1` / `Date1`），值为来源原值。
    public var attributes: [String: String]

    public init(
        id: String,
        title: String = "",
        notes: String = "",
        kind: InteropTaskKind = .task,
        outlineLevel: Int = 0,
        parentID: String? = nil,
        sequence: Int = 0,
        plannedStart: Date? = nil,
        plannedFinish: Date? = nil,
        durationSeconds: TimeInterval? = nil,
        effortHours: Double? = nil,
        progress: Double = 0,
        actualStart: Date? = nil,
        actualFinish: Date? = nil,
        dependencies: [InteropDependency] = [],
        constraint: InteropConstraint? = nil,
        calendarID: String? = nil,
        attributes: [String: String] = [:]
    ) {
        self.id = id
        self.title = title
        self.notes = notes
        self.kind = kind
        self.outlineLevel = outlineLevel
        self.parentID = parentID
        self.sequence = sequence
        self.plannedStart = plannedStart
        self.plannedFinish = plannedFinish
        self.durationSeconds = durationSeconds
        self.effortHours = effortHours
        self.progress = min(max(progress, 0), 1)
        self.actualStart = actualStart
        self.actualFinish = actualFinish
        self.dependencies = dependencies
        self.constraint = constraint
        self.calendarID = calendarID
        self.attributes = attributes
    }
}

/// 资源种类（IR）。
public enum InteropResourceKind: String, Sendable, Equatable, CaseIterable {
    case person
    case material
    /// 成本类资源（MSPDI Type=2）：Kairo 无成本概念，导入时降级。
    case cost
    case unknown
}

/// 资源（IR）。
public struct InteropResource: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var kind: InteropResourceKind
    /// 可用单位（人员/设备为倍数，1 = 100%）。
    public var units: Double
    /// 资源日历 id；nil = 用项目默认日历。
    public var calendarID: String?

    public init(
        id: String,
        name: String = "",
        kind: InteropResourceKind = .person,
        units: Double = 1,
        calendarID: String? = nil
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.units = units
        self.calendarID = calendarID
    }
}

/// 任务 ↔ 资源分配（IR）：只带单位，不带工作/成本（Kairo 无落点）。
public struct InteropAssignment: Sendable, Equatable {
    public var taskID: String
    public var resourceID: String
    public var units: Double

    public init(taskID: String, resourceID: String, units: Double = 1) {
        self.taskID = taskID
        self.resourceID = resourceID
        self.units = units
    }
}

/// 日历例外日（IR）：某一天是否上班。
public struct InteropCalendarException: Sendable, Equatable {
    /// 例外日期（当天零点）。
    public var date: Date
    /// `false` = 停工的节假日；`true` = 调休上班。
    public var isWorking: Bool
    public var note: String?

    public init(date: Date, isWorking: Bool, note: String? = nil) {
        self.date = date
        self.isWorking = isWorking
        self.note = note
    }
}

/// 工作日历（IR）。
///
/// `workingWeekdays` 用 `Calendar` 的 weekday 编号（1 = 周日 … 7 = 周六），与 Kairo 同口径；
/// 空集合表示「来源未声明」，桥接时退化为全周 7 天并登记。
public struct InteropCalendar: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var workingWeekdays: Set<Int>
    /// 一个工作日折算的工时。
    public var hoursPerDay: Double
    public var exceptions: [InteropCalendarException]

    public init(
        id: String,
        name: String = "",
        workingWeekdays: Set<Int> = InteropCalendar.allWeekdays,
        hoursPerDay: Double = 8,
        exceptions: [InteropCalendarException] = []
    ) {
        self.id = id
        self.name = name
        self.workingWeekdays = workingWeekdays
        self.hoursPerDay = hoursPerDay
        self.exceptions = exceptions
    }

    /// 全周 7 天（与「没有日历」等价）。
    public static let allWeekdays: Set<Int> = [1, 2, 3, 4, 5, 6, 7]
}

/// 基线条目（IR）：某任务在某次快照里的计划起止。
public struct InteropBaselineEntry: Sendable, Equatable {
    public var taskID: String
    public var start: Date
    public var finish: Date
    /// 快照时的完成度；来源未提供时为 nil（Kairo 回落 0 并登记）。
    public var progress: Double?

    public init(taskID: String, start: Date, finish: Date, progress: Double? = nil) {
        self.taskID = taskID
        self.start = start
        self.finish = finish
        self.progress = progress
    }
}

/// 基线（IR）。
///
/// `createdAt` 可缺：MSPDI 的 `Baseline` 只有编号与起止，没有快照时刻。
public struct InteropBaseline: Identifiable, Sendable, Equatable {
    public var id: String
    public var name: String?
    public var createdAt: Date?
    public var entries: [InteropBaselineEntry]

    public init(
        id: String,
        name: String? = nil,
        createdAt: Date? = nil,
        entries: [InteropBaselineEntry] = []
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.entries = entries
    }
}

/// 自定义域定义（IR）：MSPDI `<ExtendedAttributes>` 里的别名表。
public struct InteropCustomFieldDefinition: Identifiable, Sendable, Equatable {
    /// 来源字段 id（MSPDI FieldID）。
    public var id: String
    /// 字段名（`Text1` / `Date1`）。
    public var fieldName: String
    /// 用户在来源里起的别名（`差异时间`）。
    public var alias: String?

    public init(id: String, fieldName: String, alias: String? = nil) {
        self.id = id
        self.fieldName = fieldName
        self.alias = alias
    }
}

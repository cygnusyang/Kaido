import Foundation

/// 项目元数据（标题 / 时间戳；.kaido 格式 project 段）。
public struct ProjectMetadata: Codable, Hashable, Sendable {
    public var id: UUID
    public var title: String
    public var createdAt: Date
    public var updatedAt: Date
    /// 项目时间线（F-20-02）：排期与违例的默认边界；未设则由显式参数或任务数据推导。
    public var projectStart: Date?
    public var projectEnd: Date?
    /// 项目排期方向（ADR-011 / ADR-013）：默认向前排；旧文件缺省为 forward。
    public var direction: ScheduleDirection
    /// 项目工作日历（F-22-06 / 16-work-calendar）：可选加法字段，缺失 = 全周 7 天。
    /// 不升 `formatVersion`：旧文件读入为 nil（等价全周），旧客户端读到未知键会忽略。
    public var calendar: WorkCalendar?
    /// EVM 数据日期（17-evm-status-date）：挣值里 PV 的「观察时点」。
    ///
    /// - `nil` = 每次渲染时取「今天」（不落盘）：同一份周报跨天会得到不同数字，UI 须明示。
    /// - 存储口径是**当日 00:00**：同一天不同时分必须落到同一时刻，否则 PV 会按小时漂移。
    ///   赋值即归一（按本机时区的公历，与全仓日期口径一致）；项目日历不在本机时区时，
    ///   用 `setStatusDate(_:calendar:)` 显式传入日历。
    /// - 解码**不重算时区**：文件里的整点直接读入，避免换时区打开时日期整体漂移一天。
    /// - 加法字段，不升 `formatVersion`（仍为 2）：缺键读入为 nil，旧客户端读到未知键会忽略。
    /// - **不进基线快照**：数据日期是报告参数，不是计划事实（`BaselineEngine.snapshot`
    ///   的签名里没有元数据，快照按构造不可能带它）。
    public var statusDate: Date? {
        get { statusDateStorage }
        set { statusDateStorage = Self.normalizing(newValue) }
    }

    /// `statusDate` 的实际存储：已归一到当天零点的绝对时刻，或 nil。
    private var statusDateStorage: Date?

    public init(
        id: UUID = UUID(),
        title: String = "未命名项目",
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        projectStart: Date? = nil,
        projectEnd: Date? = nil,
        direction: ScheduleDirection = .forward,
        calendar: WorkCalendar? = nil,
        statusDate: Date? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.projectStart = projectStart
        self.projectEnd = projectEnd
        self.direction = direction
        self.calendar = calendar
        // 静态函数，不读 self：可在其余字段初始化前调用。
        self.statusDateStorage = Self.normalizing(statusDate)
    }

    // MARK: - 数据日期归一（17-evm-status-date §3）

    /// 按 `calendar` 归一到当日零点；`nil` 原样返回（「未固定」不做归一）。
    ///
    /// 归一化只影响时分，不改日历日：这是「同一天两次设置必须相等」的唯一保证点。
    private static func normalizing(
        _ date: Date?,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Date? {
        date.map { CalendarDayMath.startOfDay($0, calendar: calendar) }
    }

    /// 当前数据日期在 `calendar` 下的零点口径；`nil` = 未固定（调用方回落到「今天」）。
    ///
    /// 计算层取观察时点用这个方法，而不是直接读 `statusDate`：文件可能是旧版本或
    /// 手改写入的非零点值，这里给出与排期同口径的整日时刻。
    public func normalizedStatusDate(calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        Self.normalizing(statusDate, calendar: calendar)
    }

    /// 写入数据日期：按 `calendar` 取当日 00:00 后落盘；`nil` = 清除，回到「今天」。
    ///
    /// 直接给 `statusDate` 赋值走同一归一（本机时区）；项目日历不在本机时区时必须走这里，
    /// 否则跨时区会把日期算到前一天。
    public mutating func setStatusDate(
        _ date: Date?,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        statusDateStorage = Self.normalizing(date, calendar: calendar)
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case id, title, createdAt, updatedAt, projectStart, projectEnd, direction, calendar, statusDate
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        title = try c.decode(String.self, forKey: .title)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decode(Date.self, forKey: .updatedAt)
        projectStart = try c.decodeIfPresent(Date.self, forKey: .projectStart)
        projectEnd = try c.decodeIfPresent(Date.self, forKey: .projectEnd)
        // 新增字段缺失给默认值（旧数据前向兼容）。
        direction = try c.decodeIfPresent(ScheduleDirection.self, forKey: .direction) ?? .forward
        calendar = try c.decodeIfPresent(WorkCalendar.self, forKey: .calendar)
        // 不在这里归一：解码时拿不到写入方时区，按本机时区重算会把「本地零点」挪到前一天。
        statusDateStorage = try c.decodeIfPresent(Date.self, forKey: .statusDate)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encode(updatedAt, forKey: .updatedAt)
        try c.encodeIfPresent(projectStart, forKey: .projectStart)
        try c.encodeIfPresent(projectEnd, forKey: .projectEnd)
        try c.encode(direction, forKey: .direction)
        // 无日历不写键：与 baselines 同一策略，避免给没有日历的项目凭空加噪音。
        try c.encodeIfPresent(calendar, forKey: .calendar)
        // 数据日期同理：未固定（nil）不落键，缺键即「今天」。
        try c.encodeIfPresent(statusDateStorage, forKey: .statusDate)
    }
}

/// A Kaido project: a flat, ordered task list plus CRUD and filtering.
/// Task order in `tasks` is the outline order shown in the main window.
///
/// 纯逻辑模型（ADR-004）：不依赖 AppKit/SwiftUI/Combine，可跨平台编译。
/// SwiftUI 的变更通知由应用层 `ProjectStore` 门面承担。
public final class Project {
    public var metadata: ProjectMetadata
    public var tasks: [TaskItem] = []
    /// 资源清单（F-23-01）：供资源 CRUD 与投入↔持续时间换算。
    public var resources: [Resource] = []
    /// 基线快照（v0.13 / 08-baselines §3）：有序，索引即创建顺序；不可变（只增 / 改名 / 删）。
    public var baselines: [Baseline] = []
    /// 项目工作日历（F-22-06）：落在 `metadata` 上，随 `.kaido` 的 `project` 段存读。
    /// 读写都经元数据转发，避免两处各存一份后漂移。
    public var calendar: WorkCalendar? {
        get { metadata.calendar }
        set { metadata.calendar = newValue }
    }

    public init(metadata: ProjectMetadata = ProjectMetadata()) {
        self.metadata = metadata
    }

    /// Fast lookup by task id.
    public var tasksByID: [UUID: TaskItem] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    public func add(_ task: TaskItem) {
        tasks.append(task)
    }

    /// 在指定任务之后插入（Return 新建同级任务，US-E4-03）。
    public func insert(_ task: TaskItem, after siblingID: UUID) {
        if let index = tasks.firstIndex(where: { $0.id == siblingID }) {
            tasks.insert(task, at: index + 1)
        } else {
            tasks.append(task)
        }
    }

    /// 用新的大纲顺序替换任务列表（缩进/出缩进后调用）。
    public func replaceTasks(_ newTasks: [TaskItem]) {
        tasks = newTasks
    }

    public func update(_ task: TaskItem) {
        guard let index = tasks.firstIndex(where: { $0.id == task.id }) else { return }
        tasks[index] = task
    }

    public func remove(id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    /// Tasks satisfying every clause; an empty clause list returns all tasks.
    public func filteredTasks(clauses: [FilterClause]) -> [TaskItem] {
        AIFilterTranslator.apply(clauses: clauses, to: tasks)
    }
}

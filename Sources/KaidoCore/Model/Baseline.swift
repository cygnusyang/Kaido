import Foundation

/// 基线条目（08-baselines §3）：一条任务在某次快照里的承诺时间与完成度。
///
/// 字段固定为五元组 `(taskID, start, finish, progress, isMilestone)`：
/// - 不存 title / outlineNumber / parentID / durationDays——标题缺失时用「已删除」占位，
///   工期由排他端点派生（`finish − start`）。条目瘦身直接决定文件体积（§6）。
/// - `finish` 是**排他端点**（与 `scheduledFinish` 同口径）：1 天任务 start=11-02 时 finish=11-03。
/// - 里程碑零时长，此时 `start == finish`。
///
/// 条目一经创建不可修改：基线的价值来自「承诺不被追认」。
public struct BaselineEntry: Codable, Hashable, Sendable {
    /// 对应任务 ID；任务删除后条目保留（成为孤儿，见 §5）。
    public var taskID: UUID
    /// 基线计划开始（快照时的 `scheduledStart`）。
    public var start: Date
    /// 基线计划结束（快照时的 `scheduledFinish`，排他端点）。
    public var finish: Date
    /// 快照时的完成度（0...1）。
    public var progress: Double
    /// 里程碑标记（零时长）。
    public var isMilestone: Bool

    public init(taskID: UUID, start: Date, finish: Date, progress: Double, isMilestone: Bool) {
        self.taskID = taskID
        self.start = start
        self.finish = finish
        self.progress = min(max(progress, 0), 1)
        self.isMilestone = isMilestone
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case taskID, start, finish, progress, isMilestone
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        taskID = try c.decode(UUID.self, forKey: .taskID)
        start = try c.decode(Date.self, forKey: .start)
        finish = try c.decode(Date.self, forKey: .finish)
        progress = min(max(try c.decodeIfPresent(Double.self, forKey: .progress) ?? 0, 0), 1)
        isMilestone = try c.decodeIfPresent(Bool.self, forKey: .isMilestone) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(taskID, forKey: .taskID)
        try c.encode(start, forKey: .start)
        try c.encode(finish, forKey: .finish)
        try c.encode(progress, forKey: .progress)
        try c.encode(isMilestone, forKey: .isMilestone)
    }
}

/// 基线（08-baselines §3）：对当前排期结果拍一次不可变快照。
///
/// 三层时间轴单向只读：基线不回流排期，实际时间不进 CPM（§2）。
/// 偏差是「所选基线 × 任务」的派生量，绝不落盘到 `TaskItem`——单值字段只能承载
/// 一份基线，与「多基线 + 切换对比」冲突。
///
/// 不可变性由接口保证：`KaidoSession` 只提供创建 / 改名 / 删除，
/// 没有更新条目的入口。
public struct Baseline: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    /// 默认名「基线 N · yyyy-MM-dd」（§3）。
    public var name: String
    /// 快照时刻，不可变。
    public var createdAt: Date
    /// 快照时的排期锚点（D-029 口径），用于解释偏差来源；旧数据缺失为 nil。
    public var anchor: Date?
    /// 快照条目（按任务大纲顺序）。
    public var entries: [BaselineEntry]
    /// 调色板索引 0…7（10-multi-baseline-gantt §4）。
    ///
    /// 快照只带索引、不带颜色值（ADR-013），颜色由 DesignTokens 按索引解析。
    /// nil = 旧文件缺该字段：读路径用 BaselinePalette.resolve 派生，写路径用
    /// BaselinePalette.ensureColors 补齐——纯加法字段，不升 formatVersion。
    public var colorIndex: Int?

    public init(
        id: UUID = UUID(),
        name: String,
        createdAt: Date,
        anchor: Date? = nil,
        entries: [BaselineEntry] = [],
        colorIndex: Int? = nil
    ) {
        self.id = id
        self.name = name
        self.createdAt = createdAt
        self.anchor = anchor
        self.entries = entries
        self.colorIndex = colorIndex
    }

    /// 按任务 ID 取条目（快照条目数量级与任务数同阶，线性查找足够）。
    public func entry(for taskID: UUID) -> BaselineEntry? {
        entries.first { $0.taskID == taskID }
    }

    /// 条目索引：偏差计算按任务批量查询时避免 O(n²)。
    public var entriesByTaskID: [UUID: BaselineEntry] {
        Dictionary(entries.map { ($0.taskID, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case id, name, createdAt, anchor, entries, colorIndex
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        anchor = try c.decodeIfPresent(Date.self, forKey: .anchor)
        entries = try c.decodeIfPresent([BaselineEntry].self, forKey: .entries) ?? []
        colorIndex = try c.decodeIfPresent(Int.self, forKey: .colorIndex)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(name, forKey: .name)
        try c.encode(createdAt, forKey: .createdAt)
        try c.encodeIfPresent(anchor, forKey: .anchor)
        try c.encode(entries, forKey: .entries)
        // 与 anchor 同口径：nil 不落盘，避免给旧文件补出无意义的 null。
        try c.encodeIfPresent(colorIndex, forKey: .colorIndex)
    }
}

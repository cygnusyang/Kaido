import Foundation

/// 排期锚点（ADR-013 / D-003）：时间轴原点及其来源。
///
/// 推导优先级：项目开始日期 → 最早任务意图开始日期 → 项目创建日期 → 今天。
/// 未设项目开始日期时禁止从 1970 纪元起排；推导结果标记 `isDerived`，
/// 界面据此显示「已按最早任务开始日期推导」提示。
public struct ScheduleAnchor: Hashable, Sendable {
    public enum Source: String, Codable, Hashable, Sendable {
        /// 项目元数据显式设置。
        case projectStart
        /// 由最早任务的 `startDate` 推导。
        case earliestTaskStart
        /// 无日期信号时取项目创建日期（"输入任务的那天"即计划起点，而不是每次打开都漂到今天）。
        case projectCreated
        /// 连创建日期都缺失时取今天（兜底）。
        case today
    }

    /// 已归一到当天零点的锚点日期。
    public var date: Date
    public var source: Source

    public init(date: Date, source: Source) {
        self.date = date
        self.source = source
    }

    /// 锚点是否由推导得到（非显式项目开始日期）。
    public var isDerived: Bool { source != .projectStart }

    /// 按优先级推导锚点。`startDate` 是用户意图，`dueDate` 不参与推导。
    public static func derive(
        tasks: [TaskItem],
        projectStart: Date?,
        now: Date,
        calendar: Calendar,
        createdAt: Date? = nil
    ) -> ScheduleAnchor {
        if let projectStart {
            return ScheduleAnchor(date: calendar.startOfDay(for: projectStart), source: .projectStart)
        }
        if let earliest = tasks.compactMap(\.startDate).min() {
            return ScheduleAnchor(date: calendar.startOfDay(for: earliest), source: .earliestTaskStart)
        }
        // 创建日期优先于「今天」：无日期的任务应在「计划开始那天」起步。取今天的实现会让
        // 同一个项目每次打开都整体右移，用户看到的「所有任务都从今天开始」即此（D-029）。
        if let createdAt {
            return ScheduleAnchor(date: calendar.startOfDay(for: createdAt), source: .projectCreated)
        }
        return ScheduleAnchor(date: calendar.startOfDay(for: now), source: .today)
    }
}

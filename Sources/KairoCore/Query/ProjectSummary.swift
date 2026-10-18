import Foundation

/// 项目摘要与健康度（F-30 / ADR-013）：界面只展示，不在视图层重算。
///
/// 口径：
/// - 叶子任务 = `kind != .group` 且无子项；群组不计入进度与占比分母。
/// - 加权总进度按 `effortHours` 加权，缺失投入按权重 1。
/// - 逾期 = 未完成且计划结束早于今天；无有效排期时退回 `dueDate`。
/// - 健康占比的分母固定为未完成叶子任务。
public struct ProjectSummary: Codable, Hashable, Sendable {
    public enum Health: String, Codable, Hashable, Sendable {
        case green, orange, red
    }

    /// 0...1 加权总进度。
    public var totalProgress: Double
    public var taskCount: Int
    public var groupCount: Int
    public var milestoneCount: Int
    /// 逾期未完成的叶子任务数。
    public var overdueCount: Int
    /// 未完成叶子任务数（健康占比分母）。
    public var incompleteLeafCount: Int
    /// 未完成且无 `dueDate` 的叶子任务数。
    public var missingDueDateCount: Int
    public var errorCount: Int
    public var warningCount: Int
    /// 总宽延为 0 的叶子任务数（重要路径口径）。
    public var criticalPathCount: Int
    /// 距项目结束的剩余天数；无结束日期为 nil，已过期为 0。
    public var remainingDays: Int?
    public var health: Health

    public init(
        tasks: [TaskItem],
        schedule: ScheduleResult?,
        violations: [Violation],
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) {
        let parentIDs = Set(tasks.compactMap(\.parentID))
        let leaves = tasks.filter { $0.kind != .group && !parentIDs.contains($0.id) }
        let incompleteLeaves = leaves.filter { $0.status != .done }
        // 排期索引：避免逐任务线性查找导致 O(n²)。
        let scheduledByID = Dictionary(
            uniqueKeysWithValues: (schedule?.tasks ?? []).map { ($0.taskID, $0) }
        )
        let unscheduledIDs = Set(schedule?.unscheduledTaskIDs ?? [])
        func validSchedule(_ id: UUID) -> ScheduledTask? {
            guard !unscheduledIDs.contains(id) else { return nil }
            return scheduledByID[id]
        }

        taskCount = tasks.filter { $0.kind == .task }.count
        groupCount = tasks.filter { $0.kind == .group }.count
        milestoneCount = tasks.filter { $0.kind == .milestone }.count
        incompleteLeafCount = incompleteLeaves.count

        let weight = { (task: TaskItem) -> Double in
            max(task.effortHours ?? 1, 0)
        }
        let totalWeight = leaves.reduce(0) { $0 + weight($1) }
        totalProgress = totalWeight > 0
            ? min(max(leaves.reduce(0) { $0 + weight($1) * $1.progress } / totalWeight, 0), 1)
            : 0

        let today = calendar.startOfDay(for: now)
        overdueCount = incompleteLeaves.filter { task in
            Self.isOverdue(
                task,
                plannedFinish: validSchedule(task.id)?.scheduledFinish,
                now: today,
                calendar: calendar
            )
        }.count
        missingDueDateCount = incompleteLeaves.filter { $0.dueDate == nil }.count

        errorCount = violations.filter { $0.severity == .error }.count
        warningCount = violations.filter { $0.severity == .warning }.count

        criticalPathCount = leaves.filter { task in
            guard let scheduled = validSchedule(task.id), scheduled.durationDays > 0 else { return false }
            return abs(scheduled.totalSlackDays) < 0.0001
        }.count

        let projectEnd = schedule?.projectEnd
            ?? scheduledByID.values
                .filter { $0.durationDays > 0 && !unscheduledIDs.contains($0.taskID) }
                .map(\.scheduledFinish)
                .max()
        if let projectEnd {
            let days = calendar.dateComponents(
                [.day], from: today, to: calendar.startOfDay(for: projectEnd)
            ).day ?? 0
            remainingDays = max(days, 0)
        } else {
            remainingDays = nil
        }

        let overdueRatio = incompleteLeaves.isEmpty
            ? 0 : Double(overdueCount) / Double(incompleteLeaves.count)
        let missingDueRatio = incompleteLeaves.isEmpty
            ? 0 : Double(missingDueDateCount) / Double(incompleteLeaves.count)
        if errorCount > 0 || overdueRatio > 0.2 {
            health = .red
        } else if warningCount > 0 || overdueCount > 0 || missingDueRatio > 0.2 {
            health = .orange
        } else {
            health = .green
        }
    }

    /// 统一逾期口径：未完成且计划结束早于今天；无有效排期时退回 `dueDate`。
    /// `plannedFinish` 必须来自有效排期（调用方用 `ScheduleResult.hasSchedule` 过滤）。
    public static func isOverdue(
        _ task: TaskItem,
        plannedFinish: Date?,
        now: Date,
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> Bool {
        guard task.status != .done else { return false }
        let today = calendar.startOfDay(for: now)
        if let plannedFinish {
            return calendar.startOfDay(for: plannedFinish) < today
        }
        if let due = task.dueDate {
            return calendar.startOfDay(for: due) < today
        }
        return false
    }
}

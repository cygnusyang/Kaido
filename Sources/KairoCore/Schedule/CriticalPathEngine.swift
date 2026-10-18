import Foundation

/// 重要路径与宽延明细（US-E2-03 / F-21-01 / F-21-03）。
/// 消费调度引擎输出的最早/最晚窗口；总宽延与自由宽延已在 `ScheduledTask` 上给出。
public struct CriticalPathEntry: Codable, Hashable, Sendable {
    public var taskID: UUID
    public var totalSlackDays: Double
    public var freeSlackDays: Double
    /// 是否重要路径成员（总宽延 ≤ 宽延限制）。
    public var isCritical: Bool

    public init(taskID: UUID, totalSlackDays: Double, freeSlackDays: Double, isCritical: Bool) {
        self.taskID = taskID
        self.totalSlackDays = totalSlackDays
        self.freeSlackDays = freeSlackDays
        self.isCritical = isCritical
    }
}

/// 重要路径引擎（纯函数）：按宽延限制选出重要路径成员。
public enum CriticalPathEngine {
    /// 总宽延 ≤ `slackLimit` 的任务纳入重要路径；`slackLimit` 默认 0（决定项目总时长的链路）。
    public static func compute(result: ScheduleResult, slackLimit: Double? = nil) -> [CriticalPathEntry] {
        let limit = slackLimit ?? 0
        return result.tasks.map { task in
            CriticalPathEntry(
                taskID: task.taskID,
                totalSlackDays: task.totalSlackDays,
                freeSlackDays: task.freeSlackDays,
                isCritical: task.totalSlackDays <= limit
            )
        }
    }
}

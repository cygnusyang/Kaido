import Foundation

/// 任务种类：任务 / 群组 / 里程碑（glossary「任务 / 群组 / 里程碑」）。
public enum TaskKind: String, Codable, CaseIterable, Sendable {
    case task
    case group
    case milestone
}

/// 相关性（dependency）：任务间从属关系，带类型与前导时间。
/// 原 `TaskItem.dependencies: [UUID]` 重构而来（US-E2-01）；
/// 旧数据按 FS、无前导时间迁移。
public struct TaskDependency: Codable, Hashable, Sendable {
    /// 相关性类型：完成-开始 / 完成-完成 / 开始-开始 / 开始-完成。
    public enum DependencyType: String, Codable, CaseIterable, Sendable {
        case fs, ff, ss, sf
    }

    /// 前驱任务 ID（被本任务依赖的任务）。
    public var predecessorID: UUID
    /// 相关性类型（默认 FS）。
    public var type: DependencyType
    /// 前导时间（天）；允许正负。
    public var lagDays: Double

    public init(
        predecessorID: UUID,
        type: DependencyType = .fs,
        lagDays: Double = 0
    ) {
        self.predecessorID = predecessorID
        self.type = type
        self.lagDays = lagDays
    }
}

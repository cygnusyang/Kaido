import Foundation

/// 项目值快照（ADR-013）：撤销栈与呈现层输入的稳定边界。
///
/// 快照与 `Project` 引用脱钩；恢复时整体覆盖元数据、任务、资源与基线。
/// 任务顺序即大纲顺序，快照必须原样保留。
public struct ProjectState: Codable, Hashable, Sendable {
    public var metadata: ProjectMetadata
    public var tasks: [TaskItem]
    public var resources: [Resource]
    /// 基线快照（v0.13）：创建/删除基线进撤销栈，撤销必须能还原基线集合。
    public var baselines: [Baseline]

    public init(
        metadata: ProjectMetadata,
        tasks: [TaskItem],
        resources: [Resource],
        baselines: [Baseline] = []
    ) {
        self.metadata = metadata
        self.tasks = tasks
        self.resources = resources
        self.baselines = baselines
    }

    public init(project: Project) {
        self.init(
            metadata: project.metadata,
            tasks: project.tasks,
            resources: project.resources,
            baselines: project.baselines
        )
    }

    /// 用快照整体恢复项目。`Project` 是引用类型，因此就地覆盖内容而非替换引用。
    public func apply(to project: Project) {
        project.metadata = metadata
        project.replaceTasks(tasks)
        project.resources = resources
        project.baselines = baselines
    }

    // MARK: - Codable 兼容（ADR-011）

    private enum CodingKeys: String, CodingKey {
        case metadata, tasks, resources, baselines
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        metadata = try c.decode(ProjectMetadata.self, forKey: .metadata)
        tasks = try c.decode([TaskItem].self, forKey: .tasks)
        resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        baselines = try c.decodeIfPresent([Baseline].self, forKey: .baselines) ?? []
    }
}

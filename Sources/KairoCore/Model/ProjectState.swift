import Foundation

/// 项目值快照（ADR-013）：撤销栈与呈现层输入的稳定边界。
///
/// 快照与 `Project` 引用脱钩；恢复时整体覆盖元数据、任务与资源。
/// 任务顺序即大纲顺序，快照必须原样保留。
public struct ProjectState: Codable, Hashable, Sendable {
    public var metadata: ProjectMetadata
    public var tasks: [TaskItem]
    public var resources: [Resource]

    public init(metadata: ProjectMetadata, tasks: [TaskItem], resources: [Resource]) {
        self.metadata = metadata
        self.tasks = tasks
        self.resources = resources
    }

    public init(project: Project) {
        self.init(
            metadata: project.metadata,
            tasks: project.tasks,
            resources: project.resources
        )
    }

    /// 用快照整体恢复项目。`Project` 是引用类型，因此就地覆盖内容而非替换引用。
    public func apply(to project: Project) {
        project.metadata = metadata
        project.replaceTasks(tasks)
        project.resources = resources
    }
}

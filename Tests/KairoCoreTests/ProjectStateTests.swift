import Foundation
import Testing
@testable import KairoCore

// 项目值快照（ADR-013）：撤销与呈现层输入的稳定边界。
// 快照必须与 Project 引用脱钩；恢复必须完整覆盖元数据、任务与资源。

struct ProjectStateTests {
    @Test func snapshotCopiesProjectContent() {
        let project = Project(metadata: ProjectMetadata(title: "快照项目"))
        project.add(TaskItem(title: "A"))
        project.add(TaskItem(title: "B"))
        project.resources.append(Resource(name: "Alice"))

        let state = ProjectState(project: project)

        #expect(state.metadata.title == "快照项目")
        #expect(state.tasks.map(\.title) == ["A", "B"])
        #expect(state.resources.map(\.name) == ["Alice"])
    }

    @Test func snapshotIsIndependentOfLaterProjectMutation() {
        let project = Project(metadata: ProjectMetadata(title: "原项目"))
        let task = TaskItem(title: "A")
        project.add(task)

        let state = ProjectState(project: project)
        project.metadata.title = "已修改"
        project.tasks[0].title = "已改名"
        project.tasks.append(TaskItem(title: "新增"))

        #expect(state.metadata.title == "原项目")
        #expect(state.tasks.map(\.title) == ["A"])
    }

    @Test func applyRestoresFullProject() {
        let project = Project(metadata: ProjectMetadata(title: "原项目"))
        project.add(TaskItem(title: "A"))
        project.resources.append(Resource(name: "Alice"))
        let state = ProjectState(project: project)

        project.metadata.title = "被改"
        project.tasks.removeAll()
        project.resources.removeAll()
        state.apply(to: project)

        #expect(project.metadata.title == "原项目")
        #expect(project.tasks.map(\.title) == ["A"])
        #expect(project.resources.map(\.name) == ["Alice"])
    }

    @Test func emptyStateAppliesAsEmptyProject() {
        let project = Project(metadata: ProjectMetadata(title: "有内容"))
        project.add(TaskItem(title: "A"))

        ProjectState(metadata: ProjectMetadata(title: "空"), tasks: [], resources: [])
            .apply(to: project)

        #expect(project.metadata.title == "空")
        #expect(project.tasks.isEmpty)
        #expect(project.resources.isEmpty)
    }

    @Test func stateRoundTripsThroughCodable() throws {
        let project = Project(metadata: ProjectMetadata(title: "编码"))
        project.add(TaskItem(title: "A", dueDate: Date(timeIntervalSince1970: 1_800_000_000)))

        let data = try JSONEncoder().encode(ProjectState(project: project))
        let decoded = try JSONDecoder().decode(ProjectState.self, from: data)

        #expect(decoded == ProjectState(project: project))
    }
}

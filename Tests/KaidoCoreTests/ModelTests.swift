import Foundation
import Testing
@testable import KaidoCore

// MARK: - TaskDependency 编码

@Test func taskDependencyCodableRoundTrip() throws {
    let dependency = TaskDependency(
        predecessorID: UUID(),
        type: .ss,
        lagDays: 1.5
    )
    let data = try JSONEncoder().encode(dependency)
    let decoded = try JSONDecoder().decode(TaskDependency.self, from: data)
    #expect(decoded == dependency)
    #expect(decoded.type == .ss)
    #expect(decoded.lagDays == 1.5)
}

@Test func dependencyTypeRawValues() {
    #expect(TaskDependency.DependencyType.allCases.map(\.rawValue) == ["fs", "ff", "ss", "sf"])
    #expect(TaskDependency.DependencyType(rawValue: "fs") == .fs)
}

// MARK: - TaskItem 新字段（kind / parentID / 投入 / 持续时间）

@Test func taskItemWithKindParentAndEffortRoundTrips() throws {
    let parent = TaskItem(title: "群组 A", kind: .group)
    let child = TaskItem(
        title: "子任务",
        kind: .task,
        parentID: parent.id,
        effortHours: 8,
        durationDays: 1
    )
    let encoder = JSONEncoder()
    let data = try encoder.encode(child)
    let decoded = try JSONDecoder().decode(TaskItem.self, from: data)
    #expect(decoded.parentID == parent.id)
    #expect(decoded.kind == .task)
    #expect(decoded.effortHours == 8)
    #expect(decoded.durationDays == 1)
}

@Test func milestoneKindRoundTrips() throws {
    let milestone = TaskItem(title: "发布 v2.0", kind: .milestone)
    let data = try JSONEncoder().encode(milestone)
    let decoded = try JSONDecoder().decode(TaskItem.self, from: data)
    #expect(decoded.kind == .milestone)
}

// MARK: - 旧数据前向兼容（ADR-011 / US-E2-01）

@Test func legacyTaskMissingNewFieldsDefaults() throws {
    let legacyJSON = """
    {
      "id": "\(UUID().uuidString)",
      "title": "旧任务",
      "notes": "",
      "priority": "normal",
      "status": "pending",
      "tags": [],
      "progress": 0
    }
    """
    let decoded = try JSONDecoder().decode(TaskItem.self, from: Data(legacyJSON.utf8))
    #expect(decoded.kind == .task)
    #expect(decoded.parentID == nil)
    #expect(decoded.effortHours == nil)
    #expect(decoded.durationDays == nil)
    #expect(decoded.dependencies.isEmpty)
}

@Test func legacyUUIDDependenciesMigrateToFS() throws {
    let predecessor = UUID()
    let legacyJSON = """
    {
      "id": "\(UUID().uuidString)",
      "title": "新任务",
      "dependencies": ["\(predecessor.uuidString)"]
    }
    """
    let decoded = try JSONDecoder().decode(TaskItem.self, from: Data(legacyJSON.utf8))
    #expect(decoded.dependencies.count == 1)
    #expect(decoded.dependencies.first?.predecessorID == predecessor)
    // 旧数据按 FS、无前导时间迁移（US-E2-01 验收）。
    #expect(decoded.dependencies.first?.type == .fs)
    #expect(decoded.dependencies.first?.lagDays == 0)
}

// MARK: - 层级树结构（parentID）

@Test func parentChildrenTreeStructure() {
    let project = Project()
    let group = TaskItem(title: "群组 G", kind: .group)
    let taskA = TaskItem(title: "任务 A", parentID: group.id)
    let taskB = TaskItem(title: "任务 B", parentID: group.id)
    let top = TaskItem(title: "顶层任务")
    project.add(group)
    project.add(taskA)
    project.add(taskB)
    project.add(top)

    let childrenOfGroup = project.tasks.filter { $0.parentID == group.id }
    #expect(childrenOfGroup.count == 2)
    #expect(childrenOfGroup.contains { $0.id == taskA.id })
    #expect(childrenOfGroup.contains { $0.id == taskB.id })
    #expect(project.tasks.filter { $0.parentID == nil }.count == 2) // 群组 + 顶层
    #expect(project.tasksByID[taskA.id]?.parentID == group.id)
}

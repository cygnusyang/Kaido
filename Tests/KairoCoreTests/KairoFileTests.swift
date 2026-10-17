import Foundation
import Testing
@testable import KairoCore

// MARK: - 往返

@Test func saveLoadRoundTripPreservesTasksAndMetadata() throws {
    let project = Project()
    project.metadata.title = "示例项目"
    let a = TaskItem(title: "任务 A", kind: .task)
    let g = TaskItem(title: "群组 G", kind: .group)
    let m = TaskItem(title: "里程碑 M", kind: .milestone, parentID: g.id)
    project.add(a)
    project.add(g)
    project.add(m)

    let data = try KairoFile.encode(project: project)
    let loaded = try KairoFile.decode(from: data)

    #expect(loaded.metadata.title == "示例项目")
    #expect(loaded.metadata.id == project.metadata.id)
    #expect(Set(loaded.tasks.map(\.id)) == Set([a.id, g.id, m.id]))
    #expect(loaded.tasksByID[m.id]?.parentID == g.id)
    #expect(loaded.tasksByID[m.id]?.kind == .milestone)
}

@Test func encodeProducesSingleJSONWithVersionAndRootKeys() throws {
    let project = Project()
    project.add(TaskItem(title: "任务"))
    let data = try KairoFile.encode(project: project)

    let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
    #expect(object?["formatVersion"] as? Int == KairoFile.currentFormatVersion)
    #expect(object?["project"] is [String: Any])
    #expect((object?["tasks"] as? [[String: Any]])?.count == 1)
}

@Test func dependencyAndMilestoneSurviveRoundTrip() throws {
    let project = Project()
    let a = TaskItem(title: "前置任务")
    let b = TaskItem(
        title: "后续任务",
        kind: .task,
        effortHours: 8,
        durationDays: 2,
        dependencies: [TaskDependency(predecessorID: a.id, type: .ss, lagDays: 1)]
    )
    project.add(a)
    project.add(b)

    let data = try KairoFile.encode(project: project)
    let loaded = try KairoFile.decode(from: data)

    let loadedB = loaded.tasksByID[b.id]
    #expect(loadedB?.effortHours == 8)
    #expect(loadedB?.durationDays == 2)
    #expect(loadedB?.dependencies == [TaskDependency(predecessorID: a.id, type: .ss, lagDays: 1)])
}

// MARK: - 兼容规则（ADR-011）

@Test func decodeIgnoresUnknownFields() throws {
    let json = """
    {
      "formatVersion": 1,
      "project": { "id": "\(UUID().uuidString)", "title": "T", "createdAt": "2026-10-17T00:00:00Z", "updatedAt": "2026-10-17T00:00:00Z" },
      "tasks": [],
      "futureField": { "anything": true }
    }
    """
    let project = try KairoFile.decode(from: Data(json.utf8))
    #expect(project.tasks.isEmpty)
    #expect(project.metadata.title == "T")
}

@Test func unsupportedFormatVersionThrows() throws {
    let json = """
    {
      "formatVersion": 999,
      "project": { "id": "\(UUID().uuidString)", "title": "T", "createdAt": "2026-10-17T00:00:00Z", "updatedAt": "2026-10-17T00:00:00Z" },
      "tasks": []
    }
    """
    #expect(throws: KairoFileError.unsupportedFormatVersion(999)) {
        _ = try KairoFile.decode(from: Data(json.utf8))
    }
}

@Test func saveToURLAndLoadFromURL() throws {
    let project = Project()
    project.metadata.title = "磁盘往返"
    project.add(TaskItem(title: "持久任务", kind: .group))

    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-test-\(UUID().uuidString).kairo")
    defer { try? FileManager.default.removeItem(at: url) }

    try KairoFile.save(project, to: url)
    let loaded = try KairoFile.load(from: url)
    #expect(loaded.metadata.title == "磁盘往返")
    #expect(loaded.tasks.count == 1)
}

import Foundation
import Testing

@testable import ZenoCore

// MARK: - 夹具

private let utcCalendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func utcDay(_ year: Int, _ month: Int, _ day: Int) -> Date {
    utcCalendar.date(from: DateComponents(year: year, month: month, day: day))!
}

private func makeBaseline() -> Baseline {
    let first = UUID()
    let second = UUID()
    return Baseline(
        name: "基线 1 · 2026-10-25",
        createdAt: utcDay(2026, 10, 25),
        anchor: utcDay(2026, 10, 20),
        entries: [
            BaselineEntry(
                taskID: first,
                start: utcDay(2026, 11, 2),
                finish: utcDay(2026, 11, 5),
                progress: 0.25,
                isMilestone: false
            ),
            BaselineEntry(
                taskID: second,
                start: utcDay(2026, 11, 5),
                finish: utcDay(2026, 11, 5),
                progress: 0,
                isMilestone: true
            ),
        ]
    )
}

private func encode(_ baseline: Baseline) throws -> [String: Any] {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let data = try encoder.encode(baseline)
    return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - 判据 2：基线不可变 → 模型只有值语义，往返必须逐字段相等

@Test func baselineRoundTripsThroughCodable() throws {
    let baseline = makeBaseline()
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let decoded = try decoder.decode(Baseline.self, from: encoder.encode(baseline))

    #expect(decoded == baseline)
    #expect(decoded.id == baseline.id)
    #expect(decoded.entries.count == 2)
    #expect(decoded.entries[1].isMilestone)
    #expect(decoded.anchor == baseline.anchor)
}

@Test func entryEncodesExactlyTheFiveFields() throws {
    let object = try encode(makeBaseline())
    let entries = try #require(object["entries"] as? [[String: Any]])
    let first = try #require(entries.first)

    #expect(Set(first.keys) == ["taskID", "start", "finish", "progress", "isMilestone"])
}

@Test func baselineOmitsAnchorWhenAbsent() throws {
    let baseline = Baseline(name: "无锚点", createdAt: utcDay(2026, 10, 25))
    let object = try encode(baseline)

    #expect(Set(object.keys) == ["id", "name", "createdAt", "entries"])
}

@Test func entryClampsProgressIntoUnitRange() throws {
    let json = """
    { "taskID": "\(UUID().uuidString)", "start": "2026-11-02T00:00:00Z",
      "finish": "2026-11-03T00:00:00Z", "progress": 1.5, "isMilestone": false }
    """
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    let entry = try decoder.decode(BaselineEntry.self, from: Data(json.utf8))

    #expect(entry.progress == 1)
}

// MARK: - 判据 11：旧文件无 baselines 键 → []

@Test func projectWithoutBaselinesEncodesNoBaselinesKey() throws {
    let project = Project()
    project.tasks = [TaskItem(title: "任务")]

    let data = try ZenoFile.encode(project: project)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    #expect(root["formatVersion"] as? Int == 2)
    // 无基线省略键：凭空写 "baselines": [] 只会给 diff 加噪音（08-baselines §7.3）。
    #expect(root["baselines"] == nil)
}

@Test func projectWithBaselineWritesTopLevelArray() throws {
    let project = Project()
    project.tasks = [TaskItem(title: "任务")]
    project.baselines = [makeBaseline()]

    let data = try ZenoFile.encode(project: project)
    let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])

    // 方案 A：顶级 baselines（与 tasks 平级），不塞进 project 节点（§6）。
    #expect((root["baselines"] as? [[String: Any]])?.count == 1)
    let metadata = try #require(root["project"] as? [String: Any])
    #expect(metadata["baselines"] == nil)
}

@Test func fileWithoutBaselinesKeyDecodesToEmptyArray() throws {
    let project = Project()
    project.tasks = [TaskItem(title: "任务")]
    let encoded = try ZenoFile.encode(project: project)
    var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    root.removeValue(forKey: "baselines")
    let legacy = try JSONSerialization.data(withJSONObject: root)

    let decoded = try ZenoFile.decode(from: legacy)

    #expect(decoded.baselines.isEmpty)
    #expect(decoded.tasks.count == 1)
}

@Test func baselineSurvivesProjectStateRoundTrip() throws {
    let project = Project()
    project.baselines = [makeBaseline()]

    let state = ProjectState(project: project)
    let restored = Project()
    state.apply(to: restored)

    #expect(restored.baselines == project.baselines)
    // 撤销快照本身也要可序列化（App 层测试依赖）。
    let encoded = try JSONEncoder().encode(state)
    #expect(try JSONDecoder().decode(ProjectState.self, from: encoded).baselines == project.baselines)
}

import Foundation
import Testing

@testable import ZenoCommands
@testable import ZenoCore

// MARK: - 夹具

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func makeProject() -> Project {
    let project = Project()
    project.metadata.title = "格式迁移项目"
    project.add(TaskItem(title: "任务 A", durationDays: 2))
    project.add(TaskItem(title: "任务 B"))
    return project
}

/// 当前格式编码后改写版本号，得到「v1 但内容同形」的夹具（v1 没有 baselines 键）。
private func makeV1Data(includeResources: Bool = true) throws -> Data {
    let encoded = try ZenoFile.encode(project: makeProject())
    var root = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    root["formatVersion"] = 1
    root.removeValue(forKey: "baselines")
    if !includeResources {
        root.removeValue(forKey: "resources")
    }
    return try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
}

private func makeV2Data(withBaselines: Bool) throws -> Data {
    let project = makeProject()
    if withBaselines {
        let orphanID = UUID()
        project.baselines = [
            Baseline(
                name: "基线 1 · 2026-10-25",
                createdAt: day(2026, 10, 25),
                anchor: day(2026, 10, 20),
                entries: [
                    BaselineEntry(
                        taskID: project.tasks[0].id,
                        start: day(2026, 11, 2),
                        finish: day(2026, 11, 4),
                        progress: 0.5,
                        isMilestone: false
                    ),
                    // 孤儿条目：任务已删，条目必须保留（08-baselines §5）。
                    BaselineEntry(
                        taskID: orphanID,
                        start: day(2026, 11, 5),
                        finish: day(2026, 11, 6),
                        progress: 0.1,
                        isMilestone: false
                    ),
                ]
            ),
            Baseline(name: "基线 2 · 2026-10-26", createdAt: day(2026, 10, 26)),
        ]
    }
    return try ZenoFile.encode(project: project)
}

private func temporaryURL(_ name: String) -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("zeno-format-\(UUID().uuidString)-\(name)")
}

private func rootObject(of data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

private func capturedError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

// MARK: - 判据 11 / §7.6-1：v1 打开

@Test func versionOneFileOpensWithNeedsUpgradeAndNoBaselines() throws {
    let data = try makeV1Data()

    let decoded = try ZenoFile.read(from: data)

    #expect(decoded.sourceFormatVersion == 1)
    #expect(decoded.project.baselines.isEmpty)
    #expect(decoded.project.tasks.count == 2)
    #expect(ZenoFile.currentFormatVersion == 2)

    let url = temporaryURL("v1.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    try data.write(to: url)
    let session = ZenoSession()
    _ = try session.openProject(at: url)

    #expect(session.sourceFormatVersion == 1)
    #expect(session.needsFormatUpgrade)
}

/// 打开不落盘：v1 文件读完后磁盘仍是 v1（08-baselines §7.3）。
@Test func openingVersionOneFileDoesNotRewriteDisk() throws {
    let url = temporaryURL("v1-readonly.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    let data = try makeV1Data()
    try data.write(to: url)

    let session = ZenoSession()
    _ = try session.openProject(at: url)

    #expect(try Data(contentsOf: url) == data)
    #expect(try rootObject(of: Data(contentsOf: url))["formatVersion"] as? Int == 1)
}

// MARK: - §7.6-2：v1 保存 → v2 且无 baselines 键

@Test func savingVersionOneFileWritesVersionTwoWithoutBaselinesKey() throws {
    let url = temporaryURL("upgrade.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    try makeV1Data().write(to: url)
    let session = ZenoSession()
    _ = try session.openProject(at: url)
    let before = try #require(session.project)

    try session.saveProject()

    let saved = try rootObject(of: Data(contentsOf: url))
    #expect(saved["formatVersion"] as? Int == 2)
    // 无基线省略键（§7.3 写出策略）。
    #expect(saved["baselines"] == nil)
    #expect(session.needsFormatUpgrade == false)

    // 元数据 / 任务 / 资源逐字段相等（updatedAt 由保存动作刷新，不参与）。
    let reopened = try ZenoFile.read(from: url).project
    #expect(reopened.metadata.id == before.metadata.id)
    #expect(reopened.metadata.title == before.metadata.title)
    #expect(reopened.metadata.createdAt == before.metadata.createdAt)
    #expect(reopened.metadata.projectStart == before.metadata.projectStart)
    #expect(reopened.metadata.direction == before.metadata.direction)
    #expect(reopened.tasks == before.tasks)
    #expect(reopened.resources == before.resources)
    #expect(reopened.baselines.isEmpty)
}

// MARK: - §7.6-6：v1 同时缺 resources 与 baselines

@Test func versionOneFileWithoutResourcesOrBaselinesFallsBackToDefaults() throws {
    let decoded = try ZenoFile.read(from: try makeV1Data(includeResources: false))

    #expect(decoded.sourceFormatVersion == 1)
    #expect(decoded.project.resources.isEmpty)
    #expect(decoded.project.baselines.isEmpty)
}

// MARK: - §7.6-3：v2 往返（含孤儿）

@Test func versionTwoFileRoundTripsBaselinesIncludingOrphans() throws {
    let url = temporaryURL("v2.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    let original = try makeV2Data(withBaselines: true)
    try original.write(to: url)

    let decoded = try ZenoFile.read(from: url)
    #expect(decoded.sourceFormatVersion == 2)
    #expect(decoded.project.baselines.count == 2)
    #expect(decoded.project.baselines[0].entries.count == 2)

    // 读 → 写 → 读：基线逐字段相等（含孤儿条目）。
    try ZenoFile.save(decoded.project, to: url)
    let reopened = try ZenoFile.read(from: url)

    #expect(reopened.project.baselines == decoded.project.baselines)
    #expect(reopened.project.baselines[0].entries[1].taskID != reopened.project.tasks[0].id)

    let session = ZenoSession()
    _ = try session.openProject(at: url)
    #expect(session.needsFormatUpgrade == false)
    let report = try session.baselineVariance(baselineID: reopened.project.baselines[0].id, now: day(2026, 10, 25))
    #expect(report.orphans.count == 1)
}

@Test func versionTwoFileWithoutBaselinesStillOmitsKey() throws {
    let url = temporaryURL("v2-empty.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    try makeV2Data(withBaselines: false).write(to: url)

    let project = try ZenoFile.read(from: url).project
    #expect(project.baselines.isEmpty)
    try ZenoFile.save(project, to: url)
    #expect(try rootObject(of: Data(contentsOf: url))["baselines"] == nil)
}

// MARK: - §7.6-4：未来版本拒读且不改盘

@Test func futureVersionIsRejectedWithoutTouchingDisk() throws {
    let url = temporaryURL("future.zeno")
    defer { try? FileManager.default.removeItem(at: url) }
    var root = try rootObject(of: try makeV2Data(withBaselines: true))
    root["formatVersion"] = 3
    let bytes = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
    try bytes.write(to: url)

    let error = capturedError { try ZenoFile.read(from: url) }

    #expect((error as? ZenoFileError) == .unsupportedFormatVersion(3))
    let description = (error as? ZenoFileError)?.description ?? ""
    // 文案必须可操作：说明是「更新版本保存的」并给升级指引（§7.4）。
    #expect(description.contains("格式 v3"))
    #expect(description.contains("请升级 Zeno"))
    #expect(try Data(contentsOf: url) == bytes)
}

// MARK: - §7.6-5：迁移层不重建根节点

@Test func migrationPreservesUnknownRootKeys() throws {
    var root = try rootObject(of: try makeV1Data())
    root["futureThing"] = ["anything": true]
    var document = FormatDocument(root: root)

    try FormatMigrationPlan.standard.migrate(from: 1, to: 2, document: &document)

    #expect(document.formatVersion == 2)
    #expect(document.root["futureThing"] as? [String: Bool] == ["anything": true])
    // 迁移只碰版本号：baselines 不凭空写入（缺省 = 空）。
    #expect(document.root["baselines"] == nil)
    #expect((document.root["tasks"] as? [[String: Any]])?.count == 2)
}

@Test func standardPlanReachesCurrentVersionFromOne() throws {
    var document = FormatDocument(root: try rootObject(of: try makeV1Data()))

    try FormatMigrationPlan.standard.migrate(
        from: 1, to: ZenoFile.currentFormatVersion, document: &document
    )

    #expect(document.formatVersion == ZenoFile.currentFormatVersion)
}

// MARK: - 迁移后解码仍在 v1 语义下（实际偏差缺键）

@Test func versionOneFileMissingActualKeysStillDecodes() throws {
    let decoded = try ZenoFile.read(from: try makeV1Data())

    #expect(decoded.project.tasks.allSatisfy { $0.actualStart == nil && $0.completedAt == nil })
}

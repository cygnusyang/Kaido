import Foundation
import Testing

@testable import KairoCommands
@testable import KairoCore

// MARK: - 夹具

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func makeSession() throws -> (KairoSession, Date) {
    let now = day(2026, 10, 25)
    let session = KairoSession()
    _ = try session.createProject(title: "多基线配色", projectStart: day(2026, 11, 2))
    _ = try session.addTask(title: "任务 A", durationDays: 2)
    return (session, now)
}

private func temporaryURL() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-baseline-color-\(UUID().uuidString).kairo")
}

private func capturedError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

/// 旧文件夹具：两条基线都不带 colorIndex（字段缺失 = v0.13 及更早的文件形状）。
private func writeLegacyProject(to url: URL) throws {
    let project = Project()
    project.metadata.title = "旧项目"
    project.metadata.projectStart = day(2026, 11, 2)
    project.baselines = [
        Baseline(name: "旧基线 1", createdAt: day(2026, 10, 1)),
        Baseline(name: "旧基线 2", createdAt: day(2026, 10, 2))
    ]
    try KairoFile.save(project, to: url)
}

// MARK: - 判据：创建时分配索引

@Test func successiveBaselinesTakeSequentialColors() throws {
    let (session, now) = try makeSession()

    let first = try session.createBaseline(now: now)
    let second = try session.createBaseline(now: now)
    let third = try session.createBaseline(now: now)

    #expect([first.colorIndex, second.colorIndex, third.colorIndex] == [0, 1, 2])
}

@Test func deletedMiddleColorIsReusedAndOthersKeepTheirIndex() throws {
    let (session, now) = try makeSession()
    let first = try session.createBaseline(now: now)
    let second = try session.createBaseline(now: now)
    let third = try session.createBaseline(now: now)

    try session.deleteBaseline(id: second.id)
    let recreated = try session.createBaseline(now: now)

    // 空缺的最小索引被复用，已有基线不串色（§4 索引稳定）。
    #expect(recreated.colorIndex == 1)
    let colors = Dictionary(uniqueKeysWithValues: try session.baselines().map { ($0.id, $0.colorIndex) })
    #expect(colors[first.id] == 0)
    #expect(colors[third.id] == 2)
}

// MARK: - 判据：改色

@Test func setBaselineColorPersistsAndUndoesInOneStep() throws {
    let (session, now) = try makeSession()
    let created = try session.createBaseline(now: now)
    #expect(created.colorIndex == 0)
    let before = try session.snapshot()

    let updated = try session.setBaselineColor(id: created.id, colorIndex: 5)

    #expect(updated.colorIndex == 5)
    #expect(try session.baselines().first?.colorIndex == 5)
    #expect(session.hasUnsavedChanges)

    // 一步撤销：既有快照机制整体回滚，改色与创建同等粒度。
    try session.restore(before)
    #expect(try session.baselines().first?.colorIndex == 0)
}

@Test func outOfRangeColorIndexIsRejectedWithoutWriting() throws {
    let (session, now) = try makeSession()
    let created = try session.createBaseline(now: now)
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try session.saveProject(to: url)

    let tooHigh = capturedError { try session.setBaselineColor(id: created.id, colorIndex: BaselinePalette.count) }
    let negative = capturedError { try session.setBaselineColor(id: created.id, colorIndex: -1) }

    #expect((tooHigh as? SessionError)?.code == .invalidArgument)
    #expect((tooHigh as? SessionError)?.reason == .baselineColorIndexInvalid)
    #expect((negative as? SessionError)?.reason == .baselineColorIndexInvalid)
    // 被拒 = 不写库：数据不变，且没有产生新的未保存修改。
    #expect(try session.baselines().first?.colorIndex == 0)
    #expect(session.hasUnsavedChanges == false)
}

// MARK: - 判据：旧数据补色只在写路径

@Test func legacyBaselinesOpenCleanThenGainColorsOnSave() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeLegacyProject(to: url)

    let session = KairoSession()
    _ = try session.openProject(at: url)

    // 打开只读：不补色、不置脏、不改文件。
    #expect(try session.baselines().map(\.colorIndex) == [nil, nil])
    #expect(session.hasUnsavedChanges == false)
    #expect(BaselinePalette.resolve(try session.baselines().map(\.colorIndex)) == [0, 1])

    try session.saveProject()

    let reopened = KairoSession()
    _ = try reopened.openProject(at: url)
    #expect(try reopened.baselines().map(\.colorIndex) == [0, 1])
    #expect(reopened.hasUnsavedChanges == false)
}

// MARK: - 判据：旧数据 + 新建共存不撞色

@Test func newBaselineOnLegacyProjectStaysUniqueAfterSave() throws {
    let url = temporaryURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try writeLegacyProject(to: url)

    let session = KairoSession()
    _ = try session.openProject(at: url)
    // 只读打开旧文件不得置脏：补色只发生在写路径（§4）。
    #expect(session.hasUnsavedChanges == false)

    // 创建入口先按创建顺序补齐旧两条（0、1），新基线才取最小未用（2）——
    // 否则最新一条会抢走首色，与「轨道自上而下 = 创建顺序」的图例不一致。
    let created = try session.createBaseline(now: day(2026, 10, 25))
    #expect(created.colorIndex == 2)
    // 补色属于写操作：这一次创建必须置脏，否则补齐结果会随「没改过」的判断丢掉。
    #expect(session.hasUnsavedChanges)
    #expect(try session.baselines().map(\.colorIndex) == [0, 1, 2])

    try session.saveProject()
    #expect(session.hasUnsavedChanges == false)

    let colors = try session.baselines().compactMap(\.colorIndex)
    #expect(colors == [0, 1, 2])
    #expect(Set(colors).count == 3, "落盘索引必须互不相同，实际 \(colors)")

    // 重开：三条按创建顺序落盘，再次打开不重排、不置脏。
    let reopened = KairoSession()
    _ = try reopened.openProject(at: url)
    #expect(try reopened.baselines().map(\.colorIndex) == [0, 1, 2])
    #expect(reopened.hasUnsavedChanges == false)
}

// MARK: - 判据：改名 / 改色 / 删除入口同样先补色

@Test func legacyBaselinesAreBackfilledByRenameAndColorEdits() throws {
    let renameURL = temporaryURL()
    let colorURL = temporaryURL()
    defer {
        try? FileManager.default.removeItem(at: renameURL)
        try? FileManager.default.removeItem(at: colorURL)
    }

    try writeLegacyProject(to: renameURL)
    let renaming = KairoSession()
    _ = try renaming.openProject(at: renameURL)
    let legacyID = try #require(try renaming.baselines().first?.id)
    try renaming.renameBaseline(id: legacyID, name: "改名后")
    #expect(try renaming.baselines().map(\.colorIndex) == [0, 1])

    try writeLegacyProject(to: colorURL)
    let recoloring = KairoSession()
    _ = try recoloring.openProject(at: colorURL)
    let secondID = try #require(try recoloring.baselines().last?.id)
    try recoloring.setBaselineColor(id: secondID, colorIndex: 5)
    // 先补齐（0、1）再改色：另一条不会被后补的索引顶掉。
    let colors = try recoloring.baselines().map(\.colorIndex)
    #expect(colors == [0, 5])
}

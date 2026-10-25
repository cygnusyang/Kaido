import Foundation
import Testing

@testable import KairoCommands
@testable import KairoCore

// MARK: - 夹具

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

/// 生产侧（`ScheduleEngine` / `BaselineEngine.defaultName`）按当前时区归一日期，
/// 命令层断言必须取同一口径的本地零点，否则「UTC 零点 vs 本地零点」会被误判成缺陷。
private func localDay(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone.current
    return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth))!
}

private func makeSession() throws -> (KairoSession, UUID, Date) {
    let now = day(2026, 10, 25)
    let session = KairoSession()
    _ = try session.createProject(title: "基线项目", projectStart: day(2026, 11, 2))
    let id = try session.addTask(title: "任务 A", durationDays: 2)
    return (session, id, now)
}

private func capturedError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

// MARK: - 判据 1：创建基线

@Test func createBaselineSnapshotsScheduledTasksOnly() throws {
    let (session, firstID, now) = try makeSession()
    let secondID = try session.addTask(title: "任务 B", durationDays: 1)
    // 空群组无法排期：没有时间可比较，不得入条目（08-baselines §3）。
    _ = try session.addTask(title: "空群组", kind: .group)

    let baseline = try session.createBaseline(now: now)

    #expect(baseline.entries.map(\.taskID) == [firstID, secondID])
    #expect(baseline.createdAt == now)
    #expect(baseline.anchor == localDay(2026, 11, 2))
    #expect(baseline.name.hasPrefix("基线 1 · "))
    // 条目时间 = 当时的排期结果（排他端点）。
    #expect(baseline.entries[0].start == localDay(2026, 11, 2))
    #expect(baseline.entries[0].finish == localDay(2026, 11, 4))
}

@Test func secondSnapshotIsAppendedNotOverwritten() throws {
    let (session, _, now) = try makeSession()

    let first = try session.createBaseline(now: now)
    let second = try session.createBaseline(now: now)

    #expect(try session.baselines().map(\.id) == [first.id, second.id])
    #expect(second.name.hasPrefix("基线 2 · "))
}

@Test func createBaselineMarksProjectDirty() throws {
    let (session, _, now) = try makeSession()
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-dirty-\(UUID().uuidString).kairo")
    defer { try? FileManager.default.removeItem(at: url) }
    try session.saveProject(to: url)
    #expect(session.hasUnsavedChanges == false)

    _ = try session.createBaseline(now: now)

    #expect(session.hasUnsavedChanges)
}

// MARK: - 判据 2：不可变

@Test func renameOnlyChangesName() throws {
    let (session, _, now) = try makeSession()
    let created = try session.createBaseline(now: now)

    let renamed = try session.renameBaseline(id: created.id, name: "  承诺 v1  ")

    #expect(renamed.name == "承诺 v1")
    #expect(renamed.id == created.id)
    #expect(renamed.createdAt == created.createdAt)
    #expect(renamed.anchor == created.anchor)
    #expect(renamed.entries == created.entries)
    #expect(try session.baselines().first?.name == "承诺 v1")
}

@Test func emptyBaselineNameIsRejectedWithoutRenaming() throws {
    let (session, _, now) = try makeSession()
    let created = try session.createBaseline(now: now)

    let error = capturedError { try session.renameBaseline(id: created.id, name: "   ") }

    #expect((error as? SessionError)?.reason == .baselineNameEmpty)
    #expect(try session.baselines().first?.name == created.name)
}

@Test func deleteRemovesOnlyTargetBaseline() throws {
    let (session, _, now) = try makeSession()
    let first = try session.createBaseline(now: now)
    let second = try session.createBaseline(now: now)

    try session.deleteBaseline(id: first.id)

    #expect(try session.baselines().map(\.id) == [second.id])
    #expect(try session.baselines().first?.entries == second.entries)
}

@Test func unknownBaselineIDIsReportedStructured() throws {
    let (session, _, _) = try makeSession()

    let renameError = capturedError {
        try session.renameBaseline(id: UUID(), name: "任意")
    }
    let deleteError = capturedError { try session.deleteBaseline(id: UUID()) }
    let varianceError = capturedError { try session.baselineVariance(baselineID: UUID()) }

    #expect((renameError as? SessionError)?.reason == .baselineNotFound)
    #expect((deleteError as? SessionError)?.reason == .baselineNotFound)
    #expect((varianceError as? SessionError)?.reason == .baselineNotFound)
}

@Test func snapshotSurvivesLaterEdits() throws {
    let (session, taskID, now) = try makeSession()
    let created = try session.createBaseline(now: now)

    _ = try session.updateTask(id: taskID, durationDays: 6)

    // 基线是快照：任务改了，基线条目不动。
    #expect(try session.baselines().first?.entries == created.entries)
    let variance = try session.baselineVariance(now: day(2026, 10, 26))
    #expect(variance.tasks[taskID]?.planFinishVariance == 4)
}

// MARK: - 判据 6：偏差带基线标识 + 缺省比较最新

@Test func baselineVarianceDefaultsToLatestBaseline() throws {
    let (session, taskID, now) = try makeSession()
    _ = try session.createBaseline(now: now)
    _ = try session.updateTask(id: taskID, durationDays: 5)
    let latest = try session.createBaseline(now: now)

    let report = try session.baselineVariance(now: now)

    #expect(report.baselineID == latest.id)
    #expect(report.baselineName == latest.name)
    #expect(report.baselineCreatedAt == latest.createdAt)
    // 与最新基线同期拍的快照：计划偏差为 0，而不是 0 掩盖的 nil。
    #expect(report.tasks[taskID]?.planFinishVariance == 0)
}

@Test func varianceWithoutAnyBaselineIsStructuredError() throws {
    let (session, _, _) = try makeSession()

    let error = capturedError { try session.baselineVariance() }

    #expect((error as? SessionError)?.reason == .baselineNotFound)
}

// MARK: - 撤销：createBaseline 进快照

@Test func restoreDropsBaselineCreatedAfterSnapshot() throws {
    let (session, _, now) = try makeSession()
    let before = try session.snapshot()

    _ = try session.createBaseline(now: now)
    #expect(try session.baselines().count == 1)

    try session.restore(before)

    #expect(try session.baselines().isEmpty)
}

@Test func restoreBringsDeletedBaselineBack() throws {
    let (session, _, now) = try makeSession()
    let created = try session.createBaseline(now: now)
    let before = try session.snapshot()

    try session.deleteBaseline(id: created.id)
    try session.restore(before)

    #expect(try session.baselines() == [created])
}

// MARK: - 保存往返

@Test func baselinesSurviveSaveAndReopen() throws {
    let (session, _, now) = try makeSession()
    let created = try session.createBaseline(now: now)
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-baseline-\(UUID().uuidString).kairo")
    defer { try? FileManager.default.removeItem(at: url) }

    try session.saveProject(to: url)
    let reopened = KairoSession()
    _ = try reopened.openProject(at: url)

    #expect(try reopened.baselines() == [created])
}

import Foundation
import Testing
@testable import KairoCore

// MARK: - 合成迁移（仅测试使用）

/// 记录迁移步骤的执行顺序。
private final class MigrationRecorder {
    private(set) var appliedVersions: [Int] = []

    func record(_ version: Int) {
        appliedVersions.append(version)
    }
}

/// 成功迁移：把文档推进到 `toVersion`，并在根节点留下可断言的标记。
private struct RecordingMigration: FormatMigration {
    let toVersion: Int
    let recorder: MigrationRecorder

    func migrate(_ document: inout FormatDocument) throws {
        recorder.record(toVersion)
        document.root["migratedThrough\(toVersion)"] = true
        document.formatVersion = toVersion
    }
}

/// 违规迁移：不更新 `formatVersion`，用于验证管线的每步版本校验。
private struct VersionPreservingMigration: FormatMigration {
    let toVersion: Int

    func migrate(_ document: inout FormatDocument) throws {}
}

private enum SyntheticMigrationFailure: Error, CustomStringConvertible {
    case boom

    var description: String { "合成迁移拒绝继续" }
}

/// 抛错迁移：用于验证错误包装。
private struct ThrowingMigration: FormatMigration {
    let toVersion: Int

    func migrate(_ document: inout FormatDocument) throws {
        throw SyntheticMigrationFailure.boom
    }
}

// MARK: - 夹具

private enum SyntheticFixtureError: Error {
    case invalidRoot
}

private func makeProject(title: String = "迁移测试项目") -> Project {
    let project = Project()
    project.metadata.title = title
    project.add(TaskItem(title: "任务 A"))
    return project
}

/// 由当前格式编码数据构造文档，并把版本改写为任意值（合成旧格式）。
private func makeDocument(from data: Data? = nil, formatVersion: Int) throws -> FormatDocument {
    let encoded = try data ?? KairoFile.encode(project: makeProject())
    guard var root = try JSONSerialization.jsonObject(with: encoded) as? [String: Any] else {
        throw SyntheticFixtureError.invalidRoot
    }
    root["formatVersion"] = formatVersion
    return FormatDocument(root: root)
}

private func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("kairo-migration-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// 捕获错误，便于对 case 与关联值做细致断言。
private func capturedError<T>(_ body: () throws -> T) -> Error? {
    do {
        _ = try body()
        return nil
    } catch {
        return error
    }
}

// MARK: - FR-KAIRO-FMT-1：当前版本不做迁移

@Test func fr_kairo_fmt_1_current_version_skips_migration() throws {
    // 若管线错误地对当前版本执行迁移，该步骤会抛错。
    let plan = FormatMigrationPlan([ThrowingMigration(toVersion: KairoFile.currentFormatVersion + 1)])
    let data = try KairoFile.encode(project: makeProject(title: "当前格式"))

    let decoded = try KairoFile.read(from: data, plan: plan)

    #expect(decoded.sourceFormatVersion == KairoFile.currentFormatVersion)
    #expect(decoded.project.metadata.title == "当前格式")
}

// MARK: - FR-KAIRO-FMT-2：顺序迁移

@Test func fr_kairo_fmt_2_migrates_steps_in_ascending_order() throws {
    let recorder = MigrationRecorder()
    // 故意乱序传入：管线必须按 toVersion 升序执行。
    let plan = FormatMigrationPlan([
        RecordingMigration(toVersion: 2, recorder: recorder),
        RecordingMigration(toVersion: 1, recorder: recorder),
    ])
    var document = try makeDocument(formatVersion: 0)

    try plan.migrate(from: 0, to: 2, document: &document)

    #expect(recorder.appliedVersions == [1, 2])
    #expect(document.formatVersion == 2)
    #expect(document.root["migratedThrough1"] as? Bool == true)
    #expect(document.root["migratedThrough2"] as? Bool == true)
}

@Test func fr_kairo_fmt_2_rejects_missing_step() throws {
    let recorder = MigrationRecorder()
    let plan = FormatMigrationPlan([RecordingMigration(toVersion: 1, recorder: recorder)])
    var document = try makeDocument(formatVersion: 0)

    let error = capturedError {
        try plan.migrate(from: 0, to: 2, document: &document)
    }

    #expect((error as? KairoFileError) == .noMigrationPath(from: 1, to: 2))
    #expect(recorder.appliedVersions == [1])
}

@Test func fr_kairo_fmt_2_rejects_version_skip() throws {
    let recorder = MigrationRecorder()
    // 缺少 toVersion 2 的步骤（1 → 2 段）：即便存在 1 与 3，也不得跳版。
    let plan = FormatMigrationPlan([
        RecordingMigration(toVersion: 1, recorder: recorder),
        RecordingMigration(toVersion: 3, recorder: recorder),
    ])
    var document = try makeDocument(formatVersion: 0)

    let error = capturedError {
        try plan.migrate(from: 0, to: 3, document: &document)
    }

    // 缺失的是 1 → 2 这一段（2 → 3 的步骤虽然存在，也不得跳版）。
    #expect((error as? KairoFileError) == .noMigrationPath(from: 1, to: 2))
    #expect(recorder.appliedVersions == [1])
}

@Test func fr_kairo_fmt_2_step_must_land_on_its_to_version() throws {
    let plan = FormatMigrationPlan([VersionPreservingMigration(toVersion: 1)])
    var document = try makeDocument(formatVersion: 0)

    let error = capturedError {
        try plan.migrate(from: 0, to: 1, document: &document)
    }

    guard let kairoError = error as? KairoFileError,
          case .migrationFailed(let from, let to, let reason) = kairoError else {
        Issue.record("应为 migrationFailed，实际 \(String(describing: error))")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(reason.contains("1"))
}

@Test func fr_kairo_fmt_2_rejects_document_version_mismatch() throws {
    let plan = FormatMigrationPlan([RecordingMigration(toVersion: 1, recorder: MigrationRecorder())])
    var document = try makeDocument(formatVersion: 0)

    let error = capturedError {
        try plan.migrate(from: 1, to: 2, document: &document)
    }

    guard let kairoError = error as? KairoFileError,
          case .migrationFailed(let from, let to, _) = kairoError else {
        Issue.record("应为 migrationFailed，实际 \(String(describing: error))")
        return
    }
    #expect(from == 1)
    #expect(to == 2)
}

// MARK: - FR-KAIRO-FMT-3：未来版本

@Test func fr_kairo_fmt_3_rejects_future_version() throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("future.kairo")
    let encoded = try KairoFile.encode(project: makeProject())
    let object = try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
    var root = try #require(object)
    root["formatVersion"] = 999
    let bytes = try JSONSerialization.data(withJSONObject: root)
    try bytes.write(to: url)

    let error = capturedError { try KairoFile.read(from: url) }

    #expect((error as? KairoFileError) == .unsupportedFormatVersion(999))
    let description = (error as? KairoFileError)?.description ?? ""
    #expect(description.contains("999"))
    #expect(description.contains("\(KairoFile.currentFormatVersion)"))
    // 打开失败不得改动磁盘文件。
    #expect(try Data(contentsOf: url) == bytes)
}

// MARK: - FR-KAIRO-FMT-4：迁移失败

@Test func fr_kairo_fmt_4_throwing_step_is_wrapped_with_from_to() throws {
    let plan = FormatMigrationPlan([ThrowingMigration(toVersion: 1)])
    var document = try makeDocument(formatVersion: 0)

    let error = capturedError {
        try plan.migrate(from: 0, to: 1, document: &document)
    }

    guard let kairoError = error as? KairoFileError,
          case .migrationFailed(let from, let to, let reason) = kairoError else {
        Issue.record("应为 migrationFailed，实际 \(String(describing: error))")
        return
    }
    #expect(from == 0)
    #expect(to == 1)
    #expect(reason.contains("合成迁移拒绝继续"))
}

@Test func fr_kairo_fmt_4_failed_migration_writes_nothing() throws {
    // currentFormatVersion == 1，磁盘上不存在 1 ≤ v < current 的合法旧版本；
    // 这里用合成起点 0 直接驱动迁移管线，验证失败路径无落盘副作用。
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let sourceURL = directory.appendingPathComponent("source.kairo")
    let sourceBytes = try KairoFile.encode(project: makeProject())
    try sourceBytes.write(to: sourceURL)
    var document = try makeDocument(from: sourceBytes, formatVersion: 0)

    let plan = FormatMigrationPlan([ThrowingMigration(toVersion: 1)])
    _ = capturedError { try plan.migrate(from: 0, to: 1, document: &document) }

    #expect(try Data(contentsOf: sourceURL) == sourceBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["source.kairo"])
}

// MARK: - 无效 formatVersion：缺失 / 非整数 / ≤0

@Test func fr_kairo_fmt_malformed_missing_version_is_rejected_without_migration() throws {
    let recorder = MigrationRecorder()
    let plan = FormatMigrationPlan([RecordingMigration(toVersion: 1, recorder: recorder)])
    let json = #"{"project":{},"tasks":[]}"#

    let error = capturedError {
        try KairoFile.read(from: Data(json.utf8), plan: plan)
    }

    guard let kairoError = error as? KairoFileError,
          case .malformedFormatVersion = kairoError else {
        Issue.record("应为 malformedFormatVersion，实际 \(String(describing: error))")
        return
    }
    #expect(recorder.appliedVersions.isEmpty)
}

@Test(arguments: [
    #"{"formatVersion":"1","project":{},"tasks":[]}"#,
    #"{"formatVersion":1.5,"project":{},"tasks":[]}"#,
    #"{"formatVersion":true,"project":{},"tasks":[]}"#,
])
func fr_kairo_fmt_malformed_non_integer_version_is_rejected(json: String) throws {
    let error = capturedError {
        try KairoFile.read(from: Data(json.utf8))
    }

    guard let kairoError = error as? KairoFileError,
          case .malformedFormatVersion = kairoError else {
        Issue.record("应为 malformedFormatVersion，实际 \(String(describing: error))")
        return
    }
}

@Test(arguments: [
    #"{"formatVersion":0,"project":{},"tasks":[]}"#,
    #"{"formatVersion":-1,"project":{},"tasks":[]}"#,
])
func fr_kairo_fmt_malformed_non_positive_version_is_rejected(json: String) throws {
    let recorder = MigrationRecorder()
    // 即便存在一个覆盖 1 的迁移步骤，0/-1 也不得被当作旧版本迁移。
    let plan = FormatMigrationPlan([RecordingMigration(toVersion: 1, recorder: recorder)])

    let error = capturedError {
        try KairoFile.read(from: Data(json.utf8), plan: plan)
    }

    guard let kairoError = error as? KairoFileError,
          case .malformedFormatVersion = kairoError else {
        Issue.record("应为 malformedFormatVersion，实际 \(String(describing: error))")
        return
    }
    #expect(recorder.appliedVersions.isEmpty)
}

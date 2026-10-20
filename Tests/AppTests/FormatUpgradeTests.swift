import Foundation
import Testing
import KairoCommands
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 会话与 UI 对「打开的是旧版格式」的感知（FR-KAIRO-FMT-1/2/5/6，App 侧）。
///
/// 当前格式为 v1，磁盘上不存在可迁移的更旧版本；旧版本场景用注入 loader
/// 返回 `sourceFormatVersion = current - 1` 的 `DecodedProject` 模拟，
/// KairoCore 端到端迁移由 KairoCoreTests 覆盖，待 v2 落地后改为真实旧文件。
@MainActor
@Suite("格式版本升级（App）")
struct FormatUpgradeTests {
    private func makeStore(
        projectLoader: @escaping @Sendable (URL) throws -> DecodedProject = {
            try KairoFile.read(from: $0)
        }
    ) -> WorkspaceStore {
        let suite = "kairo.apptests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, projectLoader: projectLoader)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-format-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 写出一个当前版本的合法项目文件，供打开路径使用。
    private func writeProject(at url: URL, title: String) throws {
        let writer = makeStore()
        writer.dispatch(.setProjectTitle(title))
        writer.save(to: url)
        #expect(writer.alertMessage == nil)
    }

    /// 模拟旧版来源：项目内容来自真实文件，但声明上一版本。
    private func oldVersionLoader() -> @Sendable (URL) throws -> DecodedProject {
        { url in
            let decoded = try KairoFile.read(from: url)
            return DecodedProject(
                project: decoded.project,
                sourceFormatVersion: KairoFile.currentFormatVersion - 1
            )
        }
    }

    private func waitUntilLoaded(_ store: WorkspaceStore) async throws {
        let deadline = Date().addingTimeInterval(5)
        while store.isLoading && Date() < deadline {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(!store.isLoading)
    }

    private func openSimulatedOldVersion(_ url: URL) async throws -> WorkspaceStore {
        let store = makeStore(projectLoader: oldVersionLoader())
        store.openAsync(url: url)
        try await waitUntilLoaded(store)
        return store
    }

    private func fileFormatVersion(_ url: URL) throws -> Int {
        let data = try Data(contentsOf: url)
        let json = try #require(
            try JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        return try #require(json["formatVersion"] as? Int)
    }

    // MARK: - FMT-1：当前版本不标记升级

    @Test func fr_kairo_fmt_1_current_version_is_not_flagged() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("current.kairo")
        try writeProject(at: url, title: "当前版本")

        let store = makeStore()
        #expect(store.open(url: url))

        #expect(!store.needsFormatUpgrade)
        #expect(store.notice?.contains("已升级") != true)
    }

    /// 打开失败按原因映射错误码：损坏/迁移失败为 file_unreadable，未来版本为 unsupported_format。
    @Test func fr_kairo_fmt_2_open_project_maps_error_codes() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let malformed = directory.appendingPathComponent("missing-version.kairo")
        try Data(#"{"project":{},"tasks":[]}"#.utf8).write(to: malformed)
        let malformedError = try #require(
            Self.openError(malformed)
        )
        #expect(malformedError.code == .fileUnreadable)
        #expect(malformedError.message.contains("formatVersion"))

        let future = directory.appendingPathComponent("future.kairo")
        try Data(#"{"formatVersion":999,"project":{},"tasks":[]}"#.utf8).write(to: future)
        let futureError = try #require(
            Self.openError(future)
        )
        #expect(futureError.code == .unsupportedFormat)
        #expect(futureError.message.contains("999"))

        let invalidJSON = directory.appendingPathComponent("not-json.kairo")
        try Data("not a kairo document".utf8).write(to: invalidJSON)
        let invalidJSONError = try #require(
            Self.openError(invalidJSON)
        )
        #expect(invalidJSONError.code == .fileUnreadable)
    }

    private static func openError(_ url: URL) -> SessionError? {
        do {
            _ = try KairoSession().openProject(at: url)
            return nil
        } catch let error as SessionError {
            return error
        } catch {
            return nil
        }
    }

    // MARK: - FMT-2：旧版本打开被标记，且不静默改写磁盘

    @Test func fr_kairo_fmt_2_old_version_is_flagged_on_open() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.kairo")
        try writeProject(at: url, title: "旧版项目")
        let bytesBeforeOpen = try Data(contentsOf: url)

        let store = try await openSimulatedOldVersion(url)

        #expect(store.needsFormatUpgrade)
        #expect(store.exportProject.metadata.title == "旧版项目")
        // 打开不写盘：升级只发生在保存/另存为。
        #expect(try Data(contentsOf: url) == bytesBeforeOpen)
        #expect(store.notice?.contains("已升级") != true)
    }

    // MARK: - FMT-5：保存后提示升级一次

    @Test func fr_kairo_fmt_5_save_after_upgrade_announces_once() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("old.kairo")
        try writeProject(at: url, title: "旧版项目")

        let store = try await openSimulatedOldVersion(url)
        #expect(store.needsFormatUpgrade)

        store.save()

        #expect(!store.needsFormatUpgrade)
        #expect(store.notice == "已升级到 v\(KairoFile.currentFormatVersion)")
        #expect(try fileFormatVersion(url) == KairoFile.currentFormatVersion)

        // 后续保存不再重复提示。
        store.clearNotice()
        store.dispatch(.setProjectTitle("再修改"))
        store.save()
        #expect(store.notice?.contains("已升级") != true)
        #expect(store.notice == nil)
    }

    // MARK: - FMT-6：另存为后提示升级

    @Test func fr_kairo_fmt_6_save_as_after_upgrade_announces() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let originalURL = directory.appendingPathComponent("old.kairo")
        let newURL = directory.appendingPathComponent("upgraded.kairo")
        try writeProject(at: originalURL, title: "旧版项目")

        let store = try await openSimulatedOldVersion(originalURL)
        #expect(store.needsFormatUpgrade)

        store.beginExport()
        let project = Project()
        store.exportState.apply(to: project)
        try KairoFile.encode(project: project).write(to: newURL)
        store.rememberSaveURL(newURL)

        #expect(!store.needsFormatUpgrade)
        #expect(
            store.notice == "已另存为并升级到 v\(KairoFile.currentFormatVersion)"
        )
        #expect(store.projectURL?.standardizedFileURL == newURL.standardizedFileURL)
        #expect(try fileFormatVersion(newURL) == KairoFile.currentFormatVersion)
    }
}

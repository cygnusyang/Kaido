import AppKit
import Foundation
import Testing
import KaidoCommands
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

/// v0.17 稳定性审计的回归断言：保存失败、外部更新与退出守卫。
///
/// 三条硬约束：① 保存失败不得被标成「已保存」；② 外部更新提示不重复弹；
/// ③ 有未保存修改时退出守卫必拦。外部更新一律用独立会话重写磁盘来模拟。
@MainActor
@Suite("保存状态 / 外部更新 / 退出守卫（v0.17 审计）")
struct SaveStateAuditTests {
    private func makeStore(
        projectLoader: @escaping @Sendable (URL) throws -> DecodedProject = {
            try KaidoFile.read(from: $0)
        }
    ) -> WorkspaceStore {
        let suite = "kaido.apptests.audit.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, projectLoader: projectLoader)
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaido-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 用一个独立会话重写磁盘文件，模拟其他进程的保存。
    private func rewriteExternally(_ url: URL, title: String) throws {
        Thread.sleep(forTimeInterval: 0.05)
        let writer = makeStore()
        writer.dispatch(.setProjectTitle(title))
        writer.save(to: url)
        #expect(writer.saveState == .saved)
    }

    // MARK: - 保存失败

    /// 写不进去（父目录不存在）时：失败态必须保留，脏标记不得被清，路径不得被回填。
    @Test func failedSaveNeverReportsSaved() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        store.dispatch(.setProjectTitle("未保存标题"))
        #expect(store.hasUnsavedChanges)

        let unreachable = directory.appendingPathComponent("missing/deeper/broken.kaido")
        store.save(to: unreachable)

        #expect(store.saveState == .failed)
        #expect(store.hasUnsavedChanges)
        #expect(store.alertMessage != nil)
        #expect(store.projectURL == nil)

        // 失败态是粘滞的：普通刷新不得把它降级成 unsaved / saved。
        store.refresh()
        #expect(store.saveState == .failed)
    }

    /// 保存失败不得动到上一次成功落盘的文件与路径；重试成功后才转为已保存。
    @Test func failedSaveKeepsPreviousFileAndPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("project.kaido")
        let store = makeStore()
        store.save(to: url)
        let original = try Data(contentsOf: url)
        store.dispatch(.setProjectTitle("第二次保存"))

        store.save(to: directory.appendingPathComponent("missing/deeper/broken.kaido"))

        #expect(store.saveState == .failed)
        #expect(store.projectURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(try Data(contentsOf: url) == original)

        store.save()
        #expect(store.saveState == .saved)
        #expect(!store.hasUnsavedChanges)
        #expect(store.exportProject.metadata.title == "第二次保存")
    }

    // MARK: - 外部更新

    /// 同一次外部变更被 2 秒轮询反复看到：横幅只立一次，不弹窗、不刷提示。
    @Test func repeatedChecksDoNotRepeatExternalPrompt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.kaido")
        let store = makeStore()
        store.save(to: url)
        store.dispatch(.setProjectTitle("本地修改"))
        try rewriteExternally(url, title: "外部标题")

        store.checkExternalUpdate()
        #expect(store.externalUpdatePending)
        #expect(store.alertMessage == nil)
        #expect(store.notice == nil)

        store.checkExternalUpdate()
        store.checkExternalUpdate()
        #expect(store.externalUpdatePending)
        #expect(store.alertMessage == nil)
        #expect(store.notice == nil)
    }

    /// 「保留本地」之后，同一份磁盘版本不得再把横幅立起来。
    @Test func keepLocalSilencesTheSameDiskVersion() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.kaido")
        let store = makeStore()
        store.save(to: url)
        store.dispatch(.setProjectTitle("本地修改"))
        try rewriteExternally(url, title: "外部标题")
        store.checkExternalUpdate()
        #expect(store.externalUpdatePending)

        store.dispatch(.keepLocal)
        let noticeAfterKeep = store.notice
        #expect(!store.externalUpdatePending)

        store.checkExternalUpdate()
        #expect(!store.externalUpdatePending)
        #expect(store.notice == noticeAfterKeep)
        #expect(store.exportProject.metadata.title == "本地修改")
    }

    /// 外部刷新失败：项目仍在编辑、仍在最近列表，失败只提示一次。
    @Test func failedExternalReloadKeepsProjectOpenAndRecent() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.kaido")
        let store = makeStore()
        store.save(to: url)
        store.dispatch(.setProjectTitle("本地修改"))
        try Data("not a kaido file".utf8).write(to: url)
        store.checkExternalUpdate()
        #expect(store.externalUpdatePending)

        store.dispatch(.reloadExternal)

        #expect(store.alertMessage != nil)
        #expect(store.projectURL?.standardizedFileURL == url.standardizedFileURL)
        #expect(store.hasUnsavedChanges)
        #expect(store.recentProjects.contains { $0.standardizedFileURL == url.standardizedFileURL })

        store.alertMessage = nil
        store.checkExternalUpdate()
        #expect(store.alertMessage == nil)
    }

    /// 保存覆盖了挂着的外部版本：要明确告诉用户「保留的是本地版本」，不静默清横幅。
    @Test func saveOverPendingExternalUpdateSaysLocalKept() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("external.kaido")
        let store = makeStore()
        store.save(to: url)
        store.dispatch(.setProjectTitle("本地修改"))
        try rewriteExternally(url, title: "外部标题")
        store.checkExternalUpdate()
        #expect(store.externalUpdatePending)

        store.save()

        #expect(store.saveState == .saved)
        #expect(!store.externalUpdatePending)
        #expect(store.notice == I18n.t("alert.kept_local", "Kept the local version"))
        let reloaded = makeStore()
        reloaded.open(url: url)
        #expect(reloaded.exportProject.metadata.title == "本地修改")
    }

    /// 异步打开期间不跑外部轮询：否则旧项目被同步重载，目标文件被挤回「再确认一次」。
    @Test func externalCheckIsSkippedWhileAsyncOpenInFlight() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let currentURL = directory.appendingPathComponent("current.kaido")
        let targetURL = directory.appendingPathComponent("target.kaido")

        let gate = DispatchSemaphore(value: 0)
        let store = makeStore(projectLoader: { url in
            gate.wait()
            return try KaidoFile.read(from: url)
        })
        store.save(to: currentURL)
        let writer = makeStore()
        writer.dispatch(.setProjectTitle("待打开的项目"))
        writer.save(to: targetURL)

        store.openAsync(url: targetURL)
        #expect(store.isLoading)

        // 载入窗口内当前文件被外部改写：轮询必须让位，不得重载旧项目。
        try rewriteExternally(currentURL, title: "载入期间的外部标题")
        store.checkExternalUpdate()
        #expect(store.exportProject.metadata.title != "载入期间的外部标题")
        #expect(store.notice == nil)

        gate.signal()
        await store.awaitPendingOpenForTesting()
        #expect(!store.isLoading)
        #expect(store.pendingOpenURL == nil)
        #expect(store.exportProject.metadata.title == "待打开的项目")
        #expect(store.projectURL?.standardizedFileURL == targetURL.standardizedFileURL)
    }

    // MARK: - 退出守卫

    private func makeAppDelegate(
        _ store: WorkspaceStore,
        choice: AppDelegate.QuitChoice
    ) -> AppDelegate {
        let delegate = AppDelegate()
        delegate.store = store
        delegate.askQuitChoice = { _ in choice }
        delegate.showSaveError = { _ in }
        return delegate
    }

    /// 有未保存修改：必须拦住，取消则留在应用内且内容不变。
    @Test func quitGuardBlocksDirtyProjectAndCancels() throws {
        let store = makeStore()
        store.dispatch(.setProjectTitle("未保存标题"))
        let delegate = makeAppDelegate(store, choice: .cancel)

        #expect(delegate.terminationReply() == .terminateCancel)
        #expect(store.exportProject.metadata.title == "未保存标题")
        #expect(store.hasUnsavedChanges)
    }

    /// 没有未保存修改：不打断用户，直接退。
    @Test func quitGuardTerminatesCleanProjectWithoutPrompt() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = makeStore()
        store.save(to: directory.appendingPathComponent("clean.kaido"))

        let delegate = AppDelegate()
        delegate.store = store
        delegate.askQuitChoice = { _ in
            Issue.record("干净退出不应询问用户")
            return .cancel
        }

        #expect(delegate.terminationReply() == .terminateNow)
    }

    /// 选「保存并退出」：先落盘再退，退出前不得残留脏标记。
    @Test func quitGuardSavesThenQuits() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("saved.kaido")
        let store = makeStore()
        store.save(to: url)
        store.dispatch(.setProjectTitle("退出前保存"))
        let delegate = makeAppDelegate(store, choice: .saveAndQuit)

        #expect(delegate.terminationReply() == .terminateNow)
        #expect(store.saveState == .saved)
        #expect(!store.hasUnsavedChanges)
        let reloaded = makeStore()
        reloaded.open(url: url)
        #expect(reloaded.exportProject.metadata.title == "退出前保存")
    }

    /// 保存失败时必须取消退出，并把失败原因交给提示层（不得退化成「已保存后退出」）。
    @Test func quitGuardCancelsWhenSaveFails() throws {
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("vanishing.kaido")
        let store = makeStore()
        store.save(to: url)
        #expect(store.saveState == .saved)
        store.dispatch(.setProjectTitle("保存会失败"))
        // 目标目录在退出前消失：退出守卫里的那次落盘必然失败。
        try FileManager.default.removeItem(at: directory)

        var shown: String?
        let delegate = makeAppDelegate(store, choice: .saveAndQuit)
        delegate.showSaveError = { shown = $0 }

        #expect(delegate.terminationReply() == .terminateCancel)
        #expect(shown != nil)
        #expect(store.saveState == .failed)
        #expect(store.hasUnsavedChanges)
        // 错误文本已被守卫取走：取消退出后视图不会再补弹一次同样的失败。
        #expect(store.alertMessage == nil)
    }

    /// 尚无保存路径：走「另存为」面板，落盘成功才退出；用户取消面板则留下。
    @Test func quitGuardUsesSavePanelWhenNoPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let targetURL = directory.appendingPathComponent("chosen.kaido")
        let store = makeStore()
        store.dispatch(.setProjectTitle("另存后退出"))

        let delegate = makeAppDelegate(store, choice: .saveAndQuit)
        delegate.chooseSaveURL = { _ in targetURL }
        #expect(delegate.terminationReply() == .terminateNow)
        #expect(store.projectURL?.standardizedFileURL == targetURL.standardizedFileURL)

        let cancelStore = makeStore()
        cancelStore.dispatch(.setProjectTitle("取消另存"))
        let cancelDelegate = makeAppDelegate(cancelStore, choice: .saveAndQuit)
        cancelDelegate.chooseSaveURL = { _ in nil }
        #expect(cancelDelegate.terminationReply() == .terminateCancel)
        #expect(cancelStore.hasUnsavedChanges)
    }
}

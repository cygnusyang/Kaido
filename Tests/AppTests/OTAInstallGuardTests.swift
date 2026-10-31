import Foundation
import Testing
import CryptoKit
import KaidoCore
import KaidoUpdater
@testable import KaidoMacApp

/// issue #17：「退出并安装」永久卡在「正在安装更新」。
///
/// 四条断言对应四条硬约束：
/// ① 装前先把脏状态落盘（保存失败则不启动替换脚本）；
/// ② 武装后退出走旁路（不再弹未保存裁决，否则脚本 60s 等不到退出）；
/// ③ 脚本结果 success=false 必须把面板推出安装态，且清掉 pending 三键；
/// ④ 脚本一个结果都不写也要在超时后离开安装态（面板永不停在无按钮状态）。
@MainActor
@Suite("OTA 安装收口（#17）")
struct OTAInstallGuardTests {
    // MARK: - stubs

    private final class StubFetcher: ManifestFetching, @unchecked Sendable {
        private let data: Data
        init(data: Data) { self.data = data }
        func fetchManifest(from url: URL) async throws -> Data { data }
    }

    private final class StubDownloader: DataDownloading, @unchecked Sendable {
        private let archiveURL: URL
        init(archiveURL: URL) { self.archiveURL = archiveURL }
        func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
            progress(1)
            return archiveURL
        }
    }

    /// 假安装器：按生产顺序先落 pending 三键，再「启动脚本」。
    private final class StubInstaller: Installing, @unchecked Sendable {
        private let appURL = URL(fileURLWithPath: "/tmp/KaidoOTAStub.app")
        private let defaults: UserDefaults
        private let resultPath: String?
        private(set) var performed = 0

        init(defaults: UserDefaults, resultPath: String?) {
            self.defaults = defaults
            self.resultPath = resultPath
        }

        func prepare(downloadedArchive: URL) async throws -> URL { appURL }

        func perform(info: UpdateInfo, downloadedAppURL: URL, currentAppURL: URL) async throws {
            performed += 1
            guard let resultPath else { return }
            defaults.set(resultPath, forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
            defaults.set("/tmp/Kaido-0.app", forKey: ZipAppInstaller.pendingBackupPathDefaultsKey)
            defaults.set("/tmp", forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)
        }
    }

    private final class StubVerifier: ProductVerifying {
        func verifyApp(at url: URL, expectedCdHash: String) throws {}
    }

    // MARK: - 夹具

    private struct Env {
        let defaults: UserDefaults
        let suite: String
        let directory: URL
    }

    private func makeEnv() throws -> Env {
        let suite = "kaido.apptests.ota.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("kaido-ota-apptest-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return Env(defaults: defaults, suite: suite, directory: directory)
    }

    private func tearDown(_ env: Env) {
        env.defaults.removePersistentDomain(forName: env.suite)
        try? FileManager.default.removeItem(at: env.directory)
    }

    /// 走到 .downloaded 的 manager：真验签清单 + 假下载/假安装（不联网、不落脚本）。
    private func makeManager(
        _ env: Env,
        resultPath: String?,
        watchTimeout: TimeInterval = 10,
        watchInterval: TimeInterval = 0.02
    ) async throws -> (UpdaterManager, StubInstaller) {
        let archiveURL = env.directory.appendingPathComponent("Kaido-1.1.0.zip")
        try Data("stub".utf8).write(to: archiveURL)

        let key = Curve25519.Signing.PrivateKey()
        var dict: [String: Any] = [
            "schemaVersion": 1,
            "appId": "app.kaido.test",
            "version": "1.1.0",
            "minimumVersion": "1.0.0",
            "buildTime": "2026-10-20T08:00:00Z",
            "downloadUrl": "https://github.com/example/test/releases/download/v1.1.0/Kaido-1.1.0.zip",
            "cdHash": String(repeating: "a", count: 40),
            "securityCritical": false,
            "sha256": try UpdateChecksum.sha256Hex(of: archiveURL),
        ]
        dict["signature"] = try ManifestVerifier.sign(
            canonicalDict: dict,
            privateKeyBase64: Data(key.rawRepresentation).base64EncodedString())

        let installer = StubInstaller(defaults: env.defaults, resultPath: resultPath)
        let manager = UpdaterManager(
            manifestURL: URL(string: "https://github.com/example/test/releases/latest/download/update-manifest.json")!,
            expectedAppId: "app.kaido.test",
            currentVersion: "1.0.0",
            currentAppURL: URL(fileURLWithPath: "/Applications/Kaido.app"),
            publicKeyBase64: Data(key.publicKey.rawRepresentation).base64EncodedString(),
            policy: UpdateEndpointPolicy(allowedHosts: ["github.com"]),
            fetcher: StubFetcher(data: try ManifestVerifier.canonicalJSONData(dict)),
            downloader: StubDownloader(archiveURL: archiveURL),
            installer: installer,
            verifier: StubVerifier(),
            userDefaults: env.defaults,
            installWatchTimeout: watchTimeout,
            installWatchInterval: watchInterval)
        await manager.check()
        await manager.download()
        return (manager, installer)
    }

    private func makeStore() -> WorkspaceStore {
        let suite = "kaido.apptests.ota.store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @MainActor () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return condition()
    }

    private func isInstalling(_ manager: UpdaterManager) -> Bool {
        if case .installing = manager.state { return true }
        return false
    }

    private func isFailed(_ manager: UpdaterManager) -> Bool {
        if case .failed = manager.state { return true }
        return false
    }

    // MARK: - ① 装前先存

    @Test func dirtyProjectIsSavedBeforeScriptLaunch() async throws {
        let env = try makeEnv()
        defer { tearDown(env) }
        let (updater, installer) = try await makeManager(env, resultPath: nil)

        let projectURL = env.directory.appendingPathComponent("dirty.kaido")
        let store = makeStore()
        store.save(to: projectURL)
        store.dispatch(.setProjectTitle("装前保存"))
        #expect(store.hasUnsavedChanges)

        await updater.install(preflight: { OTAInstallPreflight.run(store: store) })

        #expect(installer.performed == 1)
        #expect(isInstalling(updater))
        #expect(updater.isInstallingUpdate)
        #expect(store.saveState == .saved)
        #expect(!store.hasUnsavedChanges)
        let reloaded = makeStore()
        reloaded.open(url: projectURL)
        #expect(reloaded.exportProject.metadata.title == "装前保存")
    }

    // MARK: - ② 保存失败：不启动脚本，面板进 failed

    @Test func saveFailureBlocksInstallAndShowsFailed() async throws {
        let env = try makeEnv()
        defer { tearDown(env) }
        let (updater, installer) = try await makeManager(env, resultPath: nil)

        let projectURL = env.directory.appendingPathComponent("vanishing.kaido")
        let store = makeStore()
        store.save(to: projectURL)
        store.dispatch(.setProjectTitle("保存会失败"))
        // 目标目录在安装前消失：装前那次落盘必然失败。
        try FileManager.default.removeItem(at: env.directory)

        await updater.install(preflight: { OTAInstallPreflight.run(store: store) })

        #expect(installer.performed == 0)
        #expect(!updater.isInstallingUpdate)
        guard case .failed(let failure) = updater.state else {
            Issue.record("期望 failed，实际 \(updater.state)")
            return
        }
        #expect(failure.code == .installSaveFailed)
        #expect(failure.parameters["detail"] != nil)
        // 失败原因交给面板：不再留给退出守卫弹模态（也避免同一失败弹两次）。
        #expect(store.alertMessage == nil)
        #expect(store.hasUnsavedChanges)
    }

    // MARK: - ③ 武装后退出走旁路

    @Test func armedInstallBypassesUnsavedChangesQuitGuard() async throws {
        let env = try makeEnv()
        defer { tearDown(env) }

        let store = makeStore()
        store.dispatch(.setProjectTitle("未保存标题"))
        let delegate = AppDelegate()
        delegate.store = store
        delegate.askQuitChoice = { _ in .cancel }

        // 对照：未武装时脏项目仍被拦（退出守卫没有被削弱）。
        #expect(delegate.terminationReply() == .terminateCancel)

        let (updater, _) = try await makeManager(env, resultPath: nil)
        await updater.install()
        #expect(updater.isInstallingUpdate)

        delegate.updater = updater
        #expect(delegate.terminationReply() == .terminateNow)
    }

    // MARK: - ④ 脚本结果 success=false → 面板 failed 且可关闭

    @Test func failureResultFileDrivesPanelOutOfInstalling() async throws {
        let env = try makeEnv()
        defer { tearDown(env) }
        let resultPath = env.directory.appendingPathComponent("kaido-ota-result-test.json").path
        let (updater, installer) = try await makeManager(env, resultPath: resultPath)

        await updater.install()
        #expect(installer.performed == 1)
        #expect(isInstalling(updater))

        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 4, message: "app_not_quitting")
        ).write(to: URL(fileURLWithPath: resultPath))

        let moved = await waitUntil { self.isFailed(updater) }
        #expect(moved, "结果文件写出后必须离开安装态")
        guard case .failed(let failure) = updater.state else {
            Issue.record("期望 failed，实际 \(updater.state)")
            return
        }
        #expect(failure.code == .installAppStillRunning)
        #expect(failure.parameters["exitCode"] == "4")
        #expect(!updater.isInstallingUpdate)
        // 失败已在面板呈现：pending 三键必须清掉，下次启动不再消费同一个失败。
        for key in [
            ZipAppInstaller.pendingResultPathDefaultsKey,
            ZipAppInstaller.pendingBackupPathDefaultsKey,
            ZipAppInstaller.pendingBackupDirDefaultsKey,
        ] {
            #expect(env.defaults.string(forKey: key) == nil, "pending key 未清理：\(key)")
        }
    }

    // MARK: - ⑤ 超时兜底

    @Test func missingResultTimesOutOfInstalling() async throws {
        let env = try makeEnv()
        defer { tearDown(env) }
        let (updater, _) = try await makeManager(
            env,
            resultPath: env.directory.appendingPathComponent("never-written.json").path,
            watchTimeout: 0.2,
            watchInterval: 0.02)

        await updater.install()
        #expect(isInstalling(updater))

        let start = Date()
        let moved = await waitUntil(timeout: 2) { self.isFailed(updater) }
        #expect(moved, "脚本一个结果都不写时也必须离开安装态")
        #expect(Date().timeIntervalSince(start) < 1.5)
        guard case .failed(let failure) = updater.state else {
            Issue.record("期望 failed，实际 \(updater.state)")
            return
        }
        #expect(failure.code == .installTimeout)
        #expect(!updater.isInstallingUpdate)
    }
}

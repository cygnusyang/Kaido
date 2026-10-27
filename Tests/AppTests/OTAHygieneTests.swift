import Foundation
import Testing
import CryptoKit
import KairoUpdater

/// issue #19 / #20 / #21：OTA 三条尾巴。
///
/// ① 失败与超时路径必须清掉本次安装的临时产物（解压目录 / 脚本 / result / 下载 zip），
///    且备份目录一律保留（那是脚本回滚依据）；
/// ② 首启消费到的安装失败要被标成「未读」，启动 5s 自动检查不得覆盖它；
/// ③ 检查/下载必须能真取消（任务停、半成品清、回 idle），且「收起面板」不等于取消。
@MainActor
@Suite("OTA 清理 / 未读失败 / 取消（#19 #20 #21）")
struct OTAHygieneTests {
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

    /// 挂起的下载器：一直不返回，直到被取消（模拟大包下载中被用户取消）。
    private final class GateDownloader: DataDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var cancelled = false
        private let archiveURL: URL

        init(archiveURL: URL) { self.archiveURL = archiveURL }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
            progress(0.2)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    if cancelled {
                        lock.unlock()
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    self.continuation = continuation
                    lock.unlock()
                }
            } onCancel: {
                lock.lock()
                cancelled = true
                let pending = continuation
                continuation = nil
                lock.unlock()
                pending?.resume(throwing: CancellationError())
            }
        }

        /// 模拟下载正常跑完。
        func finish() {
            lock.lock()
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: archiveURL)
        }
    }

    /// 按生产顺序落 pending 键（含脚本与解压目录路径）的假安装器。
    private final class StubInstaller: Installing, @unchecked Sendable {
        let products: Products
        let defaults: UserDefaults
        private(set) var performed = 0

        init(products: Products, defaults: UserDefaults) {
            self.products = products
            self.defaults = defaults
        }

        func prepare(downloadedArchive: URL) async throws -> URL { products.extractionApp }

        func perform(info: UpdateInfo, downloadedAppURL: URL, currentAppURL: URL) async throws {
            performed += 1
            try Data("#!/bin/bash\n".utf8).write(to: products.script)
            defaults.set(products.result.path, forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
            defaults.set(products.backup.path, forKey: ZipAppInstaller.pendingBackupPathDefaultsKey)
            defaults.set(products.backupDir.path, forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)
            defaults.set(products.script.path, forKey: ZipAppInstaller.pendingScriptPathDefaultsKey)
            defaults.set(products.extractionApp.path, forKey: ZipAppInstaller.pendingExtractionPathDefaultsKey)
        }
    }

    private final class StubVerifier: ProductVerifying {
        func verifyApp(at url: URL, expectedCdHash: String) throws {}
    }

    // MARK: - 夹具

    private struct Env {
        let defaults: UserDefaults
        let suite: String
        let root: URL
    }

    /// 一次安装会留下的全部产物（路径形状与生产完全一致）。
    private struct Products {
        let extractionDir: URL
        let extractionApp: URL
        let archive: URL
        let backupDir: URL
        let backup: URL
        let script: URL
        let result: URL
    }

    private func makeEnv() throws -> Env {
        let suite = "kairo.apptests.ota.hygiene.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-ota-hygiene-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return Env(defaults: defaults, suite: suite, root: root)
    }

    private func tearDown(_ env: Env, _ products: Products? = nil) {
        env.defaults.removePersistentDomain(forName: env.suite)
        try? FileManager.default.removeItem(at: env.root)
        if let products {
            try? FileManager.default.removeItem(at: products.extractionDir)
            try? FileManager.default.removeItem(at: products.archive)
        }
    }

    private func makeProducts(_ env: Env) throws -> Products {
        let fm = FileManager.default
        let extractionDir = fm.temporaryDirectory
            .appendingPathComponent("kairo-ota-\(UUID().uuidString)", isDirectory: true)
        let extractionApp = extractionDir.appendingPathComponent("Kairo.app", isDirectory: true)
        try fm.createDirectory(
            at: extractionApp.appendingPathComponent("Contents/MacOS"), withIntermediateDirectories: true)
        let archive = fm.temporaryDirectory
            .appendingPathComponent("kairo-ota-download-\(UUID().uuidString).zip")
        try Data("stub".utf8).write(to: archive)
        let backup = env.root.appendingPathComponent("Kairo-1700000000.app", isDirectory: true)
        try fm.createDirectory(at: backup, withIntermediateDirectories: true)
        return Products(
            extractionDir: extractionDir,
            extractionApp: extractionApp,
            archive: archive,
            backupDir: env.root,
            backup: backup,
            script: env.root.appendingPathComponent("kairo-ota-install-\(UUID().uuidString).sh"),
            result: env.root.appendingPathComponent("kairo-ota-result-\(UUID().uuidString).json"))
    }

    /// 真签名清单（版本 1.1.0，当前版本 1.0.0）：check() 会走到「有新版本」。
    private func makeManifest(archive: URL) throws -> (data: Data, publicKeyBase64: String) {
        let key = Curve25519.Signing.PrivateKey()
        var dict: [String: Any] = [
            "schemaVersion": 1,
            "appId": "app.kairo.test",
            "version": "1.1.0",
            "minimumVersion": "1.0.0",
            "buildTime": "2026-10-20T08:00:00Z",
            "downloadUrl": "https://github.com/example/test/releases/download/v1.1.0/Kairo-1.1.0.zip",
            "cdHash": String(repeating: "a", count: 40),
            "securityCritical": false,
            "sha256": try UpdateChecksum.sha256Hex(of: archive),
        ]
        dict["signature"] = try ManifestVerifier.sign(
            canonicalDict: dict,
            privateKeyBase64: Data(key.rawRepresentation).base64EncodedString())
        return (
            try ManifestVerifier.canonicalJSONData(dict),
            Data(key.publicKey.rawRepresentation).base64EncodedString())
    }

    private func makeManager(
        _ env: Env,
        manifest: (data: Data, publicKeyBase64: String),
        downloader: DataDownloading,
        installer: Installing,
        watchTimeout: TimeInterval = 10,
        watchInterval: TimeInterval = 0.02
    ) -> UpdaterManager {
        UpdaterManager(
            manifestURL: URL(string: "https://github.com/example/test/releases/latest/download/update-manifest.json")!,
            expectedAppId: "app.kairo.test",
            currentVersion: "1.0.0",
            currentAppURL: URL(fileURLWithPath: "/Applications/Kairo.app"),
            publicKeyBase64: manifest.publicKeyBase64,
            policy: UpdateEndpointPolicy(allowedHosts: ["github.com"]),
            fetcher: StubFetcher(data: manifest.data),
            downloader: downloader,
            installer: installer,
            verifier: StubVerifier(),
            userDefaults: env.defaults,
            installWatchTimeout: watchTimeout,
            installWatchInterval: watchInterval)
    }

    /// 走到 installing 态的 manager（假安装器已落 pending 键）。
    private func makeInstallingManager(
        _ env: Env, products: Products, watchTimeout: TimeInterval = 10
    ) async throws -> UpdaterManager {
        let manifest = try makeManifest(archive: products.archive)
        let installer = StubInstaller(products: products, defaults: env.defaults)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: StubDownloader(archiveURL: products.archive),
            installer: installer,
            watchTimeout: watchTimeout)
        await updater.check()
        await updater.download()
        await updater.install()
        return updater
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

    private func isFailed(_ manager: UpdaterManager) -> Bool {
        if case .failed = manager.state { return true }
        return false
    }

    private func isDownloading(_ manager: UpdaterManager) -> Bool {
        if case .downloading = manager.state { return true }
        return false
    }

    // MARK: - #19 失败清理

    @Test func failureCleansTempArtifactsButKeepsBackup() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }
        let updater = try await makeInstallingManager(env, products: products)
        #expect(updater.isInstallingUpdate)

        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 4, message: "app_not_quitting")
        ).write(to: products.result)

        let failed = await waitUntil { self.isFailed(updater) }
        #expect(failed, "脚本写出失败结果后必须离开安装态")

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: products.extractionDir.path), "解压目录必须清掉")
        #expect(!fm.fileExists(atPath: products.script.path), "替换脚本本体必须清掉")
        #expect(!fm.fileExists(atPath: products.result.path), "result 文件必须清掉")
        #expect(!fm.fileExists(atPath: products.archive.path), "下载 zip 必须清掉")
        #expect(fm.fileExists(atPath: products.backup.path), "备份目录是回滚依据，绝不能删")

        for key in [
            ZipAppInstaller.pendingResultPathDefaultsKey,
            ZipAppInstaller.pendingBackupPathDefaultsKey,
            ZipAppInstaller.pendingBackupDirDefaultsKey,
            ZipAppInstaller.pendingScriptPathDefaultsKey,
            ZipAppInstaller.pendingExtractionPathDefaultsKey,
        ] {
            #expect(env.defaults.string(forKey: key) == nil, "pending key 未清理：\(key)")
        }
    }

    // MARK: - #19 超时清理

    @Test func timeoutCleansTempArtifactsButKeepsBackup() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }
        let updater = try await makeInstallingManager(env, products: products, watchTimeout: 0.2)

        let failed = await waitUntil(timeout: 2) { self.isFailed(updater) }
        #expect(failed, "脚本一个结果都不写也必须离开安装态")
        guard case .failed(let failure) = updater.state else {
            Issue.record("期望 failed，实际 \(updater.state)")
            return
        }
        #expect(failure.code == .installTimeout)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: products.extractionDir.path), "超时也要清解压目录")
        #expect(!fm.fileExists(atPath: products.script.path), "超时也要清替换脚本")
        #expect(fm.fileExists(atPath: products.backup.path), "超时不得动备份目录")
    }

    // MARK: - #20 未读失败不被自动检查覆盖

    @Test func unreadInstallFailureSurvivesAutoCheckUntilUserRetries() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        // 预置「上次安装失败」的 pending 状态（模拟重启后的首启消费）。
        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 3, message: "backup_failed")
        ).write(to: products.result)
        env.defaults.set(products.result.path, forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        env.defaults.set(products.backup.path, forKey: ZipAppInstaller.pendingBackupPathDefaultsKey)
        env.defaults.set(products.backupDir.path, forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)
        env.defaults.set(products.script.path, forKey: ZipAppInstaller.pendingScriptPathDefaultsKey)
        env.defaults.set(products.extractionApp.path, forKey: ZipAppInstaller.pendingExtractionPathDefaultsKey)

        let manifest = try makeManifest(archive: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: StubDownloader(archiveURL: products.archive),
            installer: StubInstaller(products: products, defaults: env.defaults))

        updater.consumePendingInstallResult()
        #expect(updater.hasUnreadInstallFailure)
        guard case .failed(let failure) = updater.state else {
            Issue.record("期望 failed，实际 \(updater.state)")
            return
        }
        #expect(failure.code == .installBackupFailed)

        // 启动 5s 自动检查（fetch 能拿到 1.1.0 清单）：不得覆盖未读失败。
        await updater.check()
        #expect(updater.hasUnreadInstallFailure, "自动检查不得清掉未读标记")
        guard case .failed(let stillFailed) = updater.state else {
            Issue.record("未读失败被覆盖成 \(updater.state)")
            return
        }
        #expect(stillFailed.code == .installBackupFailed)

        // 用户显式重试：清标记 → 才允许进入正常检查流程。
        await updater.retry()
        #expect(!updater.hasUnreadInstallFailure)
        guard case .updateAvailable = updater.state else {
            Issue.record("重试后应正常检查，实际 \(updater.state)")
            return
        }
    }

    @Test func dismissClearsUnreadInstallFailureMarker() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 2, message: "replace_failed")
        ).write(to: products.result)
        env.defaults.set(products.result.path, forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        env.defaults.set(products.backupDir.path, forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)

        let manifest = try makeManifest(archive: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: StubDownloader(archiveURL: products.archive),
            installer: StubInstaller(products: products, defaults: env.defaults))

        updater.consumePendingInstallResult()
        #expect(updater.hasUnreadInstallFailure)

        updater.dismiss()
        #expect(!updater.hasUnreadInstallFailure, "用户显式关闭即视为已读")
        #expect(updater.state == .idle)
    }

    // MARK: - #21 真取消

    @Test func cancelStopsDownloadAndReturnsToIdle() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let manifest = try makeManifest(archive: products.archive)
        let downloader = GateDownloader(archiveURL: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: downloader,
            installer: StubInstaller(products: products, defaults: env.defaults))

        await updater.check()
        let flight = Task { await updater.download() }
        let downloading = await waitUntil { self.isDownloading(updater) }
        #expect(downloading, "应进入下载态")

        updater.cancel()
        #expect(updater.state == .idle, "取消后必须回到 idle")
        await flight.value
        #expect(downloader.wasCancelled, "底层下载任务必须被真正取消")

        // 被取消的旧任务不得回写状态（否则面板会「复活」成下载中/失败）。
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(updater.state == .idle)
    }

    @Test func cancelAfterDownloadRemovesPreparedProduct() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let manifest = try makeManifest(archive: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: StubDownloader(archiveURL: products.archive),
            installer: StubInstaller(products: products, defaults: env.defaults))
        await updater.check()
        await updater.download()
        #expect(updater.state == .downloaded)
        #expect(FileManager.default.fileExists(atPath: products.extractionDir.path))

        updater.cancel()
        #expect(updater.state == .idle)
        #expect(!FileManager.default.fileExists(atPath: products.extractionDir.path), "取消要清解压产物")
    }

    @Test func closingPanelDoesNotCancelDownload() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let manifest = try makeManifest(archive: products.archive)
        let downloader = GateDownloader(archiveURL: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: downloader,
            installer: StubInstaller(products: products, defaults: env.defaults))

        await updater.check()
        let flight = Task { await updater.download() }
        #expect(await waitUntil { self.isDownloading(updater) })

        // 「关闭」= 收起面板：任务不受影响，下载继续跑到完成。
        updater.dismiss()
        #expect(isDownloading(updater), "收起面板不得改变下载态")
        #expect(!downloader.wasCancelled, "收起面板不得取消下载")

        downloader.finish()
        await flight.value
        #expect(updater.state == .downloaded, "收起面板后下载应照常完成")
    }
}

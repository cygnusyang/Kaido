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

    /// 挂起的下载器：一直不返回，直到被取消或被放行（模拟大包下载中被用户取消）。
    ///
    /// 两条纪律，缺一条用例就会永久挂住（v1.3.2 CI 现场）：
    /// ① **信号不丢**：放行与被取消都可能早于 download 注册 continuation 到达——
    ///    并行全量下主 actor 被上千个用例争用，Task 的启动可以推迟数秒。两个信号都
    ///    先记成状态，后到的注册立即兑现，绝不静默丢弃。
    /// ② **时序由事件驱动**：waitUntilStarted() 是无超时的显式「已进入下载」信号。
    ///    原先靠轮询 published state + 3s 截止，满载时会假失败，用例随即按错误的前置
    ///    条件调用 finish/cancel，最后永久等一个再也不会被 resume 的 continuation。
    private final class GateDownloader: DataDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<URL, Error>?
        private var startedWaiters: [CheckedContinuation<Void, Never>] = []
        private var started = false
        private var cancelled = false
        private var finished = false
        private let archiveURL: URL

        init(archiveURL: URL) { self.archiveURL = archiveURL }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        /// 等到 download 真正进来并挂起为止（无超时；由下载器事件唤醒）。
        func waitUntilStarted() async {
            await withCheckedContinuation { waiter in
                lock.lock()
                if started {
                    lock.unlock()
                    waiter.resume()
                    return
                }
                startedWaiters.append(waiter)
                lock.unlock()
            }
        }

        func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
            progress(0.2)
            return try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    lock.lock()
                    started = true
                    let waiters = startedWaiters
                    startedWaiters.removeAll()
                    if cancelled {
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    if finished {
                        // 放行早于注册：立即兑现，否则这个 continuation 永远不会被 resume。
                        lock.unlock()
                        waiters.forEach { $0.resume() }
                        continuation.resume(returning: archiveURL)
                        return
                    }
                    self.continuation = continuation
                    lock.unlock()
                    waiters.forEach { $0.resume() }
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

        /// 模拟下载正常跑完。早于注册到达时记下来，注册那一刻立即兑现。
        func finish() {
            lock.lock()
            finished = true
            let pending = continuation
            continuation = nil
            lock.unlock()
            pending?.resume(returning: archiveURL)
        }
    }

    /// 只记「有没有真的开始下载」的下载器（issue #28：取消后不得再发起下载）。
    private final class SpyDownloader: DataDownloading, @unchecked Sendable {
        private let lock = NSLock()
        private var starts = 0
        private let archiveURL: URL

        init(archiveURL: URL) { self.archiveURL = archiveURL }

        var startCount: Int {
            lock.lock()
            defer { lock.unlock() }
            return starts
        }

        func download(from url: URL, progress: @escaping (Double) -> Void) async throws -> URL {
            noteStart()
            progress(1)
            return archiveURL
        }

        /// 计数在同步上下文里做（NSLock 的 lock/unlock 不进 async 上下文，避免可选性警告）。
        private func noteStart() {
            lock.lock()
            defer { lock.unlock() }
            starts += 1
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
        // 等下载器真正进来，不靠轮询 published state：满载下 3s 轮询会假失败，
        // 随后 cancel() 落在 .updateAvailable 上空转，下载照跑，flight 永久等下去。
        await downloader.waitUntilStarted()
        #expect(isDownloading(updater), "应进入下载态")

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
        // 同上：显式等下载器进来，再关面板/放行，避免 finish() 早于 continuation 注册被丢弃。
        await downloader.waitUntilStarted()
        #expect(isDownloading(updater))

        // 「关闭」= 收起面板：任务不受影响，下载继续跑到完成。
        updater.dismiss()
        #expect(isDownloading(updater), "收起面板不得改变下载态")
        #expect(!downloader.wasCancelled, "收起面板不得取消下载")

        downloader.finish()
        await flight.value
        #expect(updater.state == .downloaded, "收起面板后下载应照常完成")
    }

    // MARK: - #28 点「下载」后、进入下载前取消

    @Test func cancelAtUpdateAvailableGoesIdleAndNeverDownloads() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let manifest = try makeManifest(archive: products.archive)
        let downloader = SpyDownloader(archiveURL: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: downloader,
            installer: StubInstaller(products: products, defaults: env.defaults))

        await updater.check()
        guard case .updateAvailable = updater.state else {
            Issue.record("期望 updateAvailable，实际 \(updater.state)")
            return
        }

        // 点「下载」后立刻点「取消」：下载任务还没跑到第一次状态回写。
        let flight = Task { await updater.download() }
        updater.cancel()
        #expect(updater.state == .idle, "updateAvailable 态取消必须生效（不得空转）")

        await flight.value
        // 取消后给旧任务足够时间复活（若有 bug，这里会看到 downloading/downloaded）。
        try? await Task.sleep(nanoseconds: 150_000_000)
        #expect(updater.state == .idle, "取消后不得再进入下载/已下载，实际 \(updater.state)")
        #expect(downloader.startCount == 0, "取消后不得发起下载")
    }

    // MARK: - #24 跨版本残留：旧 pending 缺键

    /// v1.1.0 的 pending 只有 result / backup / backupDir 三键：解压目录与脚本路径
    /// 一概没有，而且解压目录的 uuid 与脚本/result 的 uuid 不是同一个。
    @Test func legacyPendingWithoutKeysSweepsArtifactsByShape() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let fm = FileManager.default
        let extractionDir = env.root.appendingPathComponent(
            "kairo-ota-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: extractionDir.appendingPathComponent("Kairo.app", isDirectory: true),
            withIntermediateDirectories: true)
        // 残留是「上一版留下的」：把 mtime 拨到一岁以外（陈旧解压目录判据）。
        try fm.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -7200)],
            ofItemAtPath: extractionDir.path)
        let legacyScript = env.root.appendingPathComponent(
            "kairo-ota-install-\(UUID().uuidString).sh")
        try Data("#!/bin/bash\n".utf8).write(to: legacyScript)

        // 旧版 pending：三个键，且 result 的 uuid 与脚本/解压目录都对不上。
        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 3, message: "backup_failed")
        ).write(to: products.result)
        env.defaults.set(products.result.path, forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        env.defaults.set(products.backup.path, forKey: ZipAppInstaller.pendingBackupPathDefaultsKey)
        env.defaults.set(products.backupDir.path, forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)

        let manifest = try makeManifest(archive: products.archive)
        let updater = makeManager(
            env,
            manifest: manifest,
            downloader: StubDownloader(archiveURL: products.archive),
            installer: StubInstaller(products: products, defaults: env.defaults))
        updater.consumePendingInstallResult()

        #expect(!fm.fileExists(atPath: products.result.path), "result 必须清掉")
        #expect(!fm.fileExists(atPath: legacyScript.path), "旧脚本必须清掉")
        #expect(!fm.fileExists(atPath: extractionDir.path), "旧解压目录必须清掉")
        #expect(fm.fileExists(atPath: products.backup.path), "备份目录是回滚依据，必须保留")
    }

    /// 清扫只认自己的形状：同目录里别的文件与新鲜解压目录一律不动。
    @Test func legacySweepDoesNotTouchForeignOrFreshArtifacts() async throws {
        let env = try makeEnv()
        let products = try makeProducts(env)
        defer { tearDown(env, products) }

        let fm = FileManager.default
        let freshDir = env.root.appendingPathComponent(
            "kairo-ota-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(
            at: freshDir.appendingPathComponent("Kairo.app", isDirectory: true),
            withIntermediateDirectories: true)
        let foreign = env.root.appendingPathComponent("kairo-ota-notes.txt")
        try Data("keep".utf8).write(to: foreign)

        try InstallerScript.encodeResult(
            InstallResult(success: false, code: 3, message: "backup_failed")
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

        #expect(fm.fileExists(atPath: freshDir.path), "新鲜解压目录可能正在用，不得删")
        #expect(fm.fileExists(atPath: foreign.path), "非本模块文件不得误删")
    }
}

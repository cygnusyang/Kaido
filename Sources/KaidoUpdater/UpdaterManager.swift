// UpdaterManager.swift —— OTA 状态机（模块公开接口）。
// 移植自 COFFER OTA 的 UpdaterManager，通用化改造：appId/公钥/feed/白名单/
// 日志全部经 init 注入；新增跳过版本支持。网络层与安装层经协议注入，测试用
// stub 驱动全部状态迁移，不真联网。

import Foundation
import os

/// 校验通过的更新信息（UI 展示用）。
public struct UpdateInfo: Equatable {
    public let version: String
    public let minimumVersion: String
    public let downloadUrl: URL
    public let cdHash: String
    /// 下载 zip 的 SHA256（可选；nil/空串 = 跳过校验，向后兼容旧清单）。
    public let sha256: String?
    public let buildTime: Date
    public let securityCritical: Bool
    public let notes: String?

    /// 从已通过解析/验签的清单构造；downloadUrl / buildTime 非法则显式报错
    ///（fail-closed，不静默降级）。
    public init(manifest: UpdateManifest) throws {
        guard let url = URL(string: manifest.downloadUrl) else {
            throw UpdateInfoError.invalidDownloadURL(manifest.downloadUrl)
        }
        guard let date = Self.parseRFC3339(manifest.buildTime) else {
            throw UpdateInfoError.invalidBuildTime(manifest.buildTime)
        }
        self.version = manifest.version
        self.minimumVersion = manifest.minimumVersion
        self.downloadUrl = url
        self.cdHash = manifest.cdHash
        self.sha256 = manifest.sha256
        self.buildTime = date
        self.securityCritical = manifest.securityCritical
        self.notes = manifest.notes
    }

    /// RFC3339 解析（与清单 `buildTime` 语义一致）。
    public static func parseRFC3339(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

/// UpdateInfo 构造的显式错误。
public enum UpdateInfoError: Error, UpdaterCodedError {
    case invalidDownloadURL(String)
    case invalidBuildTime(String)

    public var code: UpdaterErrorCode {
        switch self {
        case .invalidDownloadURL: return .downloadURLInvalid
        case .invalidBuildTime: return .buildTimeInvalid
        }
    }

    public var parameters: [String: String] {
        switch self {
        case .invalidDownloadURL(let url): return ["url": url]
        case .invalidBuildTime(let time): return ["buildTime": time]
        }
    }
}

/// Updater 状态机。
public enum UpdaterState: Equatable {
    /// 未检查
    case idle
    /// 检查中
    case checking
    /// 发现可更新
    case updateAvailable(UpdateInfo)
    /// 已是最新
    case upToDate
    /// 下载中（0...1 进度）
    case downloading(Double)
    /// 下载 + 验签完成，等待安装确认
    case downloaded
    /// 安装中（退出 + 替换 + relaunch）
    case installing
    /// 失败（码 + 参数；文案由更新面板按 code 渲染）
    case failed(UpdaterFailure)
}

/// OTA 状态机。零网络姿态：不做启动静默检查、不做定时后台检查——由 UI
/// 显式调 `check()`（自动检查策略由宿主 App 自行叠加）。
@MainActor
public final class UpdaterManager: ObservableObject {
    @Published public private(set) var state: UpdaterState = .idle

    /// 首启消费到的安装失败**尚未被用户看到**（issue #20）。
    ///
    /// 为 true 时 `state` 停在 `.failed`，自动检查（`check()`）一律跳过——
    /// 否则启动 5s 后的静默检查会把失败覆盖成 `.updateAvailable`，失败原因
    /// 再也无处可查。只有用户显式关闭面板（`dismiss()`）或点「重试」（`retry()`）
    /// 才清除标记。
    @Published public private(set) var hasUnreadInstallFailure = false

    private let manifestURL: URL
    private let expectedAppId: String
    private let currentVersion: String
    private let currentAppURL: URL
    private let publicKeyBase64: String
    private let policy: UpdateEndpointPolicy
    private let fetcher: ManifestFetching
    private let downloader: DataDownloading
    private let installer: Installing
    private let verifier: ProductVerifying
    private let userDefaults: UserDefaults
    /// 诊断日志（默认 os.log）。
    private let log: @Sendable (String) -> Void
    /// 跳过版本的持久化 key（仅严格更新版本才重新提示；securityCritical 禁跳）。
    private let skippedVersionKey: String
    /// 安装观察窗口（issue #17）：超时即离开「安装中」态，面板给出手动下载出口。
    private let installWatchTimeout: TimeInterval
    /// 安装结果文件轮询间隔。
    private let installWatchInterval: TimeInterval
    /// 替换脚本已成功启动（武装）。仅与 `.installing` 同时成立才算「OTA 武装」。
    private var installScriptLaunched = false
    /// 安装结果观察任务（失败/成功/超时后退出）。
    private var installWatchTask: Task<Void, Never>?
    /// 进行中的检查/下载任务（issue #21：`cancel()` 真中止它，不是只收起面板）。
    private var flightTask: Task<Void, Never>?
    /// 飞行代号：`cancel()` 自增，旧任务此后的任何状态回写都被丢弃。
    private var flightID = 0
    /// 本次下载落盘的 zip（取消/失败清理用；跨进程由持久化键兜底）。
    private var pendingArchive: URL?

    /// 下载完成后的安装产物暂存（清单 info + 解压验签后的 App 路径）。
    /// `.downloaded` 态无关联值，install() 从本暂存消费；失败/dismiss/新 check 清空。
    private var pendingProduct: (info: UpdateInfo, appURL: URL)?

    public init(
        manifestURL: URL,
        expectedAppId: String,
        currentVersion: String,
        currentAppURL: URL,
        publicKeyBase64: String,
        policy: UpdateEndpointPolicy,
        fetcher: ManifestFetching,
        downloader: DataDownloading,
        installer: Installing,
        verifier: ProductVerifying,
        userDefaults: UserDefaults = .standard,
        skippedVersionKey: String = "kaido_ota_skipped_version",
        installWatchTimeout: TimeInterval = 75,
        installWatchInterval: TimeInterval = 0.5,
        log: @escaping @Sendable (String) -> Void = ZipAppInstaller.defaultLogger
    ) {
        self.manifestURL = manifestURL
        self.expectedAppId = expectedAppId
        self.currentVersion = currentVersion
        self.currentAppURL = currentAppURL
        self.publicKeyBase64 = publicKeyBase64
        self.policy = policy
        self.fetcher = fetcher
        self.downloader = downloader
        self.installer = installer
        self.verifier = verifier
        self.userDefaults = userDefaults
        self.skippedVersionKey = skippedVersionKey
        self.installWatchTimeout = installWatchTimeout
        self.installWatchInterval = installWatchInterval
        self.log = log
    }

    /// OTA 已武装（issue #17）：替换脚本成功启动、本进程仍在 `.installing`。
    ///
    /// 退出守卫（`AppDelegate.terminationReply`）为真时直接放行退出：安装前
    /// 已强制落盘未保存修改，退出路径上不该再出现需要人参与的模态裁决——
    /// 否则脚本等 60s 拿不到退出就 `app_not_quitting` 放弃，面板死在安装态。
    public var isInstallingUpdate: Bool {
        guard case .installing = state else { return false }
        return installScriptLaunched
    }

    /// 检查更新：拉清单 → HTTPS+白名单 → canonical 验签 → 版本比较 → 状态迁移。
    /// 网络失败 → `.failed`（错误码 OTA-E-2001，可重查；绝不静默归「已是最新」）；
    /// 验签失败 / 不匹配 → `.failed`（fail-closed，不静默）。
    ///
    /// 未读的安装失败优先（issue #20）：还有没被用户看到的失败原因时直接返回，
    /// 自动检查不得把它覆盖成 `.updateAvailable`。
    public func check() async {
        guard !isInFlight else { return }
        guard !hasUnreadInstallFailure else {
            log("存在未读的安装失败结果，跳过本次更新检查")
            return
        }
        await runFlight { id in await self.performCheck(flightID: id) }
    }

    /// 检查主体：跑在 `runFlight` 起的可取消任务里，每个状态回写都先确认仍是
    /// 「当前飞行」——`cancel()` 之后旧任务一律不得复活状态机（issue #21）。
    ///
    /// 入口先验代号（issue #28）：`runFlight` 建完任务到本方法执行之间有一个调度点，
    /// 用户在这个窗口点取消后，任务不得再把状态写回 `.checking`。
    private func performCheck(flightID id: Int) async {
        guard isCurrentFlight(id) else { return }
        pendingProduct = nil
        pendingArchive = nil
        state = .checking
        do {
            try policy.validate(manifestURL)
            let data: Data
            do {
                data = try await fetcher.fetchManifest(from: manifestURL)
            } catch {
                guard isCurrentFlight(id), !Self.isCancellation(error) else { return }
                log("清单拉取失败 url=\(manifestURL.absoluteString) error=\(error)")
                state = .failed(UpdaterFailure(
                    code: .checkFailed,
                    parameters: ["ref": Self.checkFailureReference]
                ))
                return
            }
            try Task.checkCancellation()
            let manifest = try UpdateManifest.parse(data, expectedAppId: expectedAppId)
            _ = try ManifestVerifier.verify(manifestJSONData: data, publicKeyBase64: publicKeyBase64)
            let info = try UpdateInfo(manifest: manifest)
            // 纵深：下载地址也必须 https + 白名单（验签通过仍不例外）。
            try policy.validate(info.downloadUrl)
            guard isCurrentFlight(id) else { return }
            resolveCheckOutcome(manifest: manifest, info: info)
        } catch {
            guard isCurrentFlight(id), !Self.isCancellation(error) else { return }
            log("检查更新失败 error=\(error)")
            state = .failed(Self.failure(from: error))
        }
    }

    /// 仅下载：下载（进度）→ SHA256 校验 → 解压 → 验签 → downloaded，停在安装前。
    /// 安装一律经 .downloaded 态确认弹窗后调 install()——「退出+替换二进制」
    /// 动作确认纪律单点化。
    /// 取消语义（issue #21）：`cancel()` 中止飞行任务后本方法不再回写状态，
    /// 半成品由取消路径统一清理。
    public func download() async {
        guard case .updateAvailable(let info) = state else { return }
        await runFlight { id in await self.performDownload(info: info, flightID: id) }
    }

    /// 下载主体：进度回写只在仍是「当前飞行」时生效（取消后不再写状态）。
    ///
    /// 入口先验代号（issue #28）：用户点了「下载」、飞行任务还没跑到这里就点了取消——
    /// 这时取消已经把状态打回 `.idle`，本方法绝不能再用 `.downloading(0)` 把它拽回来，
    /// 下载也不得开始。
    private func performDownload(info: UpdateInfo, flightID id: Int) async {
        guard isCurrentFlight(id) else { return }
        do {
            state = .downloading(0)
            let archive = try await downloader.download(from: info.downloadUrl) { progress in
                guard self.isCurrentFlight(id) else { return }
                self.state = .downloading(progress)
            }
            pendingArchive = archive
            try Task.checkCancellation()
            // 下载落盘后、解压前校验 zip SHA256：清单 sha256 存在且非空即强制
            // 比对，不匹配 fail-closed 拒装；缺省/空串跳过（向后兼容旧清单）。
            if let expected = info.sha256, !expected.isEmpty {
                let actual = try UpdateChecksum.sha256Hex(of: archive)
                guard actual == expected.lowercased() else {
                    throw UpdateChecksumError.mismatch
                }
            }
            let extractedApp = try await installer.prepare(downloadedArchive: archive)
            guard isCurrentFlight(id) else {
                // 解压途中被取消：刚解出的目录同样不能留（issue #19 / #21）。
                InstallerScript.cleanupTransientArtifacts(extractionAppURL: extractedApp)
                return
            }
            try verifier.verifyApp(at: extractedApp, expectedCdHash: info.cdHash)
            pendingProduct = (info, extractedApp)
            state = .downloaded
        } catch {
            guard isCurrentFlight(id), !Self.isCancellation(error) else { return }
            pendingProduct = nil
            cleanupInstallArtifacts(after: "下载/验签失败")
            log("下载/验签失败 error=\(error)")
            state = .failed(Self.failure(from: error))
        }
    }

    /// 安装更新：装前收口 → 落盘替换脚本并 detached 启动 → installing。
    /// App 侧随即退出（脚本等退出后备份/替换/relaunch，结果经 result 文件消费）。
    ///
    /// UI 唯一入口为 .downloaded 态确认弹窗；起点为 .updateAvailable 时先补 download()。
    /// - Parameter preflight: 启动脚本**之前**的收口（生产 = 落盘未保存修改）。
    ///   返回失败则整体拒绝安装：脚本不落盘、不启动，面板进 `.failed` 说明原因
    ///   （issue #17：绝不把「能不能退」交给退出守卫的模态框）。
    public func install(preflight: (@MainActor () -> UpdaterFailure?)? = nil) async {
        if case .updateAvailable = state {
            await download()
        }
        guard case .downloaded = state, let product = pendingProduct else {
            return
        }
        if let failure = preflight?() {
            log("安装前收口失败，未启动替换脚本 error=\(failure)")
            // 脚本没启动 = 本次安装作废：解压目录与下载 zip 一并清掉（issue #19）。
            cleanupInstallArtifacts(after: "安装前收口失败")
            pendingProduct = nil
            state = .failed(failure)
            return
        }
        do {
            state = .installing
            try await installer.perform(
                info: product.info, downloadedAppURL: product.appURL, currentAppURL: currentAppURL)
            // 成功路径：脚本已启动（武装），本进程即将退出；保持 .installing。
            installScriptLaunched = true
            startInstallWatch(
                resultPath: userDefaults.string(
                    forKey: ZipAppInstaller.pendingResultPathDefaultsKey))
        } catch {
            cleanupInstallArtifacts(after: "替换脚本启动失败")
            pendingProduct = nil
            log("安装失败 error=\(error)")
            state = .failed(Self.failure(from: error))
        }
    }

    /// 用户跳过当前版本（securityCritical 版本禁跳；严格更新版本才重新提示）。
    public func skipCurrentUpdate() {
        guard case .updateAvailable(let info) = state, !info.securityCritical else { return }
        userDefaults.set(info.version, forKey: skippedVersionKey)
        state = .upToDate
    }

    /// 首启消费上次安装结果（宿主在启动早期调用；幂等）。成功：删备份 +
    /// 静默（.upToDate）；失败：呈现 failed 并打「未读」标记（issue #20：自动检查
    /// 不得覆盖它），同时把本次安装的临时产物清干净（issue #19）。UserDefaults key
    /// 一次性消费后清除；result/脚本/解压目录仅在形状守卫通过时删除（fail-closed
    /// 不误删）；无 pending 则 no-op（不打扰正常启动）。
    public func consumePendingInstallResult() {
        guard let resultPath = userDefaults.string(
            forKey: ZipAppInstaller.pendingResultPathDefaultsKey) else { return }
        let resultURL = URL(fileURLWithPath: resultPath)
        let backupDir = userDefaults.string(forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)
        let decoded = (try? Data(contentsOf: resultURL))
            .flatMap { try? JSONDecoder().decode(InstallResult.self, from: $0) }

        if decoded?.success != true {
            // 失败（含结果不可读，fail-closed 一律按失败呈现）：先给用户看，
            // 再清产物——清理要读 pending 键里的脚本/解压路径，故必须在清键之前。
            hasUnreadInstallFailure = true
            state = .failed(decoded.map(Self.failure(from:))
                ?? UpdaterFailure(code: .installResultUnreadable))
            cleanupInstallArtifacts(after: "首启消费安装失败结果")
        } else {
            // 成功：备份目录已过回滚窗口，删除；面板静默回到「已是最新」。
            if let backupPath = userDefaults.string(forKey: ZipAppInstaller.pendingBackupPathDefaultsKey),
               let dir = backupDir,
               backupPath.hasPrefix(dir + "/"),
               InstallerScript.isBackupShape(backupPath) {
                try? FileManager.default.removeItem(at: URL(fileURLWithPath: backupPath))
            }
            state = .upToDate
        }
        clearPendingInstallState()
    }

    /// 收起面板 / 清理失败态（**不等于取消**，issue #21）。
    ///
    /// 检查中 / 下载中只收起面板，任务继续跑完；要中止请用 `cancel()`。
    /// 其余状态回到 idle；用户显式关闭即视为「已读过失败原因」，清未读标记。
    public func dismiss() {
        switch state {
        case .checking, .downloading:
            log("面板收起（检查/下载继续，取消请用 cancel）")
        case .idle, .upToDate, .updateAvailable, .downloaded, .installing, .failed:
            stopInstallWatch()
            pendingProduct = nil
            pendingArchive = nil
            hasUnreadInstallFailure = false
            state = .idle
        }
    }

    /// 真正取消检查 / 下载（issue #21 / #28）：中止底层任务、清半成品与临时目录、回 idle。
    ///
    /// 与 `dismiss()`（只收起面板）语义分离。**可取消范围 = 一切非终态**：
    /// `.checking` / `.updateAvailable` / `.downloading` / `.downloaded`。
    /// `.updateAvailable` 必须算在内（issue #28）：用户点了「下载」、飞行任务还没跑到
    /// 第一次状态回写时点取消，等同于「别下了」——代号失效让该任务自己退出，
    /// 不会再进入 `.downloading`。
    ///
    /// 唯一不可取消的是 `.installing`（替换脚本可能已武装，打断会留下半替换的 App）；
    /// 面板在该态不给取消按钮，只给「关闭」，且关闭不影响已启动的脚本。
    public func cancel() {
        switch state {
        case .checking, .updateAvailable, .downloading, .downloaded:
            // 先失效再取消：被取消任务的 catch 分支不会再回写状态。
            flightID &+= 1
            flightTask?.cancel()
            flightTask = nil
            cleanupInstallArtifacts(after: "用户取消")
            pendingProduct = nil
            pendingArchive = nil
            log("已取消检查/下载，临时产物已清理")
            state = .idle
        case .idle, .upToDate, .failed, .installing:
            break
        }
    }

    /// 用户显式「重试」：先承认已读过失败原因（清 issue #20 的未读标记），再重查。
    public func retry() async {
        hasUnreadInstallFailure = false
        await check()
    }

    /// 进行中状态（不可重复 check / install）。
    private var isInFlight: Bool {
        switch state {
        case .checking, .downloading, .downloaded, .installing:
            return true
        case .idle, .upToDate, .updateAvailable, .failed:
            return false
        }
    }

    /// 版本比较 → 状态迁移（纯逻辑）。跳过的版本按「已是最新」呈现
    ///（securityCritical 例外，禁跳必显）。
    private func resolveCheckOutcome(manifest: UpdateManifest, info: UpdateInfo) {
        guard let order = VersionCompare.compare(currentVersion, manifest.version) else {
            state = .failed(UpdaterFailure(
                code: .versionUnparsable,
                parameters: ["version": manifest.version, "currentVersion": currentVersion]
            ))
            return
        }
        switch order {
        case .ascending:
            if VersionCompare.isBelow(currentVersion, minimum: manifest.minimumVersion) {
                state = .failed(UpdaterFailure(
                    code: .minimumVersionUnmet,
                    parameters: [
                        "currentVersion": currentVersion,
                        "minimumVersion": manifest.minimumVersion,
                    ]
                ))
                return
            }
            if !info.securityCritical, userDefaults.string(forKey: skippedVersionKey) == manifest.version {
                state = .upToDate
                return
            }
            state = .updateAvailable(info)
        case .equal, .descending:
            state = .upToDate
        }
    }

    /// 检查失败的诊断号（完整错误只进日志；界面按 code + 该诊断号出提示）。
    nonisolated public static let checkFailureReference = "OTA-E-2001"

    /// 脚本结果 → 结构化失败（issue #17 面板内呈现与首启消费共用同一映射）。
    ///
    /// F-0719：脚本写的是稳定码，映射成独立错误码；**只带退出码**——
    /// 旧版本脚本写下的中文文案绝不进 UI（英文界面不得漏中文）。
    nonisolated static func failure(from result: InstallResult) -> UpdaterFailure {
        let code: UpdaterErrorCode
        switch result.reason {
        case .appNotQuitting: code = .installAppStillRunning
        case .backupFailed: code = .installBackupFailed
        case .replaceFailed: code = .installReplaceFailed
        case .relaunchFailed, nil: code = .installFailed
        }
        return UpdaterFailure(code: code, parameters: ["exitCode": String(result.code)])
    }

    /// 任意错误 → 结构化失败（实现 UpdaterCodedError 的错误保留码与参数，其余兜底）。
    nonisolated public static func failure(from error: Error) -> UpdaterFailure {
        if let failure = error as? UpdaterFailure { return failure }
        if let coded = error as? any UpdaterCodedError {
            return UpdaterFailure(code: coded.code, parameters: coded.parameters)
        }
        // 未知错误（URLError 等）：只给稳定码 + 诊断号，绝不把 error 的 description 拼给界面。
        // 原始错误由调用方写日志（updater.check 的 os.Logger），界面拿到的永远是可翻译的码。
        return UpdaterFailure(code: .checkFailed, parameters: ["ref": Self.checkFailureReference])
    }

    // MARK: - 安装结果观察（issue #17）

    /// `.installing` 期间的兜底观察：脚本的成功/失败结果只写在 result 文件里，
    /// 而旧进程一旦退出就再也读不到——所以「本进程还活着」时由本进程读。
    ///
    /// 三条出口：读到 success=false → 面板 failed（含退出码）；读到 success=true →
    /// 停观察（进程随即被替换/relaunch）；超过时限没有任何结果 → failed(.installTimeout)。
    /// 任何一条都保证面板不会停在「安装中」这个无按钮可点的状态。
    private func startInstallWatch(resultPath: String?) {
        stopInstallWatch()
        installWatchTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(self.installWatchTimeout)
            while !Task.isCancelled {
                if Date() >= deadline {
                    self.failInstall(UpdaterFailure(code: .installTimeout))
                    return
                }
                try? await Task.sleep(
                    nanoseconds: UInt64(max(self.installWatchInterval, 0.01) * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let result = Self.readInstallResult(atPath: resultPath) else { continue }
                if result.success { return }
                self.failInstall(Self.failure(from: result))
                return
            }
        }
    }

    private func stopInstallWatch() {
        installWatchTask?.cancel()
        installWatchTask = nil
    }

    /// 安装失败收口：停观察、解除武装、清临时产物与 pending 键、面板进 `.failed`
    ///（有「重试 / 关闭」两个出口）。
    ///
    /// 产物清理在清 pending 键**之前**：清理入口要从键里读脚本/解压目录路径。
    private func failInstall(_ failure: UpdaterFailure) {
        stopInstallWatch()
        installScriptLaunched = false
        cleanupInstallArtifacts(after: "安装失败 \(failure.code)")
        pendingProduct = nil
        pendingArchive = nil
        clearPendingInstallState()
        log("安装失败（面板内呈现）error=\(failure)")
        state = .failed(failure)
    }

    /// 清掉 pending 五键（result / backup / backupDir / 脚本 / 解压目录），
    /// 结果文件已由 `cleanupInstallArtifacts` 按形状删除，这里只兜底再删一次
    ///（幂等；形状不匹配绝不误删，fail-closed）。
    private func clearPendingInstallState() {
        let resultPath = userDefaults.string(forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        userDefaults.removeObject(forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        userDefaults.removeObject(forKey: ZipAppInstaller.pendingBackupPathDefaultsKey)
        userDefaults.removeObject(forKey: ZipAppInstaller.pendingBackupDirDefaultsKey)
        userDefaults.removeObject(forKey: ZipAppInstaller.pendingScriptPathDefaultsKey)
        userDefaults.removeObject(forKey: ZipAppInstaller.pendingExtractionPathDefaultsKey)
        if let resultPath, InstallerScript.isResultShape(resultPath) {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: resultPath))
        }
    }

    // MARK: - 临时产物清理（issue #19）与可取消飞行（issue #21）

    /// 失败 / 超时 / 取消的临时产物清理统一入口（issue #19 / #24）。
    ///
    /// 只清本次流程自建的解压目录、下载 zip、替换脚本、结果文件（形状守卫在
    /// `InstallerScript.cleanupTransientArtifacts` 内）。**备份目录 `Kaido-<stamp>.app`
    /// 不在清理范围**——那是脚本回滚的依据，成功与已武装路径都不调用本方法。
    ///
    /// 跨版本兜底（issue #24）：v1.1.0 写的 pending 只有 result / backup / backupDir
    /// 三键，脚本与解压目录的路径一概没有，按本版键名逐个删就一个都删不掉。键不全
    /// 时降级为形状清扫：脚本与 result 按本模块专属前缀清（旧脚本的 uuid 无从匹配），
    /// 解压目录只认「形状 `kaido-ota-<UUID>` + 单个 .app + 超过一岁数」——
    /// 绝不按 `kaido-ota-*` 前缀批量删目录。
    private func cleanupInstallArtifacts(after reason: String) {
        let extractionKeyPath = userDefaults.string(
            forKey: ZipAppInstaller.pendingExtractionPathDefaultsKey)
        let extraction = pendingProduct?.appURL
            ?? extractionKeyPath.map { URL(fileURLWithPath: $0) }
        let scriptPath = userDefaults.string(forKey: ZipAppInstaller.pendingScriptPathDefaultsKey)
        let resultPath = userDefaults.string(forKey: ZipAppInstaller.pendingResultPathDefaultsKey)
        var removed = InstallerScript.cleanupTransientArtifacts(
            extractionAppURL: extraction,
            archiveURL: pendingArchive,
            scriptPath: scriptPath,
            resultPath: resultPath)

        let pendingComplete = extractionKeyPath != nil && scriptPath != nil && resultPath != nil
        if !pendingComplete,
           let sweepDir = userDefaults.string(forKey: ZipAppInstaller.pendingBackupDirDefaultsKey) {
            let root = URL(fileURLWithPath: sweepDir)
            // ① 脚本与 result 是本模块专属名字：缺键时无从 uuid 匹配，按形状清。
            var swept = InstallerScript.sweepTransientArtifacts(in: root, id: nil)
            // ② 还能从既有键推出 uuid 时，再按同一 uuid 收一次（解压目录会被这条命中）。
            let id = [resultPath, scriptPath, extractionKeyPath]
                .compactMap { $0 }
                .compactMap { InstallerScript.transientArtifactID(fromPath: $0) }
                .first
            if let id {
                swept += InstallerScript.sweepTransientArtifacts(in: root, id: id)
            }
            // ③ 解压目录的 uuid 由 prepare() 另生成、与脚本不同：只认形状 + 单 .app + 超龄。
            swept += InstallerScript.sweepStaleExtractionDirectories(in: root)
            removed += swept.filter { !removed.contains($0) }
        }
        if !removed.isEmpty {
            log("清理临时产物（\(reason)）count=\(removed.count)")
        }
    }

    /// 在可取消的飞行任务里跑一次检查/下载（issue #21）。
    ///
    /// 句柄留给 `cancel()`；`flightID` 让取消后旧任务的任何回写都失效。
    private func runFlight(_ operation: @escaping @MainActor (Int) async -> Void) async {
        flightID &+= 1
        let id = flightID
        let task = Task { @MainActor in await operation(id) }
        flightTask = task
        await task.value
        if flightID == id { flightTask = nil }
    }

    /// 该代号是否仍是当前飞行（取消 / 新任务后旧代号立即失效）。
    private func isCurrentFlight(_ id: Int) -> Bool { id == flightID }

    /// 取消判定：Swift 任务取消与 URLSession 取消（`URLError.cancelled`）同义，
    /// 都属「用户取消」——不呈现为失败。
    nonisolated private static func isCancellation(_ error: Error) -> Bool {
        if error is CancellationError { return true }
        if let urlError = error as? URLError, urlError.code == .cancelled { return true }
        return Task.isCancelled
    }

    /// 读一次脚本结果：文件尚未出现 → nil（继续等）。半截写入 / 坏 JSON 同样按
    /// nil 处理（下一拍再读），不把瞬态读失败误报成安装失败。
    nonisolated private static func readInstallResult(atPath path: String?) -> InstallResult? {
        guard let path, let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else {
            return nil
        }
        return try? JSONDecoder().decode(InstallResult.self, from: data)
    }
}

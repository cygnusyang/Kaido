// ZipAppInstaller.swift —— 安装机制（非沙盒 App 自替换适配版）。
// 移植自 COFFER OTA 的 OTAInstaller：Kairo 非沙盒，用 detached bash 脚本承接
// 替换协议（等退出→备份→替换→relaunch→result 握手），替代 helper 进程。

import Foundation
import os

/// 真实安装机制（解压 / 落盘脚本 / detached 启动）。
public struct ZipAppInstaller: Installing {
    /// 临时区（解压、备份与 result 落点）。
    public let backupDirectory: URL
    public let pidProvider: () -> Int32
    public let userDefaults: UserDefaults
    /// 当前运行 App 路径提供者（生产 = Bundle.main.bundleURL；测试注入假值）。
    public let runningAppURLProvider: () -> URL
    public let launchScript: (URL, [String]) throws -> Void
    public let log: @Sendable (String) -> Void

    /// 首启找回 result 文件的 UserDefaults key（重启后的 App 消费）。
    public static let pendingResultPathDefaultsKey = "kairo_ota_pending_result_path"
    public static let pendingBackupPathDefaultsKey = "kairo_ota_pending_backup_path"
    /// 备份目录 key（消费删备份前校验前缀，防误删）。
    public static let pendingBackupDirDefaultsKey = "kairo_ota_pending_backup_dir"
    /// 替换脚本本体路径 key（issue #19：失败/超时后删脚本要靠它，跨进程也要能找回）。
    public static let pendingScriptPathDefaultsKey = "kairo_ota_pending_script_path"
    /// 解压出的 App 路径 key（issue #19：失败后连解压目录一起清，跨进程可追溯）。
    public static let pendingExtractionPathDefaultsKey = "kairo_ota_pending_extraction_path"

    public init(
        backupDirectory: URL = FileManager.default.temporaryDirectory,
        pidProvider: @escaping () -> Int32 = { ProcessInfo.processInfo.processIdentifier },
        userDefaults: UserDefaults = .standard,
        runningAppURLProvider: @escaping () -> URL = { Bundle.main.bundleURL },
        log: @escaping @Sendable (String) -> Void = ZipAppInstaller.defaultLogger,
        launchScript: @escaping (URL, [String]) throws -> Void = ZipAppInstaller.launchDetached
    ) {
        self.backupDirectory = backupDirectory
        self.pidProvider = pidProvider
        self.userDefaults = userDefaults
        self.runningAppURLProvider = runningAppURLProvider
        self.log = log
        self.launchScript = launchScript
    }

    /// 默认诊断日志（os.log，单行截断）。
    public static var defaultLogger: @Sendable (String) -> Void {
        let logger = Logger(subsystem: "app.kairo.macos", category: "ota")
        return { message in logger.notice("\(String(message.prefix(500)), privacy: .public)") }
    }

    /// 解压下载的 zip 到临时目录，返回首个 `.app` URL（fail-closed）。
    public func prepare(downloadedArchive: URL) async throws -> URL {
        let fm = FileManager.default
        let tempDir = fm.temporaryDirectory
            .appendingPathComponent("kairo-ota-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempDir, withIntermediateDirectories: true)
        do {
            try InstallerScript.runProcess(
                "/usr/bin/ditto", args: ["-x", "-k", downloadedArchive.path, tempDir.path])
        } catch {
            throw InstallError.unzipFailed("\(error)")
        }
        let contents = try fm.contentsOfDirectory(at: tempDir, includingPropertiesForKeys: nil)
        guard let app = contents.first(where: { $0.pathExtension == "app" }) else {
            throw InstallError.appNotFound
        }
        return app
    }

    /// 落盘替换脚本并 detached 启动，随即返回。启动路径错位（运行中 App ≠
    /// 安装目标）fail-fast 拦截：从 build 副本点升级会「替了 A 跑着 B」。
    public func perform(info: UpdateInfo, downloadedAppURL: URL, currentAppURL: URL) async throws {
        guard runningAppURLProvider().path == currentAppURL.path else {
            log("启动路径错位拦截（running=\(runningAppURLProvider().path) target=\(currentAppURL.path)）")
            InstallerScript.cleanupFailedProductExtractionDir(of: downloadedAppURL)
            throw InstallError.launchPathMismatch
        }
        let stamp = Int(Date().timeIntervalSince1970)
        let uuid = UUID().uuidString
        let backupPath = backupDirectory.appendingPathComponent("Kairo-\(stamp).app").path
        let resultFilePath = backupDirectory
            .appendingPathComponent("kairo-ota-result-\(uuid).json").path
        let scriptURL = backupDirectory
            .appendingPathComponent("kairo-ota-install-\(uuid).sh")
        let script = InstallerScript.replacement(
            newAppPath: downloadedAppURL.path,
            currentAppPath: currentAppURL.path,
            backupPath: backupPath,
            resultFilePath: resultFilePath,
            pid: pidProvider())
        do {
            try script.write(to: scriptURL, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: scriptURL.path)
        } catch {
            throw InstallError.scriptWriteFailed("\(error)")
        }
        // result/backup/backupDir/脚本/解压目录路径持久化：重启后的 App 首启据此
        // 找回并消费；失败/超时/取消清理也据此跨进程删产物（issue #19）。
        userDefaults.set(resultFilePath, forKey: Self.pendingResultPathDefaultsKey)
        userDefaults.set(backupPath, forKey: Self.pendingBackupPathDefaultsKey)
        userDefaults.set(backupDirectory.path, forKey: Self.pendingBackupDirDefaultsKey)
        userDefaults.set(scriptURL.path, forKey: Self.pendingScriptPathDefaultsKey)
        userDefaults.set(downloadedAppURL.path, forKey: Self.pendingExtractionPathDefaultsKey)
        do {
            try launchScript(scriptURL, [])
        } catch {
            Self.clearPendingState(
                userDefaults: userDefaults, scriptURL: scriptURL, resultFilePath: resultFilePath)
            InstallerScript.cleanupFailedProductExtractionDir(of: downloadedAppURL)
            throw InstallError.scriptLaunchFailed("\(error)")
        }
        log("替换脚本已启动（\(scriptURL.lastPathComponent)），等待当前进程退出后替换")
    }

    /// launch 失败后的 pending 状态回滚：清除 pending keys + best-effort 删
    /// 脚本/result 残留，保证下次启动 consume 为 no-op（不误报）。
    public static func clearPendingState(
        userDefaults: UserDefaults, scriptURL: URL, resultFilePath: String
    ) {
        userDefaults.removeObject(forKey: Self.pendingResultPathDefaultsKey)
        userDefaults.removeObject(forKey: Self.pendingBackupPathDefaultsKey)
        userDefaults.removeObject(forKey: Self.pendingBackupDirDefaultsKey)
        userDefaults.removeObject(forKey: Self.pendingScriptPathDefaultsKey)
        userDefaults.removeObject(forKey: Self.pendingExtractionPathDefaultsKey)
        try? FileManager.default.removeItem(at: scriptURL)
        try? FileManager.default.removeItem(at: URL(fileURLWithPath: resultFilePath))
    }

    /// detached 启动脚本：孤儿化（父进程退出后由 launchd 托管继续执行）。
    /// 输出重定向 null 防管道破裂；不 waitUntilExit——本进程随后即退出，
    /// 脚本靠孤儿化继续。
    public static func launchDetached(script: URL, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path] + args
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
    }
}

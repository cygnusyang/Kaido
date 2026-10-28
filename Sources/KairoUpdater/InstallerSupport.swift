// InstallerSupport.swift —— 安装脚本构造、结果握手与清理支撑。
// 移植自 COFFER OTA 的 OTAInstaller（通用化：Kairo 命名、detached bash 载体）。

import Foundation

/// 安装机制协议（注入点：测试用 stub；生产用 `ZipAppInstaller`）。
public protocol Installing {
    /// 解压下载的 zip 到临时目录，返回解压出的 .app URL。
    func prepare(downloadedArchive: URL) async throws -> URL
    /// 落盘替换脚本并脱离启动，随即返回（替换/回滚/relaunch 由脚本执行）。
    func perform(info: UpdateInfo, downloadedAppURL: URL, currentAppURL: URL) async throws
}

/// 安装显式错误（fail-closed：任何一步失败即呈现 failed）。
public enum InstallError: Error, UpdaterCodedError, Equatable {
    case unzipFailed(String)
    case appNotFound
    case scriptWriteFailed(String)
    case scriptLaunchFailed(String)
    /// 启动路径错位（运行中 App ≠ 安装目标）。
    case launchPathMismatch

    public var code: UpdaterErrorCode {
        switch self {
        case .unzipFailed: return .unzipFailed
        case .appNotFound: return .appNotFound
        case .scriptWriteFailed: return .scriptWriteFailed
        case .scriptLaunchFailed: return .scriptLaunchFailed
        case .launchPathMismatch: return .launchPathMismatch
        }
    }

    public var parameters: [String: String] {
        switch self {
        case .unzipFailed(let detail),
             .scriptWriteFailed(let detail),
             .scriptLaunchFailed(let detail):
            return ["detail": detail]
        case .appNotFound, .launchPathMismatch:
            return [:]
        }
    }
}

/// 脚本写回的结果文件（成功/失败 + 退出码 + 稳定码；重启后的 App 首启消费）。
///
/// `message` 自 F-0719 起只装**稳定码**（如 `backup_failed`），不再写自然语言：
/// 该 JSON 会被更新面板直接渲染，中文会漏到英文界面（06 §8 明确不可豁免）。
/// 字段名保留 `message` 是为了兼容旧版本脚本已写下的结果文件（旧值是中文字符串，
/// `reason` 解析为 nil，调用方只认退出码，文案一律不展示）。
public struct InstallResult: Codable, Equatable {
    /// 脚本失败/提示的稳定码（与 `message` 字段同值，语义化视图）。
    public enum FailureReason: String, Codable, CaseIterable, Sendable {
        case appNotQuitting = "app_not_quitting"
        case backupFailed = "backup_failed"
        case replaceFailed = "replace_failed"
        /// 已替换成功但 relaunch 失败（success = true）。
        case relaunchFailed = "relaunch_failed"
    }

    public let success: Bool
    public let code: Int
    /// 稳定码（旧版本脚本可能写中文，此时 `reason` 为 nil）。
    public let message: String

    public init(success: Bool, code: Int, message: String) {
        self.success = success
        self.code = code
        self.message = message
    }

    /// `message` 的语义化视图；未知取值（含 v0.8.5 的中文文案）为 nil。
    public var reason: FailureReason? { FailureReason(rawValue: message) }
}

/// 替换脚本构造与文件形状守卫（纯函数，可独立测试）。
public enum InstallerScript {
    /// 替换脚本：等当前进程退出（上限 60s）→ 备份 → 替换 → relaunch →
    /// 写 result JSON（成功/失败均写，App 首启消费）。单引号包裹所有路径，
    /// 防空格与特殊字符拆参。
    public static func replacement(
        newAppPath: String, currentAppPath: String, backupPath: String,
        resultFilePath: String, pid: Int32
    ) -> String {
        let q: (String) -> String = { "'\($0)'" }
        return """
        #!/bin/bash
        # Kairo OTA replacement script: written by the app and launched detached;
        # after the parent process exits it is supervised by launchd.
        # Result JSON carries stable codes only (no natural language) - F-0719.
        RESULT_FILE=\(q(resultFilePath))
        write_result() {
          printf '{"success":%s,"code":%d,"message":"%s"}\\n' "$2" "$1" "$3" > "$RESULT_FILE"
        }
        for i in $(seq 1 300); do
          kill -0 \(pid) 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 \(pid) 2>/dev/null; then
          write_result 4 false "app_not_quitting"
          exit 1
        fi
        rm -rf \(q(backupPath))
        if ! mv \(q(currentAppPath)) \(q(backupPath)); then
          write_result 3 false "backup_failed"
          exit 1
        fi
        if ! cp -R \(q(newAppPath)) \(q(currentAppPath)); then
          mv \(q(backupPath)) \(q(currentAppPath)) 2>/dev/null
          write_result 2 false "replace_failed"
          exit 1
        fi
        if ! open \(q(currentAppPath)); then
          write_result 1 true "relaunch_failed"
          exit 0
        fi
        write_result 0 true ""
        exit 0
        """
    }

    /// 备份文件名形状校验：`Kairo-<stamp>.app`（与父目录前缀双守卫，fail-closed）。
    public static func isBackupShape(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("Kairo-") && name.hasSuffix(".app")
    }

    /// result 文件名形状校验：`kairo-ota-result-*.json`（fail-closed 不误删）。
    public static func isResultShape(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("kairo-ota-result-") && name.hasSuffix(".json")
    }

    /// 替换脚本文件名形状校验：`kairo-ota-install-*.sh`（fail-closed 不误删）。
    public static func isScriptShape(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("kairo-ota-install-") && name.hasSuffix(".sh")
    }

    /// 下载落盘文件名形状校验：`kairo-ota-download-*.zip`（fail-closed 不误删）。
    public static func isDownloadShape(_ path: String) -> Bool {
        let name = (path as NSString).lastPathComponent
        return name.hasPrefix("kairo-ota-download-") && name.hasSuffix(".zip")
    }

    /// install 失败路径 best-effort 清理解压目录。安全边界：父目录名必须匹配
    /// 自建的 `kairo-ota-*` 前缀才删（绝不误删非本场目录）；失败静默。
    public static func cleanupFailedProductExtractionDir(of downloadedAppURL: URL) {
        cleanupTransientArtifacts(extractionAppURL: downloadedAppURL)
    }

    /// 失败 / 超时 / 取消路径的临时产物清理（issue #19 单点入口）。
    ///
    /// 收口范围严格限定为「本次流程自建且形状匹配」的四类产物：解压目录
    /// `kairo-ota-<uuid>/`、下载落盘 `kairo-ota-download-*.zip`、替换脚本
    /// `kairo-ota-install-*.sh`、结果文件 `kairo-ota-result-*.json`。
    /// 任何一条形状不匹配就跳过（fail-closed 绝不误删他人文件）。
    ///
    /// 备份目录 `Kairo-<stamp>.app` **刻意不在清单内**：那是替换脚本回滚的依据，
    /// 成功与已武装路径都不允许删，这里也不给删除入口。
    ///
    /// - Parameters:
    ///   - extractionAppURL: 解压出的 App（只取其父目录，且要求 `kairo-ota-` 前缀）。
    ///   - archiveURL: 下载落盘的 zip。
    ///   - scriptPath: 替换脚本本体路径。
    ///   - resultPath: 脚本写回的 result 文件路径。
    /// - Returns: 实际删除的路径（诊断日志用）。
    @discardableResult
    public static func cleanupTransientArtifacts(
        extractionAppURL: URL? = nil,
        archiveURL: URL? = nil,
        scriptPath: String? = nil,
        resultPath: String? = nil
    ) -> [String] {
        let fm = FileManager.default
        var removed: [String] = []

        if let extractionAppURL {
            let dir = extractionAppURL.deletingLastPathComponent()
            if dir.lastPathComponent.hasPrefix("kairo-ota-"),
               (try? fm.removeItem(at: dir)) != nil {
                removed.append(dir.path)
            }
        }
        if let archiveURL, isDownloadShape(archiveURL.path),
           (try? fm.removeItem(at: archiveURL)) != nil {
            removed.append(archiveURL.path)
        }
        if let scriptPath, isScriptShape(scriptPath),
           (try? fm.removeItem(at: URL(fileURLWithPath: scriptPath))) != nil {
            removed.append(scriptPath)
        }
        if let resultPath, isResultShape(resultPath),
           (try? fm.removeItem(at: URL(fileURLWithPath: resultPath))) != nil {
            removed.append(resultPath)
        }
        return removed
    }

    // MARK: - 跨版本残留清扫（issue #24）

    /// 陈旧解压目录的判定年龄：解压目录只在「下载完成 → 安装」之间短暂存在，
    /// 超龄即视为残留（5.5 MB 包的下载 + 解压远达不到这个量级）。
    public static let staleExtractionMinAge: TimeInterval = 3600

    private static let extractionDirPrefix = "kairo-ota-"
    private static let scriptNamePrefix = "kairo-ota-install-"
    private static let resultNamePrefix = "kairo-ota-result-"

    /// 从 pending 记下的产物路径里取本次安装的 uuid（跨版本清扫用）。
    ///
    /// 认三种形状：解压目录 `kairo-ota-<uuid>/`（入参通常是目录里的 .app，也可传目录
    /// 本身）、替换脚本 `kairo-ota-install-<uuid>.sh`、结果文件
    /// `kairo-ota-result-<uuid>.json`。uuid 段不是合法 UUID 时返回 nil——旧版本写过
    /// 非常规文件名，此时调用方降级为形状清扫，绝不按前缀猜目录。
    public static func transientArtifactID(fromPath path: String) -> String? {
        let url = URL(fileURLWithPath: path)
        let name = url.lastPathComponent
        if name.hasPrefix(scriptNamePrefix), name.hasSuffix(".sh") {
            return validID(String(name.dropFirst(scriptNamePrefix.count).dropLast(".sh".count)))
        }
        if name.hasPrefix(resultNamePrefix), name.hasSuffix(".json") {
            return validID(String(name.dropFirst(resultNamePrefix.count).dropLast(".json".count)))
        }
        for candidate in [name, url.deletingLastPathComponent().lastPathComponent] {
            if candidate.hasPrefix(extractionDirPrefix) {
                return validID(String(candidate.dropFirst(extractionDirPrefix.count)))
            }
        }
        return nil
    }

    private static func validID(_ candidate: String) -> String? {
        UUID(uuidString: candidate) == nil ? nil : candidate
    }

    /// 目录名是否解压目录形状：`kairo-ota-<uuid>`（`kairo-ota-download-*.zip` 等不算）。
    private static func isExtractionDirName(_ name: String) -> Bool {
        guard name.hasPrefix(extractionDirPrefix) else { return false }
        return validID(String(name.dropFirst(extractionDirPrefix.count))) != nil
    }

    /// 按形状清扫一次安装留下的产物（issue #24：跨版本 pending 可能缺键）。
    ///
    /// - `id` 非 nil：只删**同一 uuid** 的三件套——`kairo-ota-<id>/`、
    ///   `kairo-ota-install-<id>.sh`、`kairo-ota-result-<id>.json`。相邻 uuid 的产物
    ///   一个都不碰（历史残留与并行安装互不连带）。
    /// - `id` 为 nil（uuid 无法确定）：只删脚本与 result，**目录一律不动**——
    ///   按 `kairo-ota-*` 前缀批量删目录是禁止的，那会把别人的解压目录一起带走。
    ///
    /// - Parameters:
    ///   - directory: 待清扫目录（生产 = pending 里记下的备份/临时目录）。
    ///   - id: 本次安装的 uuid；nil = 未知。
    /// - Returns: 实际删除的路径（诊断日志用）。
    @discardableResult
    public static func sweepTransientArtifacts(in directory: URL, id: String?) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names {
            let matched: Bool
            if let id {
                matched = name == "\(extractionDirPrefix)\(id)"
                    || name == "\(scriptNamePrefix)\(id).sh"
                    || name == "\(resultNamePrefix)\(id).json"
            } else {
                matched = isScriptShape(name) || isResultShape(name)
            }
            guard matched else { continue }
            let url = directory.appendingPathComponent(name)
            if (try? fm.removeItem(at: url)) != nil {
                removed.append(url.path)
            }
        }
        return removed
    }

    /// 陈旧解压目录的兜底清扫（issue #24 的另一半）。
    ///
    /// 解压目录的 uuid 由 `prepare()` 另生成，与脚本/result 的 uuid **不是同一个**，
    /// 旧版本 pending 又不记它的路径——「同一 uuid」匹配不到，只能按形状 + 年龄收敛。
    /// 三个条件缺一不删：
    /// ① 名字严格是 `kairo-ota-<UUID>`（脚本、下载 zip 等不在此列）；
    /// ② 内容是「恰好一个 .app」的解压形状（空目录/别的内容不猜）；
    /// ③ mtime 早于 `olderThan`（默认 1 小时）——正在用的解压目录一定比这新。
    ///
    /// 仍然不做 `kairo-ota-*` 前缀批量删：那是「把别人的东西一起删」，不是清理。
    ///
    /// - Parameters:
    ///   - directory: 待清扫目录（生产 = 临时目录）。
    ///   - olderThan: 判定残留的最小年龄（秒）。
    /// - Returns: 实际删除的路径（诊断日志用）。
    @discardableResult
    public static func sweepStaleExtractionDirectories(
        in directory: URL, olderThan minAge: TimeInterval = staleExtractionMinAge
    ) -> [String] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: directory.path) else { return [] }
        var removed: [String] = []
        for name in names where isExtractionDirName(name) {
            let url = directory.appendingPathComponent(name)
            guard let attributes = try? fm.attributesOfItem(atPath: url.path),
                  attributes[.type] as? FileAttributeType == .typeDirectory,
                  let modified = attributes[.modificationDate] as? Date,
                  Date().timeIntervalSince(modified) >= minAge else { continue }
            guard let contents = try? fm.contentsOfDirectory(
                at: url, includingPropertiesForKeys: nil),
                contents.count == 1,
                contents[0].pathExtension == "app" else { continue }
            if (try? fm.removeItem(at: url)) != nil {
                removed.append(url.path)
            }
        }
        return removed
    }

    /// 编码 result JSON（与脚本写入、App 首启读取同构；测试夹具复用）。
    public static func encodeResult(_ result: InstallResult) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(result)
    }

    /// 同步跑子进程（解压），非 0 退出抛错（stderr 并入错误）。
    static func runProcess(_ executable: String, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args
        let stderr = Pipe()
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let detail = String(
                data: stderr.fileHandleForReading.readDataToEndOfFile(),
                encoding: .utf8
            )?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let suffix = detail.isEmpty ? "" : "：\(detail)"
            throw NSError(
                domain: "ZipAppInstaller", code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: "\(executable) 退出码 \(process.terminationStatus)\(suffix)"])
        }
    }
}

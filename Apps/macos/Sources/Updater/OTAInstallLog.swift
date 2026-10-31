// OTAInstallLog.swift -- OTA 安装链路的决策留痕（issue #17 取证缺口）。
//
// 为什么需要它（2026-10-28 复盘）：现场只有一个替换脚本写的 app_not_quitting，
// 没有任何记录说明「谁在什么状态下拒绝了退出」，只能靠 ps 启动时刻反推跑的是
// 哪个 build。武装 / terminate / 裁决三个时刻此后各留一行。
//
// 双写：
//   - os_log（subsystem app.zeno.macos / category ota）——与 ZenoUpdater 同通道
//   - ~/Library/Logs/Zeno/ota.log —— tools/ota-local-verify.sh 直接 grep 这个文件
//
// 纪律：日志是旁路，任何写入失败一律静默——不给安装路径引入新的失败点；
// 文案一律 ASCII（tools/i18n-lint.sh 扫 Apps/macos/Sources 的中文字面量）。

import Foundation
import ZenoUpdater
import os

/// OTA 决策日志（os_log + 文件双写）。
enum OTAInstallLog {
    private static let logger = Logger(subsystem: "app.zeno.macos", category: "ota")
    private static let logURL = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Logs/Zeno/ota.log", isDirectory: false)

    /// 构建标识 `1.3.0+20261028.0912`：判断「跑的是哪个 build」的第一手信息。
    static var buildTag: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "0.0.0"
        let build = info["CFBundleVersion"] as? String ?? "-"
        return version + "+" + build
    }

    /// 记一行（event 用稳定短名，details 放 key=value；两者都不得含中文）。
    ///
    /// 同步写文件：最关键的一条（`reply=terminateNow`）就在退出路径上，
    /// 异步写会在进程消失前丢掉——这类日志一旦丢，等于没加。
    static func note(_ event: String, _ details: String = "") {
        let line = stamp.string(from: Date())
            + " build=" + buildTag
            + " " + event
            + (details.isEmpty ? "" : " " + details)
        logger.notice("\(line, privacy: .public)")
        appendToFile(line)
    }

    /// 状态短名：日志只认稳定短名，不打印关联值（进度/版本会变，短名不会）。
    static func name(_ state: UpdaterState) -> String {
        switch state {
        case .idle: return "idle"
        case .checking: return "checking"
        case .updateAvailable: return "updateAvailable"
        case .upToDate: return "upToDate"
        case .downloading: return "downloading"
        case .downloaded: return "downloaded"
        case .installing: return "installing"
        case .failed: return "failed"
        }
    }

    private static let stamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return formatter
    }()

    /// 追加一行到 ota.log（首次创建目录与文件）。失败静默：日志不能影响安装。
    private static func appendToFile(_ line: String) {
        let fileManager = FileManager.default
        guard let data = (line + "\n").data(using: .utf8) else { return }
        if !fileManager.fileExists(atPath: logURL.path) {
            try? fileManager.createDirectory(
                at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: logURL)
            return
        }
        guard let handle = try? FileHandle(forWritingTo: logURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }
}

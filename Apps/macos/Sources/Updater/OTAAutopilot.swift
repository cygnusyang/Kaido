// OTAAutopilot.swift -- DEBUG 自动驾驶：无人值守跑完 检查 -> 下载 -> 安装。
//
// 为什么需要它（2026-10-28）：tools/ota-local-verify.sh 能把本地清单与包准备好，
// 但最后三步要点面板按钮，而 SwiftUI 面板的按钮不暴露给 Accessibility
// （`buttons of sheet` 为空，坐标点击会打偏）——UI 自动化这条路是死的。于是把
// 「按按钮」换成应用内驱动：同一份 OTAInstallSequence，同一套状态机，只是触发者
// 从鼠标换成了环境变量。
//
// 只在 DEBUG 编译存在（release 里这段代码与 `KAIRO_OTA_AUTOPILOT` 一起消失）。
//
// 环境变量：
//   KAIRO_OTA_AUTOPILOT=1        启用自动驾驶
//   KAIRO_OTA_AUTOPILOT_STATE    （可选）状态文件路径：记录 pid 与替换脚本要写的
//                                结果文件路径，供闭环脚本抓取安装结果
//
// 留痕格式（写 ota.log，tools/ota-loop-verify.sh 直接 grep）：
//   autopilot step=check|download|install   进入某一步
//   autopilot step=<x> error=<code>         某一步失败（code = UpdaterErrorCode）
//   autopilot finished reason=<reason>      无需安装即收工（如 upToDate）

#if DEBUG

import Foundation
import KairoUpdater

/// DEBUG 自动驾驶。
///
/// 决策表（isEnabled / afterCheck / afterDownload）刻意不是 MainActor：它们是纯函数，
/// 单测可同步断言。只有真正驱动 UI 与状态机的 start / drive 标注 @MainActor。
enum OTAAutopilot {
    /// 启用开关（值为 `1` 才算开启，其余一律不启用）。
    static let environmentKey = "KAIRO_OTA_AUTOPILOT"
    /// 状态文件路径（可选；未设则不写）。
    static let statePathKey = "KAIRO_OTA_AUTOPILOT_STATE"
    /// 启动宽限：等窗口与 SwiftUI 场景就绪再动手（面板要能真的弹出并被收起）。
    static let startupDelayNanoseconds: UInt64 = 3_000_000_000

    /// 驾驶步骤（日志里的 step= 取值）。
    enum Step: String {
        case check
        case download
        case install
    }

    /// 一步之后的决定。
    enum Decision: Equatable {
        /// 继续执行该步骤。
        case run(Step)
        /// 不需要再做什么（例如已是最新）。
        case finished(reason: String)
        /// 停在该步骤并报错（code 为稳定错误码）。
        case failed(step: Step, code: String)
    }

    /// 开关判定（纯函数）。
    nonisolated static func isEnabled(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        environment[environmentKey] == "1"
    }

    /// 检查之后的下一步（纯函数，单测直接断言）。
    nonisolated static func afterCheck(_ state: UpdaterState) -> Decision {
        switch state {
        case .updateAvailable:
            return .run(.download)
        case .upToDate:
            return .finished(reason: "upToDate")
        case .failed(let failure):
            return .failed(step: .check, code: failure.code.rawValue)
        case .idle, .checking, .downloading, .downloaded, .installing:
            return .failed(step: .check, code: "unexpected_state_" + OTAInstallLog.name(state))
        }
    }

    /// 下载之后的下一步（纯函数，单测直接断言）。
    nonisolated static func afterDownload(_ state: UpdaterState) -> Decision {
        switch state {
        case .downloaded:
            return .run(.install)
        case .failed(let failure):
            return .failed(step: .download, code: failure.code.rawValue)
        case .idle, .checking, .updateAvailable, .upToDate, .downloading, .installing:
            return .failed(step: .download, code: "unexpected_state_" + OTAInstallLog.name(state))
        }
    }

    /// 若开关打开则启动自动驾驶（未打开时完全 no-op）。
    ///
    /// - Parameters:
    ///   - updater: OTA 状态机。
    ///   - present: 弹出更新面板（生产 = 宿主 `showUpdateSheet = true`）。
    ///   - dismiss: 收起更新面板（生产 = 宿主 `showUpdateSheet = false`）。
    ///   - preflight: 安装前收口（生产 = `OTAInstallPreflight.run(store:)`）。
    @MainActor
    static func start(
        updater: UpdaterManager,
        present: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void,
        preflight: @escaping @MainActor () -> UpdaterFailure?
    ) {
        guard isEnabled() else { return }
        Task {
            await drive(updater: updater, present: present, dismiss: dismiss, preflight: preflight)
        }
    }

    /// 驾驶主体：check -> download -> install，每步都留一行 ota.log。
    @MainActor
    private static func drive(
        updater: UpdaterManager,
        present: @escaping @MainActor () -> Void,
        dismiss: @escaping @MainActor () -> Void,
        preflight: @escaping @MainActor () -> UpdaterFailure?
    ) async {
        let stateURL = ProcessInfo.processInfo.environment[statePathKey]
            .map { URL(fileURLWithPath: $0) }
        write(state: "start", details: "pid=\(ProcessInfo.processInfo.processIdentifier)",
              to: stateURL)

        try? await Task.sleep(nanoseconds: startupDelayNanoseconds)
        // 面板必须真的弹出：面板是 sheet，AppKit 在窗口挂着 sheet 时会推迟终止流程
        // （#17 的现场）。不弹面板就测不到这条路径。
        present()

        OTAInstallLog.note("autopilot step=check")
        await updater.check()
        var decision = afterCheck(updater.state)
        if case .run(.download) = decision {
            OTAInstallLog.note("autopilot step=download")
            await updater.download()
            decision = afterDownload(updater.state)
        }

        switch decision {
        case .finished(let reason):
            OTAInstallLog.note("autopilot finished", "reason=\(reason)")
        case .failed(let step, let code):
            OTAInstallLog.note("autopilot step=\(step.rawValue) error=\(code)")
            write(state: "error", details: "step=\(step.rawValue) code=\(code)", to: stateURL)
        case .run(.install):
            OTAInstallLog.note("autopilot step=install")
            await OTAInstallSequence.run(
                updater: updater,
                preflight: preflight,
                dismiss: dismiss,
                onArmed: { writeArmedState(to: stateURL) }
            )
        case .run(.check), .run(.download):
            // 不可达：检查之后只会落到 download / finished / failed。
            break
        }
    }

    /// 武装后把「替换脚本会写到哪个结果文件」交给外部脚本：脚本据此精确抓取
    /// 安装结果（结果文件会在重启后的 App 首启时被消费删除，晚一步就没了）。
    private static func writeArmedState(to stateURL: URL?) {
        let resultPath = UserDefaults.standard.string(
            forKey: ZipAppInstaller.pendingResultPathDefaultsKey) ?? ""
        write(
            state: "armed",
            details: "pid=\(ProcessInfo.processInfo.processIdentifier) result_path=\(resultPath)",
            to: stateURL)
    }

    /// 追加一行到状态文件（同步写：进程随时可能退出）。未设路径或写失败一律静默。
    private static func write(state: String, details: String, to url: URL?) {
        guard let url, let data = (state + " " + details + "\n").data(using: .utf8) else {
            return
        }
        if let handle = try? FileHandle(forWritingTo: url) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            return
        }
        try? data.write(to: url)
    }
}

#endif

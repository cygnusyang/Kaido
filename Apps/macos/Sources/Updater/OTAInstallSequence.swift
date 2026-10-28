// OTAInstallSequence.swift -- "退出并安装"的驱动序列（面板按钮与 DEBUG 自动驾驶共用）。
//
// 为什么抽出来：从「下载完成」到「收面板 -> terminate」这条链是 issue #17 的复发点，
// tools/ota-loop-verify.sh 要在无人值守下跑同一条路。自动驾驶若另写一份，验证通过也
// 证明不了面板按钮走的那条路——两份实现只会各自漂移。
//
// 纪律：本序列只做驱动与留痕，退出判定（AppDelegate.terminationReply）一字不动。

import AppKit
import Foundation
import KairoUpdater

/// 「退出并安装」序列：装前收口 -> 武装替换脚本 -> 收面板 -> terminate。
@MainActor
enum OTAInstallSequence {
    /// 执行安装序列。
    ///
    /// - Parameters:
    ///   - updater: OTA 状态机。起点应为 `.downloaded`（`.updateAvailable` 时
    ///     `install` 内部先补下载，与面板按钮的行为一致）。
    ///   - preflight: 启动替换脚本**之前**的收口（生产 = 落盘未保存修改）。
    ///   - dismiss: 收起更新面板（生产 = 宿主 `onRequestClose`）。
    ///   - onArmed: 脚本已成功启动（武装）后的回调。DEBUG 自动驾驶用它把结果文件
    ///     路径交给外部脚本；面板不关心（默认 nil）。
    static func run(
        updater: UpdaterManager,
        preflight: @escaping @MainActor () -> UpdaterFailure?,
        dismiss: @escaping () -> Void,
        onArmed: (() -> Void)? = nil
    ) async {
        let requestedAt = Date()
        OTAInstallLog.note("install requested", "state=\(OTAInstallLog.name(updater.state))")
        await updater.install(preflight: {
            // 包一层只为记收口结论：失败时脚本根本没启动，这是与「退了但没装上」
            // 完全不同的两种现场。
            let failure = preflight()
            OTAInstallLog.note("preflight", failure.map { "failed=\($0)" } ?? "ok")
            return failure
        })
        // 只有武装成功（脚本已启动）才进入退出序列；失败/收口被拒时停在
        // .failed，用户可重试或关闭——绝不把面板留在无按钮的安装态。
        guard updater.isInstallingUpdate else {
            OTAInstallLog.note(
                "install not armed; terminate skipped",
                "state=\(OTAInstallLog.name(updater.state))"
            )
            return
        }
        OTAInstallLog.note(
            "install armed",
            "after_ms=\(Int(Date().timeIntervalSince(requestedAt) * 1000))"
                + " state=\(OTAInstallLog.name(updater.state))"
        )
        onArmed?()
        try? await Task.sleep(nanoseconds: 500_000_000)
        // 先收面板再退：面板是 sheet，AppKit 会因窗口仍挂着 sheet 推迟终止流程，
        // terminate 走不到 applicationShouldTerminate（2026-10-28 现场：armed 之后
        // 没有任何 reply）。收面板走宿主的关闭请求而非 updater.dismiss()——后者会把
        // 状态打回 idle，武装旁路失效。
        OTAInstallExit.run(
            dismiss: dismiss,
            terminate: { NSApp.terminate(nil) })
    }
}

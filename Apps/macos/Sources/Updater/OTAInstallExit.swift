// OTAInstallExit.swift -- 「退出并安装」的最后一段：先收面板，再 terminate。
//
// 2026-10-28 现场（tools/ota-local-verify.sh 实跑）：ota.log 停在
//   install requested -> preflight ok -> install armed -> NSApp.terminate called
// 之后再没有任何 termination reply，进程仍存活、脚本 60s 后写 app_not_quitting。
// 根因不是判定逻辑：更新面板是 .sheet，AppKit 在窗口仍挂着 sheet 时会推迟
// 终止流程——NSApp.terminate 走不到 applicationShouldTerminate，
// 于是 #17 的「武装后旁路」压根没被问到。
//
// 所以退出序列固定为三段，顺序不可颠倒：
//   sheet dismissed -> 让关闭真正生效（一个 runloop 回合）
//   -> NSApp.terminate called -> terminate
//
// 纪律：只做「收面板 + 退出」两件事，判定（AppDelegate.applicationShouldTerminate
// 的 terminateNow / 未保存裁决）一字不动。收面板必须走宿主的关闭请求
// （presented=false），不能走 updater.dismiss()——那会把状态从 .installing
// 打回 idle，武装旁路失效，又会退回到未保存裁决的模态框。

import Foundation

/// 面板收起动画的最短窗口：SwiftUI sheet 收起约 0.25s，留一点余量，
/// 保证 terminate 时窗口上已经没有 attachedSheet。
private let otaSheetCloseDelay: TimeInterval = 0.35

/// 退出序列（收面板 → 让出一回合 → terminate），钩子全部可注入以便断言调用顺序。
@MainActor
enum OTAInstallExit {
    /// 关键事件留痕（生产 = OTAInstallLog.note；测试注入数组收集）。
    typealias Log = (_ event: String, _ details: String) -> Void

    /// 执行退出序列。
    ///
    /// - Parameters:
    ///   - dismiss: 关闭更新面板（生产 = 宿主 onRequestClose）。
    ///   - terminate: 真正的退出调用（生产 = NSApp.terminate(nil)）。
    ///   - log: 留痕，默认双写 os_log 与 ota.log。
    ///   - afterSheetClose: 关闭之后、terminate 之前的「让出一回合」，默认在主队列
    ///     延迟 otaSheetCloseDelay 执行；测试注入同步执行以便断言顺序。
    static func run(
        dismiss: @escaping () -> Void,
        terminate: @escaping () -> Void,
        log: @escaping Log = { OTAInstallLog.note($0, $1) },
        afterSheetClose: (@escaping () -> Void) -> Void = { action in
            DispatchQueue.main.asyncAfter(
                deadline: .now() + otaSheetCloseDelay,
                execute: DispatchWorkItem(block: action))
        }
    ) {
        dismiss()
        log("sheet dismissed", "")
        afterSheetClose {
            log("NSApp.terminate called", "")
            terminate()
        }
    }
}

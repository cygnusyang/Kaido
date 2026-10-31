import Foundation
import Testing
import KaidoUpdater
@testable import KaidoMacApp

/// 更新面板（sheet）挡住退出：install armed 之后没有任何 termination reply，进程存活。
///
/// 硬约束只有两条：
/// ① 收面板必须发生在 terminate 之前（AppKit 有 attachedSheet 就不走终止流程）；
/// ② 两者各只调用一次——重复 terminate 或漏掉收面板都会让脚本走到 app_not_quitting。
/// 判定逻辑（applicationShouldTerminate）不在此处断言，见 OTAInstallGuardTests。
@MainActor
@Suite("OTA 退出序列（先收面板再 terminate）")
struct OTAInstallExitTests {
    /// 把动作与日志记进同一条流水：顺序断言才有意义。
    private final class Recorder {
        private(set) var events: [String] = []
        private var deferred: (() -> Void)?

        func record(_ event: String) { events.append(event) }
        func hold(_ action: @escaping () -> Void) { deferred = action }

        /// 放行「让出一回合」里挂起的动作（模拟 runloop 回合结束）。
        func flush() {
            let action = deferred
            deferred = nil
            action?()
        }

        func count(_ event: String) -> Int { events.filter { $0 == event }.count }
    }

    @Test func sheetIsDismissedBeforeTerminate() {
        let recorder = Recorder()
        OTAInstallExit.run(
            dismiss: { recorder.record("dismiss") },
            terminate: { recorder.record("terminate") },
            log: { event, _ in recorder.record("log:" + event) },
            afterSheetClose: { action in
                recorder.record("sheet-close-settled")
                recorder.hold(action)
            })

        // 关闭已发生、退出尚未发生：两者不在同一拍里抢顺序。
        #expect(recorder.events == ["dismiss", "log:sheet dismissed", "sheet-close-settled"])
        #expect(recorder.count("terminate") == 0)

        recorder.flush()

        #expect(recorder.events == [
            "dismiss",
            "log:sheet dismissed",
            "sheet-close-settled",
            "log:NSApp.terminate called",
            "terminate",
        ])
        #expect(recorder.count("dismiss") == 1)
        #expect(recorder.count("terminate") == 1)
    }

    @Test func logShowsSheetDismissedBeforeTerminate() {
        let recorder = Recorder()
        OTAInstallExit.run(
            dismiss: { recorder.record("dismiss") },
            terminate: { recorder.record("terminate") },
            log: { event, _ in recorder.record("log:" + event) },
            afterSheetClose: { action in action() })

        // ota.log 必须能读出可判读序列：armed -> sheet dismissed -> terminate。
        guard let dismissed = recorder.events.firstIndex(of: "log:sheet dismissed"),
              let terminateCall = recorder.events.firstIndex(of: "log:NSApp.terminate called") else {
            Issue.record("缺少 sheet dismissed 或 NSApp.terminate called，实际 \(recorder.events)")
            return
        }
        #expect(dismissed < terminateCall)
        #expect(recorder.events.last == "terminate")
        #expect(recorder.count("dismiss") == 1)
        #expect(recorder.count("terminate") == 1)
    }
}

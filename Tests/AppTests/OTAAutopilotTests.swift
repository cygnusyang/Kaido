import Foundation
import Testing
import ZenoUpdater
@testable import ZenoMacApp

/// DEBUG 自动驾驶的决策表（触发由 tools/ota-loop-verify.sh 注入，判定在此断言）。
///
/// 只测纯函数：真正的四步驱动要真网络/真文件，交给闭环脚本跑真升级；这里保证
/// 「哪种状态走哪一步、失败怎么归因」不含糊——归因错了，脚本报的阶段就是假的。
@Suite("OTA 自动驾驶（DEBUG）")
struct OTAAutopilotTests {
    #if DEBUG
    /// 构造一个可用版本信息（字段与 schema v1 一致；签名内容不参与本用例）。
    private func makeUpdateInfo() throws -> UpdateInfo {
        let json: [String: Any] = [
            "schemaVersion": 1,
            "appId": "app.zeno.test",
            "version": "1.1.0",
            "minimumVersion": "1.0.0",
            "buildTime": "2026-10-20T08:00:00Z",
            "downloadUrl": "https://github.com/example/test/releases/download/v1.1.0/Test.zip",
            "cdHash": String(repeating: "a", count: 40),
            "securityCritical": false,
            "signature": "unused-in-this-test",
        ]
        let data = try JSONSerialization.data(withJSONObject: json)
        let manifest = try UpdateManifest.parse(data, expectedAppId: "app.zeno.test")
        return try UpdateInfo(manifest: manifest)
    }

    @Test func enabledOnlyWhenFlagIsOne() {
        #expect(OTAAutopilot.isEnabled(environment: ["ZENO_OTA_AUTOPILOT": "1"]))
        #expect(!OTAAutopilot.isEnabled(environment: ["ZENO_OTA_AUTOPILOT": "0"]))
        #expect(!OTAAutopilot.isEnabled(environment: ["ZENO_OTA_AUTOPILOT": "true"]))
        #expect(!OTAAutopilot.isEnabled(environment: [:]))
    }

    @Test func availableVersionLeadsToDownload() throws {
        #expect(OTAAutopilot.afterCheck(.updateAvailable(try makeUpdateInfo())) == .run(.download))
    }

    @Test func upToDateFinishesWithoutInstall() {
        #expect(OTAAutopilot.afterCheck(.upToDate) == .finished(reason: "upToDate"))
    }

    @Test func checkFailureIsAttributedToCheck() {
        let failure = UpdaterFailure(code: .checkFailed, parameters: ["ref": "OTA-E-2001"])
        #expect(OTAAutopilot.afterCheck(.failed(failure))
            == .failed(step: .check, code: "updater_check_failed"))
    }

    @Test func downloadedLeadsToInstall() {
        #expect(OTAAutopilot.afterDownload(.downloaded) == .run(.install))
    }

    @Test func downloadFailureIsAttributedToDownload() {
        let failure = UpdaterFailure(code: .checksumMismatch)
        #expect(OTAAutopilot.afterDownload(.failed(failure))
            == .failed(step: .download, code: "updater_checksum_mismatch"))
    }

    /// 不该出现的状态必须显式报错，而不是静默收工（静默 = 脚本白等到超时）。
    @Test func unexpectedStatesAreReportedNotIgnored() throws {
        #expect(OTAAutopilot.afterCheck(.idle)
            == .failed(step: .check, code: "unexpected_state_idle"))
        #expect(OTAAutopilot.afterCheck(.downloading(0.5))
            == .failed(step: .check, code: "unexpected_state_downloading"))
        #expect(OTAAutopilot.afterDownload(.updateAvailable(try makeUpdateInfo()))
            == .failed(step: .download, code: "unexpected_state_updateAvailable"))
    }
    #endif
}

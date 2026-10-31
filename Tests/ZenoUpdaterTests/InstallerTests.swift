import Foundation
import Testing
@testable import ZenoUpdater

/// 安装层：解压、脚本契约、清理守卫（真实 ditto/codesign，无网络）。
@Suite("OTA 安装层")
struct InstallerTests {
    @Test func prepareExtractsAppFromZip() async throws {
        // 构造最小 .app → ditto 打 zip → prepare 解压取回 .app
        let fixtureDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-ota-fixture-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDir.appendingPathComponent("Test.app/Contents/MacOS"),
            withIntermediateDirectories: true)
        try Data("#!/bin/sh\n".utf8).write(
            to: fixtureDir.appendingPathComponent("Test.app/Contents/MacOS/Test"))
        let zipURL = fixtureDir.appendingPathComponent("Test.zip")
        try InstallerScript.runProcess(
            "/usr/bin/ditto", args: ["-c", "-k", "--keepParent",
                                     fixtureDir.appendingPathComponent("Test.app").path, zipURL.path])
        defer { try? FileManager.default.removeItem(at: fixtureDir) }

        let installer = ZipAppInstaller()
        let app = try await installer.prepare(downloadedArchive: zipURL)
        #expect(app.pathExtension == "app")
        #expect(app.lastPathComponent == "Test.app")
        // 清理解压目录（前缀守卫）
        InstallerScript.cleanupFailedProductExtractionDir(of: app)
        #expect(!FileManager.default.fileExists(atPath: app.deletingLastPathComponent().path))
    }

    @Test func replacementScriptWaitsBacksUpReplacesAndReports() throws {
        // 脚本契约真机验证：当前 pid 用一个即将退出的 sleep 子进程替代——
        // 直接以「pid 已退出」路径验证 备份→替换→result 握手。
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-ota-script-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let currentApp = dir.appendingPathComponent("Current.app")
        let newApp = dir.appendingPathComponent("New.app")
        for (app, marker) in [(currentApp, "old"), (newApp, "new")] {
            try FileManager.default.createDirectory(
                at: app.appendingPathComponent("Contents/MacOS"),
                withIntermediateDirectories: true)
            try Data(marker.utf8).write(
                to: app.appendingPathComponent("Contents/MacOS/Runner"))
        }
        let backup = dir.appendingPathComponent("Zeno-123.app")
        let result = dir.appendingPathComponent("zeno-ota-result-test.json")
        let scriptPath = dir.appendingPathComponent("install.sh")
        // pid=1（launchd，永存活）改为已退出 pid：用 pid 999999（大概率不存在）→ 立即通过
        let script = InstallerScript.replacement(
            newAppPath: newApp.path, currentAppPath: currentApp.path,
            backupPath: backup.path, resultFilePath: result.path, pid: 999_999)
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)

        try InstallerScript.runProcess("/bin/bash", args: [scriptPath.path])

        #expect(FileManager.default.fileExists(atPath: currentApp.appendingPathComponent("Contents/MacOS/Runner").path))
        #expect(try String(contentsOf: currentApp.appendingPathComponent("Contents/MacOS/Runner"), encoding: .utf8) == "new")
        #expect(FileManager.default.fileExists(atPath: backup.appendingPathComponent("Contents/MacOS/Runner").path))
        let decoded = try JSONDecoder().decode(
            InstallResult.self, from: try Data(contentsOf: result))
        // headless 环境 `open` 拉不起无 Info.plist 的夹具 App → 走「已替换但自动
        // 启动失败」回退分支（success=true, code=1）；核心契约（备份+替换+result
        // 握手）已由上面三个断言锁定。
        #expect(decoded.success)
        #expect(decoded.code == 1)
        // F-0719：结果 JSON 的 message 现在是稳定码（脚本不再写中文，更新面板按码渲染）。
        #expect(decoded.message == "relaunch_failed")
        #expect(decoded.reason == .relaunchFailed)
    }

    /// F-0719：脚本正文（会落盘到用户磁盘、并写进 result JSON）不得出现任何中文——
    /// 面板直接渲染 result 里的 message，中文会漏到英文界面。
    @Test func replacementScriptContainsNoNaturalLanguage() {
        let script = InstallerScript.replacement(
            newAppPath: "/tmp/New.app",
            currentAppPath: "/Applications/Zeno.app",
            backupPath: "/tmp/Zeno-123.app",
            resultFilePath: "/tmp/zeno-ota-result-1.json",
            pid: 42
        )
        let cjk = script.unicodeScalars.filter { (0x4E00...0x9FFF).contains($0.value) }
        #expect(cjk.isEmpty, "替换脚本含中文：\(String(cjk))；脚本只允许写稳定码")

        for token in ["app_not_quitting", "backup_failed", "replace_failed", "relaunch_failed"] {
            #expect(script.contains(token), "脚本缺少失败码 \(token)")
        }
    }

    @Test func shapeGuardsFailClosed() {
        #expect(InstallerScript.isBackupShape("/tmp/Zeno-1712345678.app"))
        #expect(!InstallerScript.isBackupShape("/tmp/Other-1712345678.app"))
        #expect(!InstallerScript.isBackupShape("/tmp/Zeno-backup.txt"))
        #expect(InstallerScript.isResultShape("/tmp/zeno-ota-result-ABC.json"))
        #expect(!InstallerScript.isResultShape("/tmp/other-file.json"))
    }

    // MARK: - issue #24 跨版本残留清扫

    /// 造一套「一次安装的产物」：解压目录 / 脚本 / result 共用同一个 uuid。
    private func makeArtifactSet(in root: URL, id: String = UUID().uuidString) throws -> (
        id: String, dir: URL, script: URL, result: URL
    ) {
        let fm = FileManager.default
        let dir = root.appendingPathComponent("zeno-ota-\(id)", isDirectory: true)
        try fm.createDirectory(
            at: dir.appendingPathComponent("Zeno.app", isDirectory: true),
            withIntermediateDirectories: true)
        let script = root.appendingPathComponent("zeno-ota-install-\(id).sh")
        let result = root.appendingPathComponent("zeno-ota-result-\(id).json")
        try Data("#!/bin/bash\n".utf8).write(to: script)
        try Data("{}".utf8).write(to: result)
        return (id, dir, script, result)
    }

    private func makeSweepRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-ota-sweep-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    /// 同一 uuid 的三件套被清掉，相邻 uuid 的产物一个都不动。
    @Test func sweepRemovesSameUUIDArtifactsOnly() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = try makeArtifactSet(in: root)
        let neighbour = try makeArtifactSet(in: root)

        let removed = InstallerScript.sweepTransientArtifacts(in: root, id: target.id)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: target.dir.path))
        #expect(!fm.fileExists(atPath: target.script.path))
        #expect(!fm.fileExists(atPath: target.result.path))
        #expect(removed.count == 3, "应恰好删掉目标 uuid 的三件套，实际 \(removed)")
        #expect(fm.fileExists(atPath: neighbour.dir.path), "相邻 uuid 的目录不得误删")
        #expect(fm.fileExists(atPath: neighbour.script.path), "相邻 uuid 的脚本不得误删")
        #expect(fm.fileExists(atPath: neighbour.result.path), "相邻 uuid 的 result 不得误删")
    }

    /// uuid 无法确定时只清脚本与 result，目录保留（禁止宽前缀批量删目录）。
    @Test func sweepWithoutUUIDKeepsDirectories() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let set = try makeArtifactSet(in: root)
        let decoy = root.appendingPathComponent("notes.txt")
        try Data("keep".utf8).write(to: decoy)

        InstallerScript.sweepTransientArtifacts(in: root, id: nil)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: set.script.path))
        #expect(!fm.fileExists(atPath: set.result.path))
        #expect(fm.fileExists(atPath: set.dir.path), "uuid 未知时不得按前缀删解压目录")
        #expect(fm.fileExists(atPath: decoy.path), "非本模块文件不得误删")
    }

    /// 陈旧解压目录：形状 + 单 .app + 超龄三条同时成立才删。
    @Test func staleExtractionSweepRequiresShapeContentAndAge() throws {
        let root = try makeSweepRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let stale = try makeArtifactSet(in: root)
        let fresh = try makeArtifactSet(in: root)
        // 空目录 / 名字不是 UUID 的目录：形状不成立，即使超龄也不动。
        let emptyDir = root.appendingPathComponent("zeno-ota-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
        let bogusDir = root.appendingPathComponent("zeno-ota-not-a-uuid")
        try FileManager.default.createDirectory(at: bogusDir, withIntermediateDirectories: true)
        let old = Date(timeIntervalSinceNow: -7200)
        for path in [stale.dir.path, emptyDir.path, bogusDir.path] {
            try FileManager.default.setAttributes(
                [.modificationDate: old], ofItemAtPath: path)
        }

        InstallerScript.sweepStaleExtractionDirectories(in: root, olderThan: 3600)

        let fm = FileManager.default
        #expect(!fm.fileExists(atPath: stale.dir.path), "超龄的解压目录必须清掉")
        #expect(fm.fileExists(atPath: fresh.dir.path), "新鲜目录可能正在用，不得删")
        #expect(fm.fileExists(atPath: emptyDir.path), "空目录不是解压形状，不猜")
        #expect(fm.fileExists(atPath: bogusDir.path), "名字不是 UUID，不猜")
        #expect(fm.fileExists(atPath: stale.script.path), "脚本不归这条规则管")
    }

    /// 路径 → uuid 的解析（三种形状 + 非法 uuid 一律 nil）。
    @Test func transientArtifactIDParsesKnownShapes() {
        let id = UUID().uuidString
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-install-\(id).sh") == id)
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-result-\(id).json") == id)
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-\(id)/Zeno.app") == id)
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-\(id)") == id)
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-download-\(id).zip") == nil)
        #expect(InstallerScript.transientArtifactID(fromPath: "/tmp/zeno-ota-install-abc.sh") == nil)
        #expect(InstallerScript.transientArtifactID(fromPath: "/Applications/Zeno.app") == nil)
    }

    @Test func launchPathMismatchFailsFast() async throws {
        let keys = TestKeys.makeKeyPair()
        let suite = "zeno.updatertests.mismatch.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var launched: [URL] = []
        let installer = ZipAppInstaller(
            userDefaults: defaults,
            runningAppURLProvider: { URL(fileURLWithPath: "/build/Test.app") },
            log: { _ in },
            launchScript: { url, _ in launched.append(url) })

        let info = try UpdateInfo(manifest: UpdateManifest.parse(
            try TestKeys.signedManifest(
                dict: TestKeys.manifestDict(), privateKeyBase64: keys.privateKeyBase64),
            expectedAppId: "app.zeno.test"))
        do {
            try await installer.perform(
                info: info,
                downloadedAppURL: URL(fileURLWithPath: "/tmp/zeno-ota-x/Test.app"),
                currentAppURL: URL(fileURLWithPath: "/Applications/Test.app"))
            Issue.record("期望 launchPathMismatch，实际未抛错")
        } catch let error as InstallError {
            #expect(error == .launchPathMismatch)
        }
        #expect(launched.isEmpty, "错位时不得启动脚本")
        #expect(defaults.string(forKey: ZipAppInstaller.pendingResultPathDefaultsKey) == nil,
                "错位时不得留下 pending 状态")
    }
}

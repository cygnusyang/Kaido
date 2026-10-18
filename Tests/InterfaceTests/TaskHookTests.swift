import Foundation
import Testing

/// 插件 TaskCompleted hook 契约测试（US-E5-03 验收 3）。
/// 用假 CLI 替换真实 KairoCLI，只验证匹配、跳过与退出码，不读写真实项目。
struct TaskHookTests {
    private var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // InterfaceTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent()
    }

    private var hook: URL {
        repoRoot.appendingPathComponent("Plugins/claude-code/bin/kairo-task-hook")
    }

    /// 临时目录 + 假 CLI；假 CLI 把每次调用追加到 calls.log，list 返回给定 JSON。
    private func makeFixture(tasksJSON: String) throws -> (dir: URL, cli: URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("kairo-hook-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = dir.appendingPathComponent("calls.log")
        let cli = dir.appendingPathComponent("fake-kairo")
        let script = """
        #!/bin/sh
        echo "$@" >> "\(log.path)"
        case "$1 $2" in
        "task list")
        cat <<'JSON'
        \(tasksJSON)
        JSON
        ;;
        "status update")
        echo "已回写"
        ;;
        esac
        """
        try script.write(to: cli, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: cli.path
        )
        return (dir, cli)
    }

    private func calls(_ dir: URL) -> String {
        (try? String(contentsOf: dir.appendingPathComponent("calls.log"), encoding: .utf8)) ?? ""
    }

    @discardableResult
    private func runHook(
        _ event: String,
        dir: URL,
        cli: URL,
        project: String? = "/tmp/kairo-hook-project.kairo"
    ) -> (code: Int32, stderr: String) {
        let process = Process()
        process.executableURL = hook
        var environment = ProcessInfo.processInfo.environment
        environment["KAIRO_CLI_BIN"] = cli.path
        if let project {
            environment["KAIRO_PROJECT"] = project
        } else {
            environment.removeValue(forKey: "KAIRO_PROJECT")
        }
        process.environment = environment

        let input = Pipe()
        let errors = Pipe()
        process.standardInput = input
        process.standardError = errors
        process.standardOutput = Pipe()

        do {
            try process.run()
        } catch {
            return (-1, "启动失败：\(error)")
        }
        input.fileHandleForWriting.write(Data(event.utf8))
        try? input.fileHandleForWriting.close()
        let errorData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errorData, as: UTF8.self))
    }

    private func completion(_ subject: String) -> String {
        #"{"hook_event_name":"TaskCompleted","task_subject":"\#(subject)"}"#
    }

    @Test func uniqueTitleWritesDone() throws {
        let id = UUID().uuidString
        let fixture = try makeFixture(tasksJSON: """
        [{"id":"\(id)","title":"接口设计","status":"pending"}]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(completion("接口设计"), dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(calls(fixture.dir).contains("status update \(id) --status done"))
        #expect(result.stderr.contains("已回写"))
    }

    @Test func duplicateTitlesAreSkipped() throws {
        let fixture = try makeFixture(tasksJSON: """
        [{"id":"\(UUID().uuidString)","title":"重名","status":"pending"},
         {"id":"\(UUID().uuidString)","title":"重名","status":"pending"}]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(completion("重名"), dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(!calls(fixture.dir).contains("status update"))
        #expect(result.stderr.contains("匹配 2 个"))
    }

    @Test func missingTitleIsSkipped() throws {
        let fixture = try makeFixture(tasksJSON: """
        [{"id":"\(UUID().uuidString)","title":"别的任务","status":"pending"}]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(completion("不存在"), dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(!calls(fixture.dir).contains("status update"))
        #expect(result.stderr.contains("匹配 0 个"))
    }

    @Test func completedTaskIsNotRewritten() throws {
        let fixture = try makeFixture(tasksJSON: """
        [{"id":"\(UUID().uuidString)","title":"已完成","status":"done"}]
        """)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(completion("已完成"), dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(!calls(fixture.dir).contains("status update"))
    }

    @Test func otherEventsAreIgnored() throws {
        let fixture = try makeFixture(tasksJSON: "[]")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(#"{"hook_event_name":"Stop"}"#, dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(calls(fixture.dir).isEmpty)
    }

    @Test func missingProjectIsIgnored() throws {
        let fixture = try makeFixture(tasksJSON: "[]")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(
            completion("任意"), dir: fixture.dir, cli: fixture.cli, project: nil
        )
        #expect(result.code == 0)
        #expect(calls(fixture.dir).isEmpty)
    }

    @Test(arguments: [
        "[]",                        // 事件不是对象
        "not json",                  // 非法 JSON
        #"{"hook_event_name":"TaskCompleted"}"#,              // 缺标题
        #"{"hook_event_name":"TaskCompleted","task_subject":1}"#, // 标题非字符串
    ])
    func malformedEventsExitZero(_ event: String) throws {
        let fixture = try makeFixture(tasksJSON: "[]")
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(event, dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(!calls(fixture.dir).contains("status update"))
    }

    @Test(arguments: ["null", #"{"tasks":[]}"#, "[1,2]"])
    func malformedTaskListsExitZero(_ tasksJSON: String) throws {
        let fixture = try makeFixture(tasksJSON: tasksJSON)
        defer { try? FileManager.default.removeItem(at: fixture.dir) }

        let result = runHook(completion("任意"), dir: fixture.dir, cli: fixture.cli)
        #expect(result.code == 0)
        #expect(!calls(fixture.dir).contains("status update"))
    }
}

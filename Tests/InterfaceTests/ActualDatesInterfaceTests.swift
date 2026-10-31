import Foundation
import Testing
import ZenoCore
import ZenoCommands
@testable import ZenoMCP
@testable import ZenoCLI

// 判据 13（docs/features/07-actual-dates.md §9-13 / §8）：实际时间的接口层输出。
//
// 口径：
// - CLI 文本两行「实际开始」「实际结束」，标签与 §2 命名裁决一致；
// - MCP / JSON 只多 actualStart 一个键，实际结束仍是 completedAt（不得出现 actualFinish 键）；
// - 语言显式钉死 zh-Hans：CI 为英文系统语言，不钉会因标签语言不同而假红。

private let t0 = Date(timeIntervalSince1970: 1_790_000_000)
private let t1 = t0.addingTimeInterval(86_400)

private func isoString(_ date: Date) -> String {
    ISO8601DateFormatter().string(from: date)
}

/// 建临时工作目录与 .zeno 路径；调用方用 defer 清理目录。
private func makeScratch() throws -> (dir: URL, zeno: URL) {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("zeno-actual-dates-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return (dir: dir, zeno: dir.appendingPathComponent("actual.zeno"))
}

/// 用 CLI 建项目与任务，再用会话写入实际时间（输出层用例只验渲染，不验写入口）。
private func makeTaskWithActualDates(in file: URL) throws -> UUID {
    try CLIRouter.execute(arguments: ["project", "create", "实际时间接口", "--file", file.path])
    try CLIRouter.execute(arguments: ["task", "add", "任务甲", "--file", file.path])

    let session = ZenoSession()
    _ = try session.openProject(at: file)
    let id = try #require(session.project?.tasks.first?.id)
    _ = try session.setActualStart(id: id, date: t0)
    _ = try session.setActualFinish(id: id, date: t1)
    try session.saveProject()
    return id
}

// MARK: - A-13a：CLI task get 两行

@Test func taskGetPrintsActualStartAndActualFinishLines() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    let id = try makeTaskWithActualDates(in: scratch.zeno)

    let detail = try cliOutput(arguments: ["task", "get", id.uuidString, "--file", scratch.zeno.path], environment: ["ZENO_LANG": "zh-Hans"], preferredLanguages: [])

    let startLine = "实际开始：\(isoString(t0))"
    let finishLine = "实际结束：\(isoString(t1))"
    #expect(detail.contains(startLine))
    #expect(detail.contains(finishLine))
    // 顺序：实际开始在「实际结束」之前（检查器/大纲同口径）。
    let startIndex = try #require(detail.range(of: startLine)?.lowerBound)
    let finishIndex = try #require(detail.range(of: finishLine)?.lowerBound)
    #expect(startIndex < finishIndex)
}

// MARK: - A-13a：status update 的完成行标签改为「实际结束」

@Test func statusUpdateCompletionLineIsLabelledActualFinish() throws {
    let scratch = try makeScratch()
    defer { try? FileManager.default.removeItem(at: scratch.dir) }
    try CLIRouter.execute(arguments: ["project", "create", "实际时间回写", "--file", scratch.zeno.path])
    try CLIRouter.execute(arguments: ["task", "add", "任务乙", "--file", scratch.zeno.path])
    let session = ZenoSession()
    _ = try session.openProject(at: scratch.zeno)
    let id = try #require(session.project?.tasks.first?.id)

    let output = try cliOutput(arguments: ["status", "update", id.uuidString, "--status", "done", "--file", scratch.zeno.path], environment: ["ZENO_LANG": "zh-Hans"], preferredLanguages: [])

    // 行为不变，只有标签口径改为「实际结束」（§8）。
    #expect(output.contains("实际结束："))
    #expect(!output.contains("完成于："), "旧标签「完成于」必须退场，否则口径不统一")
}

// MARK: - A-13b：MCP / JSON 只有 actualStart + completedAt

@Test func taskJsonCarriesActualStartAndKeepsCompletedAt() throws {
    let task = TaskItem(title: "任务丙", completedAt: t1, actualStart: t0)

    // MCP task_get / task_list 走 JSONValue.json(task) 的 Codable 直出。
    let encoded = try JSONValue.json(task)
    let payload = try #require(encoded.objectValue)
    #expect(payload["actualStart"] != nil)
    #expect(payload["completedAt"] != nil)
    #expect(payload["actualFinish"] == nil, "实际结束复用 completedAt，不得新增 actualFinish 键")

    // CLI --json 与 MCP 同源，同样只多一个键。
    let json = try CLIOutput.taskListJSON([task])
    #expect(json.contains("\"actualStart\""))
    #expect(json.contains("\"completedAt\""))
    #expect(!json.contains("actualFinish"))
}

import Foundation
import Testing
@testable import ZenoCore

// 实际开始（v0.12 / docs/features/07-actual-dates.md §2 §7）：
// 模型层只新增 actualStart 一个字段；实际结束复用既有 completedAt，不新增 actualFinish。
// 旧文件缺键 → nil，格式版本仍为 1（不迁移）。

/// 固定时间戳夹具：不读墙钟，断言与构造共用同一常量。
private let actualStartFixture = Date(timeIntervalSince1970: 1_760_000_000)
private let completedAtFixture = Date(timeIntervalSince1970: 1_760_086_400)

struct TaskItemActualDatesTests {
    /// 新增字段默认 nil：既有构造调用无需任何改动即可编译与运行。
    @Test func actualStartDefaultsToNil() {
        let task = TaskItem(title: "无实际时间的任务")
        #expect(task.actualStart == nil)
        #expect(task.completedAt == nil)
    }

    /// 构造参数追加在末尾（设计 §6 契约），既有参数顺序不变。
    @Test func initAcceptsActualStartAsTrailingParameter() {
        let task = TaskItem(
            title: "已开工任务",
            completedAt: completedAtFixture,
            assignments: [],
            actualStart: actualStartFixture
        )
        #expect(task.actualStart == actualStartFixture)
        #expect(task.completedAt == completedAtFixture)
    }

    /// 磁盘键为 camelCase "actualStart"，与 startDate 同写法（ISO8601 由 ZenoFile 统一设置）。
    @Test func encodesActualStartUnderCamelCaseKey() throws {
        let task = TaskItem(title: "已开工任务", actualStart: actualStartFixture)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let json = String(decoding: try encoder.encode(task), as: UTF8.self)
        #expect(json.contains("\"actualStart\""))
        // 实际结束不得出现新键：语义由 completedAt 承担。
        #expect(!json.contains("\"actualFinish\""))
    }

    /// 往返：actualStart 与 completedAt 均按 ISO8601 精确还原。
    @Test func roundTripsActualDatesThroughCodable() throws {
        let task = TaskItem(
            title: "已开工任务",
            completedAt: completedAtFixture,
            actualStart: actualStartFixture
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(TaskItem.self, from: try encoder.encode(task))
        #expect(decoded.actualStart == actualStartFixture)
        #expect(decoded.completedAt == completedAtFixture)
    }

    /// 旧 .zeno（无 actualStart 键）解码为 nil，不报错（ADR-011 前向兼容）。
    @Test func legacyPayloadWithoutActualStartDecodesAsNil() throws {
        let legacy = """
        {"id":"\(UUID().uuidString)","title":"旧任务","notes":"","priority":"normal","status":"in_progress","tags":[],"kind":"task","dependencies":[],"progress":0.5,"schedulingPolicy":"asap","assignments":[]}
        """
        let task = try JSONDecoder().decode(TaskItem.self, from: Data(legacy.utf8))
        #expect(task.actualStart == nil)
        #expect(task.status == .inProgress)
    }

    /// 新增字段参与 Equatable/Hashable：actualStart 不同即不同任务。
    @Test func actualStartParticipatesInEquatable() {
        var started = TaskItem(title: "任务")
        let untouched = TaskItem(id: started.id, title: "任务")
        started.actualStart = actualStartFixture
        #expect(untouched != started)
        #expect(Set([untouched, started]).count == 2)
    }
}

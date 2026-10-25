import Foundation
import KairoCore

/// 机器可读输出（US-E5-02 验收 2）：供脚本与插件 hook 直接解析。
/// 字段与 `.kairo` 模型一致（camelCase、ISO 8601 日期），不做二次裁剪。
enum CLIOutput {
    static func taskListJSON(_ tasks: [TaskItem]) throws -> String {
        try encode(tasks)
    }

    /// `baseline list --json`：字段与 MCP `baseline_list` 同名同义。
    static func baselineListJSON(_ baselines: [Baseline]) throws -> String {
        let payload = BaselineListPayload(
            baselines: baselines.map {
                BaselineListPayload.Row(
                    baselineID: $0.id.uuidString,
                    name: $0.name,
                    createdAt: $0.createdAt,
                    anchor: $0.anchor,
                    entryCount: $0.entries.count
                )
            }
        )
        return try encode(payload)
    }

    /// `baseline variance --json`：字段与 `BaselineVarianceReport` / `TaskVariance`
    /// 逐字段同名同义（判据 12 对等性门禁）。
    ///
    /// - 空值（`nil`）**不写键**：写成 0 会把「没有数据」冒充成「准时」（§4.1）；
    /// - 偏差是整数天，负数原样带 `-`；
    /// - `taskIDs` 决定行顺序（调用方按大纲顺序给出，见 `orderedTaskIDs(_:projectOrder:)`）。
    static func baselineVarianceJSON(_ report: BaselineVarianceReport, taskIDs: [UUID]) throws -> String {
        let rows = taskIDs.compactMap { taskID -> BaselineVariancePayload.TaskRow? in
            guard let variance = report.tasks[taskID] else { return nil }
            return BaselineVariancePayload.TaskRow(
                taskID: variance.taskID.uuidString,
                baselineStart: variance.baselineStart,
                baselineFinish: variance.baselineFinish,
                planStartVariance: variance.planStartVariance,
                planFinishVariance: variance.planFinishVariance,
                actualStartVariance: variance.actualStartVariance,
                actualFinishVariance: variance.actualFinishVariance,
                overdueDays: variance.overdueDays,
                hasBaseline: variance.hasBaseline,
                isForecast: variance.isForecast,
                durationVariance: variance.durationVariance
            )
        }
        let payload = BaselineVariancePayload(
            baselineID: report.baselineID.uuidString,
            baselineName: report.baselineName,
            baselineCreatedAt: report.baselineCreatedAt,
            projectFinishVariance: report.projectFinishVariance,
            lateTaskCount: report.lateTaskCount,
            overdueOpenCount: report.overdueOpenCount,
            tasksWithoutBaseline: report.tasksWithoutBaseline,
            predictedTaskCount: report.predictedTaskCount,
            tasks: rows,
            orphans: report.orphans
        )
        return try encode(payload)
    }

    /// 偏差行的稳定顺序：先按项目大纲顺序，报告里多出的任务按 UUID 排序兜底。
    static func orderedTaskIDs(_ report: BaselineVarianceReport, projectOrder: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in projectOrder where report.tasks[id] != nil {
            if seen.insert(id).inserted { result.append(id) }
        }
        result.append(contentsOf: report.tasks.keys.filter { !seen.contains($0) }.sorted { $0.uuidString < $1.uuidString })
        return result
    }

    private static func encode(_ value: some Encodable) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

/// `baseline list --json` 的载荷（日期按 ISO 8601，`anchor` 缺失不写键）。
private struct BaselineListPayload: Encodable {
    struct Row: Encodable {
        var baselineID: String
        var name: String
        var createdAt: Date
        var anchor: Date?
        var entryCount: Int
    }

    var baselines: [Row]
}

/// `baseline variance --json` 的载荷：字段名与 `BaselineVarianceReport` 同源。
///
/// 为什么单独定义而不是让 `BaselineVarianceReport` 直接 `Encodable`：报告在核心层
/// 是纯值（`[UUID: TaskVariance]` 字典），字典键序不稳定；接口层需要稳定的行序与
/// 明确的「空值不写」语义。
private struct BaselineVariancePayload: Encodable {
    struct TaskRow: Encodable {
        var taskID: String
        var baselineStart: Date?
        var baselineFinish: Date?
        var planStartVariance: Int?
        var planFinishVariance: Int?
        var actualStartVariance: Int?
        var actualFinishVariance: Int?
        var overdueDays: Int?
        var hasBaseline: Bool
        var isForecast: Bool
        var durationVariance: Int?
    }

    var baselineID: String
    var baselineName: String
    var baselineCreatedAt: Date
    var projectFinishVariance: Int?
    var lateTaskCount: Int
    var overdueOpenCount: Int
    var tasksWithoutBaseline: Int
    var predictedTaskCount: Int
    var tasks: [TaskRow]
    var orphans: [BaselineEntry]
}

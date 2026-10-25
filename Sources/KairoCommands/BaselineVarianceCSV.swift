import Foundation
import KairoCore

/// 偏差 CSV 写盘失败（环境问题，不是用法错误）。
public struct CSVWriteFailure: Error, CustomStringConvertible {
    public let message: String
    public init(message: String) { self.message = message }
    public var description: String { message }
}

/// 基线偏差 CSV 导出（v0.15 · 09-baseline-version-plan §4）。
///
/// 放在 KairoCommands 而不是 CLI：CLI 与 macOS 应用共用同一份导出实现，
/// 避免「命令行能导出、界面导不出」或两边列头漂移（v0.15.1 修的就是这个缺口）。
///
/// 口径与 `baseline variance --json` 同源（同一份 `BaselineVarianceReport`）：
/// - 列头逐字固定 11 列，不随语言变化；
/// - 空值留空，**不写 0**（0 = 准时，与「没有数据」语义不同）；
/// - 偏差为整数天，负数保留 `-`；
/// - UTF-8 **带 BOM**（Excel 双击打开中文不乱码）、行尾 LF、字段按 RFC 4180 转义；
/// - 前三行 `# key,value` 携带基线身份（08 §4.5）；
/// - 孤儿（条目在、任务已删）单独一节并复用同一列头，列数仍为 11。
public enum VarianceCSV {
    /// 列头（逐字固定；数组顺序即数据列顺序）。
    public static let header = [
        "taskID", "title", "baselineStart", "baselineFinish",
        "planStartVariance", "planFinishVariance",
        "actualStartVariance", "actualFinishVariance",
        "overdueDays", "hasBaseline", "isForecast",
    ]

    /// 偏差行的稳定顺序：先按项目大纲顺序，报告里多出的任务按 UUID 排序兜底。
    public static func orderedTaskIDs(_ report: BaselineVarianceReport, projectOrder: [UUID]) -> [UUID] {
        var seen: Set<UUID> = []
        var result: [UUID] = []
        for id in projectOrder where report.tasks[id] != nil {
            if seen.insert(id).inserted { result.append(id) }
        }
        result.append(contentsOf: report.tasks.keys.filter { !seen.contains($0) }.sorted { $0.uuidString < $1.uuidString })
        return result
    }

    /// 组装整份文档（含 BOM 与结尾换行）。
    public static func document(
        report: BaselineVarianceReport,
        taskIDs: [UUID],
        titles: [UUID: String],
        includeOrphans: Bool = true
    ) -> String {
        var lines: [String] = [
            comment("baselineID", report.baselineID.uuidString),
            comment("baselineName", report.baselineName),
            comment("baselineCreatedAt", dateText(report.baselineCreatedAt)),
            header.joined(separator: ","),
        ]
        for taskID in taskIDs {
            guard let v = report.tasks[taskID] else { continue }
            lines.append(row(
                taskID: v.taskID.uuidString,
                title: titles[taskID] ?? "",
                baselineStart: v.baselineStart,
                baselineFinish: v.baselineFinish,
                planStartVariance: v.planStartVariance,
                planFinishVariance: v.planFinishVariance,
                actualStartVariance: v.actualStartVariance,
                actualFinishVariance: v.actualFinishVariance,
                overdueDays: v.overdueDays,
                hasBaseline: v.hasBaseline,
                isForecast: v.isForecast
            ))
        }
        if includeOrphans, !report.orphans.isEmpty {
            lines.append("")
            lines.append(header.joined(separator: ","))
            for entry in report.orphans {
                lines.append(row(
                    taskID: entry.taskID.uuidString, title: "",
                    baselineStart: entry.start, baselineFinish: entry.finish,
                    planStartVariance: nil, planFinishVariance: nil,
                    actualStartVariance: nil, actualFinishVariance: nil,
                    overdueDays: nil, hasBaseline: true, isForecast: false
                ))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    private static func row(
        taskID: String, title: String,
        baselineStart: Date?, baselineFinish: Date?,
        planStartVariance: Int?, planFinishVariance: Int?,
        actualStartVariance: Int?, actualFinishVariance: Int?,
        overdueDays: Int?, hasBaseline: Bool, isForecast: Bool
    ) -> String {
        var fields: [String] = [taskID, title]
        fields.append(dayText(baselineStart))
        fields.append(dayText(baselineFinish))
        for value in [planStartVariance, planFinishVariance, actualStartVariance, actualFinishVariance, overdueDays] {
            fields.append(value.map { String($0) } ?? "")
        }
        fields.append(hasBaseline ? "true" : "false")
        fields.append(isForecast ? "true" : "false")
        return fields.map(escape).joined(separator: ",")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func comment(_ key: String, _ value: String) -> String {
        "# " + key + "," + escape(value)
    }

    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    private static func dayText(_ date: Date?) -> String {
        date.map(dateText) ?? ""
    }
}

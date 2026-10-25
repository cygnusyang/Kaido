import Foundation
import KairoCore

/// 基线偏差 CSV 导出（v0.15 · 09-baseline-version-plan §4）。
///
/// 口径与 `baseline variance --json` 同源（同一份 `BaselineVarianceReport`）：
/// - 列头逐字固定 11 列，不随语言变化——这是机器可读出口，与 `--json` 同口径；
/// - 空值留空，**不写 0**（0 = 准时，与「没有数据」语义不同，08 §4.1）；
/// - 偏差是整数天，负数保留 `-`（不补 `+`，电子表格与脚本都按数值解析）；
/// - 文件 UTF-8 **带 BOM**（Excel 双击打开中文不乱码）、行尾 LF、字段按 RFC 4180 转义。
///
/// 三条注释行（`#` 前缀）携带身份三字段：文件会脱离终端单独流转，标识必须落在文件里
/// （08 §4.5「任何偏差输出都必须携带 baselineID + name + createdAt」）。
///
/// 孤儿（基线条目在、任务已删，08 §5）单独一节：空行分隔 + **逐字复用同一列头**。
/// 为什么分节而不是加第 12 列标记：列头是外部契约，多一列会让既有解析脚本错位；
/// 分节后每行仍是 11 列，脚本按列数一致即可解析，孤儿集合与计数也能逐字节复现。
/// CSV 写盘失败：路径不可写属环境问题，按运行时错误处理（退出码 1），不是用法错误（2）。
struct CSVWriteFailure: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

enum VarianceCSV {
    /// 列头（逐字固定；数组顺序即数据列顺序）。
    static let header = [
        "taskID",
        "title",
        "baselineStart",
        "baselineFinish",
        "planStartVariance",
        "planFinishVariance",
        "actualStartVariance",
        "actualFinishVariance",
        "overdueDays",
        "hasBaseline",
        "isForecast",
    ]

    /// 组装整份文档（含 BOM 与结尾换行）。
    ///
    /// - Parameters:
    ///   - report: 偏差报告，唯一数据源（与文本 / JSON 输出同源）。
    ///   - taskIDs: 任务行顺序，由调用方按项目大纲顺序给出（见 `CLIOutput.orderedTaskIDs`）。
    ///   - titles: 任务 ID → 标题；已删任务不在表内，孤儿行标题留空。
    ///   - includeOrphans: 是否输出孤儿节。`--task` 收窄到单个任务时传 `false`。
    static func document(
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
            guard let variance = report.tasks[taskID] else { continue }
            lines.append(row(
                taskID: variance.taskID.uuidString,
                title: titles[taskID] ?? "",
                baselineStart: variance.baselineStart,
                baselineFinish: variance.baselineFinish,
                planStartVariance: variance.planStartVariance,
                planFinishVariance: variance.planFinishVariance,
                actualStartVariance: variance.actualStartVariance,
                actualFinishVariance: variance.actualFinishVariance,
                overdueDays: variance.overdueDays,
                hasBaseline: variance.hasBaseline,
                isForecast: variance.isForecast
            ))
        }
        if includeOrphans, !report.orphans.isEmpty {
            lines.append("")
            lines.append(header.joined(separator: ","))
            for entry in report.orphans {
                lines.append(row(
                    taskID: entry.taskID.uuidString,
                    title: "",
                    baselineStart: entry.start,
                    baselineFinish: entry.finish,
                    planStartVariance: nil,
                    planFinishVariance: nil,
                    actualStartVariance: nil,
                    actualFinishVariance: nil,
                    overdueDays: nil,
                    // 条目在 → 有基线数据；预测项只针对未完成任务，孤儿一律 false。
                    hasBaseline: true,
                    isForecast: false
                ))
            }
        }
        return "\u{FEFF}" + lines.joined(separator: "\n") + "\n"
    }

    /// 一行的字段拼装。缺值一律空字段（不写 0 / 不写 "-"）。
    private static func row(
        taskID: String,
        title: String,
        baselineStart: Date?,
        baselineFinish: Date?,
        planStartVariance: Int?,
        planFinishVariance: Int?,
        actualStartVariance: Int?,
        actualFinishVariance: Int?,
        overdueDays: Int?,
        hasBaseline: Bool,
        isForecast: Bool
    ) -> String {
        // 分步拼装：一次性写出 11 个混着 ?? 的表达式会让类型检查器超时（实测）。
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

    /// RFC 4180 转义：含逗号 / 引号 / 换行的字段加双引号，内部引号翻倍。
    private static func escape(_ field: String) -> String {
        guard field.contains(",") || field.contains("\"") || field.contains("\n") || field.contains("\r") else {
            return field
        }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// 元数据注释行：`# key,value`。值同样转义（基线名允许逗号）。
    private static func comment(_ key: String, _ value: String) -> String {
        "# " + key + "," + escape(value)
    }

    /// 与 `--json` 相同的时间表示（ISO 8601，UTC），便于两边逐字对照。
    private static func dateText(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// 可缺日期：缺值留空字段（不写占位符，脚本按空串判缺）。
    private static func dayText(_ date: Date?) -> String {
        date.map(dateText) ?? ""
    }
}

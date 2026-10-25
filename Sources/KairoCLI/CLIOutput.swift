import Foundation
import KairoCore
import KairoCommands

/// 机器可读输出（US-E5-02 验收 2）：供脚本与插件 hook 直接解析。
/// 字段与 `.kairo` 模型一致（camelCase、ISO 8601 日期），不做二次裁剪。
enum CLIOutput {
    static func taskListJSON(_ tasks: [TaskItem]) throws -> String {
        try encode(tasks)
    }

    /// `baseline list --json`：字段与 MCP `baseline_list` 同名同义。
    static func baselineListJSON(_ baselines: [Baseline]) throws -> String {
        let colors = resolvedColorIndexes(baselines)
        let payload = BaselineListPayload(
            baselines: zip(baselines, colors).map { baseline, colorIndex in
                BaselineListPayload.Row(
                    baselineID: baseline.id.uuidString,
                    name: baseline.name,
                    colorIndex: colorIndex,
                    createdAt: baseline.createdAt,
                    anchor: baseline.anchor,
                    entryCount: baseline.entries.count
                )
            }
        )
        return try encode(payload)
    }

    /// 读路径颜色索引：整组交给 `BaselinePalette.resolve` 归一（nil / 越界 / 重复都派生），
    /// 返回与入参逐位对应的合法索引。
    ///
    /// 为什么不直接读 `baseline.colorIndex`：旧文件缺字段时它是 nil，JSON 里写成 0
    /// 会把「未分配」冒充成「第 1 色」；派生一次与 App 画的颜色才一致。
    static func resolvedColorIndexes(_ baselines: [Baseline]) -> [Int] {
        BaselinePalette.resolve(baselines.map(\.colorIndex))
    }

    /// 指定基线的颜色索引（整组归一后按位取）。
    ///
    /// - Parameter id: 目标基线；不在 `baselines` 里时（调用方传错了快照）按
    ///   「如新建一条」的最小未用索引给出合法值，绝不写死 0。
    static func resolvedColorIndex(of id: UUID, in baselines: [Baseline]) -> Int {
        let colors = resolvedColorIndexes(baselines)
        if let position = baselines.firstIndex(where: { $0.id == id }) {
            return colors[position]
        }
        return BaselinePalette.colorIndex(for: baselines)
    }

    /// `baseline variance --json`：字段与 `BaselineVarianceReport` / `TaskVariance`
    /// 逐字段同名同义（判据 12 对等性门禁）。
    ///
    /// - 空值（`nil`）**不写键**：写成 0 会把「没有数据」冒充成「准时」（§4.1）；
    /// - 偏差是整数天，负数原样带 `-`；
    /// - `taskIDs` 决定行顺序（调用方按大纲顺序给出，见 `orderedTaskIDs(_:projectOrder:)`）。
    /// - Parameter colorIndex: 该基线在整组里的调色板索引（由 `resolvedColorIndex(of:in:)` 派生）。
    static func baselineVarianceJSON(
        _ report: BaselineVarianceReport,
        taskIDs: [UUID],
        colorIndex: Int
    ) throws -> String {
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
            colorIndex: colorIndex,
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

    /// `project summary --json`：项目元信息 + 偏差块（v0.15 · 09 §4）。
    ///
    /// 同源要求：`variance` 内的字段名与 `baseline variance --json` 的项目级字段逐字相同
    /// （baselineID / baselineName / colorIndex / baselineCreatedAt / projectFinishVariance /
    /// lateTaskCount / overdueOpenCount / tasksWithoutBaseline / predictedTaskCount），
    /// 只多一个 `orphanCount`。两边都由同一份 `BaselineVarianceReport` 渲染，数值不会漂移。
    ///
    /// - 无基线时 `variance` 写 `null`：不写零值（0 = 准时 ≠ 没有数据，§4.1）；
    /// - `statusCounts` 四档恒写（含 0），脚本可按固定键取值，不必判缺失。
    static func projectSummaryJSON(
        _ meta: ProjectMetadata,
        tasks: [TaskItem],
        report: BaselineVarianceReport?,
        baselines: [Baseline]
    ) throws -> String {
        let payload = ProjectSummaryPayload(
            project: ProjectSummaryPayload.ProjectFields(
                id: meta.id.uuidString,
                title: meta.title,
                projectStart: meta.projectStart,
                projectEnd: meta.projectEnd,
                taskCount: tasks.count,
                groupCount: tasks.filter { $0.kind == .group }.count,
                milestoneCount: tasks.filter { $0.kind == .milestone }.count,
                statusCounts: ProjectSummaryPayload.StatusCounts(
                    pending: tasks.filter { $0.status == .pending }.count,
                    inProgress: tasks.filter { $0.status == .inProgress }.count,
                    done: tasks.filter { $0.status == .done }.count,
                    blocked: tasks.filter { $0.status == .blocked }.count
                )
            ),
            variance: report.map { report in
                ProjectSummaryPayload.Variance(
                    baselineID: report.baselineID.uuidString,
                    baselineName: report.baselineName,
                    colorIndex: resolvedColorIndex(of: report.baselineID, in: baselines),
                    baselineCreatedAt: report.baselineCreatedAt,
                    projectFinishVariance: report.projectFinishVariance,
                    lateTaskCount: report.lateTaskCount,
                    overdueOpenCount: report.overdueOpenCount,
                    tasksWithoutBaseline: report.tasksWithoutBaseline,
                    predictedTaskCount: report.predictedTaskCount,
                    orphanCount: report.orphans.count
                )
            }
        )
        return try encode(payload)
    }

    /// 偏差行的稳定顺序：先按项目大纲顺序，报告里多出的任务按 UUID 排序兜底。
    static func orderedTaskIDs(_ report: BaselineVarianceReport, projectOrder: [UUID]) -> [UUID] {
        // 与 App 共用同一实现（KairoCommands.VarianceCSV），避免两处顺序规则漂移。
        VarianceCSV.orderedTaskIDs(report, projectOrder: projectOrder)
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
        var colorIndex: Int
        var createdAt: Date
        var anchor: Date?
        var entryCount: Int
    }

    var baselines: [Row]
}

/// `project summary --json` 的载荷：项目元信息 + 偏差块。
///
/// 为什么 `variance` 单独放一个可空子对象而不是平铺：无基线时整块缺席（`null`），
/// 平铺会把「项目字段」和「偏差字段」混在同一层，缺基线时无法整体区分。
private struct ProjectSummaryPayload: Encodable {
    struct StatusCounts: Encodable {
        var pending: Int
        var inProgress: Int
        var done: Int
        var blocked: Int
    }

    struct ProjectFields: Encodable {
        var id: String
        var title: String
        var projectStart: Date?
        var projectEnd: Date?
        var taskCount: Int
        var groupCount: Int
        var milestoneCount: Int
        var statusCounts: StatusCounts
    }

    /// 字段名与 `BaselineVariancePayload` 的项目级字段逐字相同（对等性门禁）。
    struct Variance: Encodable {
        var baselineID: String
        var baselineName: String
        var colorIndex: Int
        var baselineCreatedAt: Date
        var projectFinishVariance: Int?
        var lateTaskCount: Int
        var overdueOpenCount: Int
        var tasksWithoutBaseline: Int
        var predictedTaskCount: Int
        var orphanCount: Int
    }

    var project: ProjectFields
    var variance: Variance?
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
    var colorIndex: Int
    var baselineCreatedAt: Date
    var projectFinishVariance: Int?
    var lateTaskCount: Int
    var overdueOpenCount: Int
    var tasksWithoutBaseline: Int
    var predictedTaskCount: Int
    var tasks: [TaskRow]
    var orphans: [BaselineEntry]
}

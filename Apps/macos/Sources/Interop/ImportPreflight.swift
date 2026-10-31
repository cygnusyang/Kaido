import Foundation
import ZenoInterop

/// 导入预检报告（13-interop-mapping §5）：**先看再导**的唯一数据来源。
///
/// 四块内容逐块都能追到同一份 `FidelityLedger`，不另算一份；四块是对登记表的**分区**
/// （每条登记恰好落进一块，见 `isLedgerPartitioned`）：
/// 1. `conversionLosses`：已换算 / 语义有变的条目（硬约束转软、自定义域丢弃、工期换口径）——
///    最容易被用户忽略、后果最持久的一类，必须摆在主清单里，不能只藏在下钻明细；
/// 2. `calendar` / `calendarLosses`：日历换算方式与偏差预估（工作日 ↔ 日历天，最严重的语义鸿沟）；
/// 3. `dependencyLosses`：依赖明细（lag 取整、前驱缺失的悬空边）；
/// 4. `losses`：其余丢失或按默认值补全的字段（计数 + 原值样例）。
///
/// 纯值类型、不碰会话：视图只渲染它，取消时整个丢掉——「取消后项目零变化」就靠这条边界。
struct ImportPreflight: Equatable {
    /// 一条有损登记。三块清单共用同一形状，渲染代码因此只有一份。
    struct LossRow: Identifiable, Equatable {
        let id: String
        let kind: FidelityLedger.Kind
        let field: String
        let count: Int
        let detail: String
        let samples: [String]
    }

    /// 一项规模统计（导入后项目里会有多少这类对象）。
    struct ScaleRow: Identifiable, Equatable {
        let id: String
        let title: String
        let value: Int
    }

    /// 日历换算说明。
    struct CalendarConversion: Equatable {
        /// 来源工作周（如「Monday–Friday」）。
        let workingWeek: String
        /// 来源的一个工作日折算几小时。
        let hoursPerDay: Double
        /// 该日历覆盖的任务数（含继承项目默认日历的任务）。
        let affectedTasks: Int
        /// 例外日数（节假日 + 调休），原样带入 Zeno。
        let exceptionCount: Int
        /// 关键路径预计提前的日历天数；工作周已是 7 天或无可估的依赖链时为 nil。
        let estimatedAdvanceDays: Int?
    }

    let formatID: String
    let formatName: String
    let formatVersion: String
    let fileName: String
    /// 适配器给的规模摘要（一句话，原样展示，不在这里重新拼）。
    let summary: String
    let scale: [ScaleRow]
    /// 已换算 / 语义有变的条目（`converted` / `degraded`）。
    let conversionLosses: [LossRow]
    let losses: [LossRow]
    let calendar: CalendarConversion?
    let calendarLosses: [LossRow]
    let dependencyLosses: [LossRow]
    /// 将导入的任务总数（含汇总与里程碑）：确认后的落地判据就是它。
    let taskCount: Int
    /// 分块前的登记条数：四块计数之和必须等于它（防漏报的不变量基准）。
    let ledgerEntryCount: Int

    /// 有无任何有损项（四块任一非空）。
    var hasLosses: Bool {
        !conversionLosses.isEmpty || !losses.isEmpty
            || !calendarLosses.isEmpty || !dependencyLosses.isEmpty
    }

    /// 不变量：四块清单是 ledger 的**分区**——不重复、不遗漏。
    ///
    /// 归类写成对 `FidelityLedger.Kind` 的穷尽 `switch`，新增种类时编译器会先拦住；
    /// 这条断言再兜一层，防止以后有人往里加「只进下钻明细」的分支把主清单掏空。
    var isLedgerPartitioned: Bool {
        let ids = (conversionLosses + dependencyLosses + calendarLosses + losses).map(\.id)
        return ids.count == ledgerEntryCount && Set(ids).count == ids.count
    }

    // MARK: - 构造

    init(
        document: InteropDocument,
        report: PreflightReport,
        ledger: FidelityLedger,
        fileName: String
    ) {
        formatID = report.formatID
        formatName = InteropFormats.displayName(for: report.formatID)
        formatVersion = report.formatVersion
        self.fileName = fileName
        summary = report.summary

        let groupCount = document.tasks.filter { $0.kind == .group }.count
        let milestoneCount = document.tasks.filter { $0.kind == .milestone }.count
        let dependencyCount = document.tasks.reduce(0) { $0 + $1.dependencies.count }
        taskCount = document.tasks.count
        scale = [
            ScaleRow(id: "tasks", title: I18n.t("interop.scale.tasks", "Tasks"), value: document.tasks.count),
            ScaleRow(id: "groups", title: I18n.t("interop.scale.groups", "Summary rows"), value: groupCount),
            ScaleRow(id: "milestones", title: I18n.t("interop.scale.milestones", "Milestones"), value: milestoneCount),
            ScaleRow(id: "dependencies", title: I18n.t("interop.scale.dependencies", "Dependencies"), value: dependencyCount),
            ScaleRow(id: "resources", title: I18n.t("interop.scale.resources", "Resources"), value: document.resources.count),
            ScaleRow(id: "assignments", title: I18n.t("interop.scale.assignments", "Assignments"), value: document.assignments.count),
            ScaleRow(id: "calendars", title: I18n.t("interop.scale.calendars", "Calendars"), value: document.calendars.count),
            ScaleRow(id: "baselines", title: I18n.t("interop.scale.baselines", "Baselines"), value: document.baselines.count),
        ]

        // 四块清单都从同一份登记切分，每条只进一块（`bucket(for:)` 决定归属）。
        var conversionRows: [LossRow] = []
        var calendarRows: [LossRow] = []
        var dependencyRows: [LossRow] = []
        var otherRows: [LossRow] = []
        for entry in ledger.entries {
            let row = LossRow(
                id: entry.id,
                kind: entry.kind,
                field: entry.field,
                count: entry.count,
                detail: entry.detail,
                samples: entry.samples
            )
            switch Self.bucket(for: entry) {
            case .conversion: conversionRows.append(row)
            case .calendar: calendarRows.append(row)
            case .dependency: dependencyRows.append(row)
            case .other: otherRows.append(row)
            }
        }
        conversionLosses = conversionRows
        losses = otherRows
        calendarLosses = calendarRows
        dependencyLosses = dependencyRows
        ledgerEntryCount = ledger.entries.count
        calendar = Self.makeCalendarConversion(document)
        assert(isLedgerPartitioned, "preflight ledger not fully partitioned: \(ledgerEntryCount) entries outside the four buckets")
    }

    // MARK: - 分块

    /// 条目归属的那一块清单。
    private enum Bucket {
        /// 依赖明细：lag 取整、前驱缺失的悬空边（用户核对依赖时要逐项对照）。
        case dependency
        /// 已换算 / 语义有变：主清单里必须自成一块，否则最持久的语义差会被下钻明细掩盖。
        case conversion
        /// 日历项：换算方式已在「日历换算」块里单独说明，这里只放残余条目。
        case calendar
        /// 其余丢失 / 补全项。
        case other
    }

    /// 归类规则（顺序即优先级，每条登记只命中一个分支）：
    /// 1. `dependency*` 归依赖明细——**即使**它是 `converted`（lag 取整）或 `dropped`（悬空边）；
    /// 2. `converted` / `degraded` 归「已换算」——硬约束降级（`constraint`）与工期口径换算
    ///    必须出现在主清单里，不能被字段前缀吞掉；
    /// 3. `calendar*` 归日历块；
    /// 4. 剩下的归「其余有损项」。
    ///
    /// 对 `Kind` 的 `switch` 是穷尽的：新增种类会编译失败，逼着先想清楚归哪一块。
    private static func bucket(for entry: FidelityLedger.Entry) -> Bucket {
        if entry.field.hasPrefix("dependency") { return .dependency }
        switch entry.kind {
        case .converted, .degraded: return .conversion
        case .dropped, .derived:
            return entry.field.hasPrefix("calendar") ? .calendar : .other
        }
    }

    // MARK: - 日历换算

    /// 默认日历与 Zeno 口径不同时给出换算说明；已经是「全周 7 天 + 无例外日」则不产生换算项。
    private static func makeCalendarConversion(_ document: InteropDocument) -> CalendarConversion? {
        guard !document.calendars.isEmpty else { return nil }
        let defaultID = document.metadata.defaultCalendarID
        guard let calendar = document.calendars.first(where: { $0.id == defaultID })
            ?? document.calendars.first else { return nil }
        let weekdays = calendar.workingWeekdays.filter { (1...7).contains($0) }
        guard !weekdays.isEmpty else { return nil }

        let affected = document.tasks.filter { $0.calendarID == nil || $0.calendarID == calendar.id }.count
        guard affected > 0 else { return nil }

        let isZenoDefault = weekdays.count == 7 && calendar.exceptions.isEmpty
        guard !isZenoDefault else { return nil }

        let hoursPerDay = calendar.hoursPerDay > 0 ? calendar.hoursPerDay : 8
        // 工作日 → 日历天：来源每 5 个工作日占 7 个自然日，Zeno 只占 5 个，故整条链提前
        // `(7 / w - 1)` × 链长。7 天工作周没有偏差，留 nil 而不是写 0。
        let factor = weekdays.count < 7 ? 7.0 / Double(weekdays.count) - 1 : 0
        let advance: Int? = factor > 0
            ? Int((criticalPathWorkingDays(document, calendar: calendar, hoursPerDay: hoursPerDay) * factor).rounded())
            : nil

        return CalendarConversion(
            workingWeek: workingWeekText(weekdays),
            hoursPerDay: hoursPerDay,
            affectedTasks: affected,
            exceptionCount: calendar.exceptions.count,
            estimatedAdvanceDays: advance
        )
    }

    /// 任务在该日历下的工期（工作日数）：群组不排期、里程碑零工期。
    private static func workingDays(_ task: InteropTask, hoursPerDay: Double) -> Double {
        guard task.kind == .task else { return 0 }
        guard let seconds = task.durationSeconds else { return 0 }
        return seconds / (max(hoursPerDay, 0.5) * 3600)
    }

    /// 最长依赖链上的工作日总量（用于偏差预估，不是真正的关键路径计算）。
    ///
    /// 取「链长」而不是逐任务累加：偏差随链长线性放大，只有链尾才是用户能看到的日期差。
    /// 环上取下界 0（不在 DFS 里死循环）：真实排期会把环上的任务标为不可排期。
    private static func criticalPathWorkingDays(
        _ document: InteropDocument,
        calendar: InteropCalendar,
        hoursPerDay: Double
    ) -> Double {
        var durations: [String: Double] = [:]
        for task in document.tasks where task.calendarID == nil || task.calendarID == calendar.id {
            durations[task.id] = workingDays(task, hoursPerDay: hoursPerDay)
        }
        guard !durations.isEmpty else { return 0 }
        let predecessors = Dictionary(
            document.tasks.map { ($0.id, $0.dependencies.map(\.predecessorID)) },
            uniquingKeysWith: { first, _ in first }
        )
        var memo: [String: Double] = [:]
        var visiting: Set<String> = []

        func longestChain(to id: String) -> Double {
            if let cached = memo[id] { return cached }
            guard !visiting.contains(id) else { return 0 }
            visiting.insert(id)
            let upstream = (predecessors[id] ?? []).reduce(0.0) { best, predecessor in
                max(best, longestChain(to: predecessor))
            }
            visiting.remove(id)
            let total = (durations[id] ?? 0) + upstream
            memo[id] = total
            return total
        }

        return durations.keys.reduce(0.0) { best, id in max(best, longestChain(to: id)) }
    }

    /// 「Monday–Friday」：连续区间压成一段，不连续的相邻并列。
    private static func workingWeekText(_ weekdays: Set<Int>) -> String {
        let sorted = weekdays.sorted()
        guard let first = sorted.first else { return "" }
        var parts: [String] = []
        var start = first
        var previous = first
        for day in sorted.dropFirst() {
            if day == previous + 1 {
                previous = day
                continue
            }
            parts.append(weekdayRange(start, previous))
            start = day
            previous = day
        }
        parts.append(weekdayRange(start, previous))
        return parts.joined(separator: ", ")
    }

    private static func weekdayRange(_ start: Int, _ end: Int) -> String {
        let startName = Display.weekdayFullName(start)
        guard start != end else { return startName }
        return I18n.t("interop.week.range", "%1$@–%2$@", startName, Display.weekdayFullName(end))
    }

    // MARK: - 复制为文本

    /// 报告的可复制文本（13 §5 验收 4）：贴进邮件与对方核对用。
    ///
    /// 与界面同源：都由本模型渲染，不另建一套「导出成文本时才用」的文案。
    var copyText: String {
        var lines: [String] = []
        lines.append("\(formatName) · \(formatVersion) · \(fileName)")
        lines.append(summary)
        lines.append("")
        lines.append(I18n.t("interop.copy.scale", "Will import:"))
        for row in scale {
            lines.append("  \(row.title): \(row.value)")
        }
        if let calendar {
            lines.append("")
            lines.append(I18n.t("interop.copy.calendar", "Calendar conversion:"))
            lines.append("  " + calendarLine(calendar))
        }
        for section in [
            (I18n.t("interop.copy.converted", "Converted (semantics changed):"), conversionLosses),
            (I18n.t("interop.copy.calendar_losses", "Calendar items:"), calendarLosses),
            (I18n.t("interop.copy.dependency", "Dependency details:"), dependencyLosses),
            (I18n.t("interop.copy.losses", "Lost or downgraded fields:"), losses),
        ] where !section.1.isEmpty {
            lines.append("")
            lines.append(section.0)
            for row in section.1 { lines.append("  " + line(row)) }
        }
        return lines.joined(separator: "\n")
    }

    /// 一行登记的文本：`[kind] field × N — detail（样例：a、b）`。
    private func line(_ row: LossRow) -> String {
        let samples = row.samples.isEmpty
            ? ""
            : I18n.t("interop.copy.samples", " (e.g. %1$@)", row.samples.joined(separator: ", "))
        return "[\(InteropFormats.kindLabel(row.kind))] \(row.field) × \(row.count) — \(row.detail)\(samples)"
    }

    /// 日历换算的一句话说明（界面与复制文本共用）。
    func calendarLine(_ calendar: CalendarConversion) -> String {
        let hours = calendar.hoursPerDay.formatted(
            .number.precision(.fractionLength(0...1)).locale(I18n.locale)
        )
        let base = I18n.t(
            "interop.calendar.summary",
            "%1$@ (%2$@ h/day, %3$ld exceptions) drives %4$ld tasks; Zeno advances by calendar days rather than working days.",
            calendar.workingWeek,
            hours,
            calendar.exceptionCount,
            calendar.affectedTasks
        )
        guard let advance = calendar.estimatedAdvanceDays else { return base }
        return base + " " + I18n.t(
            "interop.calendar.advance",
            "The critical path is expected to finish about %1$ld days earlier.",
            advance
        )
    }
}

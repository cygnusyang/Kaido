import Foundation
import ZenoCore
import ZenoCommands

/// CLI 人类可读文案（F-0707 · 设计 §3「CLI / MCP 各自渲染」）。
///
/// 为什么是一张代码内的表而不是 String Catalog：\`dist/ZenoCLI\` 是裸可执行文件，
/// 没有 \`Info.plist\` 与 \`.lproj\` 宿主，Catalog 取不到译文（设计 §7.4）。
///
/// **阶段一约束**：\`zh-Hans\` 列逐字等于 v0.8.5 的输出（含全角括号、全角冒号与
/// 「」引号），既有中文脚本与断言继续命中；\`en\` 列为新增，一律半角标点。
///
/// 边界：\`ZenoCommands\` 的 \`SessionError.message\` 阶段一仍是中文（设计 §A.2），
/// CLI 直接透传、不在本表重写——本表只负责 CLI 自己拼的文案。
struct CLIStrings: Sendable {
    let language: CLILanguage

    init(language: CLILanguage) { self.language = language }

    /// 成对书写中英文，避免两处 switch 各自漂移。
    private func t(_ zh: @autoclosure () -> String, _ en: @autoclosure () -> String) -> String {
        language == .zhHans ? zh() : en()
    }

    // MARK: - 通用前缀

    /// 用法错误的行首（退出码 2）。
    func usagePrefix(_ message: String) -> String {
        t("用法错误：" + message, "usage error: " + message)
    }

    /// 运行时错误的行首（退出码 1）。
    func errorPrefix(_ message: String) -> String {
        t("错误：" + message, "error: " + message)
    }

    // MARK: - 操作数名（用法错误的 <占位> 与其后紧跟的名词）

    var operandTitle: String { t("标题", "title") }
    var operandFilePath: String { t("文件路径", "file path") }
    var operandTaskID: String { t("任务 ID", "task ID") }
    var operandJSONFile: String { t("JSON 文件", "JSON file") }
    var operandResourceName: String { t("资源名称", "resource name") }
    var operandBaselineID: String { t("基线 ID", "baseline ID") }
    /// baseline color 的第二个操作数（0…7 调色板索引）。
    var operandColorIndex: String { t("颜色索引", "color index") }
    var operandProjectStart: String { t("项目开始", "project start") }
    var operandProjectEnd: String { t("项目结束", "project end") }
    var operandLanguageValue: String { t("--lang 的值", "--lang value") }

    // MARK: - 参数与选项校验

    func missingOperand(_ name: String) -> String {
        t("缺少参数：<\(name)>", "missing argument: <\(name)>")
    }

    func unknownOption(_ item: String, allowed: [String]) -> String {
        let list = allowed.joined(separator: " ")
        return t("未知选项：\(item)（可用：\(list)）", "unknown option: \(item) (allowed: \(list))")
    }

    func unknownCommand(group: String, command: String) -> String {
        t("未知命令：\(group) \(command)", "unknown command: \(group) \(command)")
    }

    /// 空子命令 / 空命令组的占位（未知命令提示用）。
    var emptyLabel: String { t("(空)", "(empty)") }

    func missingLanguageValue() -> String {
        let list = CLILanguage.allowedValues.joined(separator: "/")
        return t(
            "缺少参数：<--lang 的值>（可选 \(list)）",
            "missing argument: <--lang value> (allowed: \(list))"
        )
    }

    func invalidLanguage(_ raw: String) -> String {
        let list = CLILanguage.allowedValues.joined(separator: "/")
        return t("无效语言：\(raw)（可选 \(list)）", "invalid language: \(raw) (allowed: \(list))")
    }

    func invalidDateOption(field: String, raw: String) -> String {
        t(
            "无效的\(field)日期：\(raw)（ISO8601 或 YYYY-MM-DD）",
            "invalid \(field) date: \(raw) (ISO8601 or YYYY-MM-DD)"
        )
    }

    // MARK: - 枚举参数（CLIEnums）

    func invalidKind(_ raw: String) -> String {
        t("无效类型：\(raw)（可选 task/group/milestone）", "invalid kind: \(raw) (expected task/group/milestone)")
    }

    func invalidPriority(_ raw: String) -> String {
        t(
            "无效优先级：\(raw)（可选 low/normal/high/critical）",
            "invalid priority: \(raw) (expected low/normal/high/critical)"
        )
    }

    /// 无效状态的提示列出全部取值（v0.16 起含 cancelled）。
    ///
    /// CLI 是人类出口，提示缺一个合法取值就等于把人引到错路上；MCP 侧同一提示串被
    /// v0.8.5 基线逐字冻结，只在新 schema 的 enum 里加值，故两边文案不追求逐字相同。
    func invalidStatus(_ raw: String) -> String {
        t(
            "无效状态：\(raw)（可选 pending/in_progress/done/blocked/cancelled）",
            "invalid status: \(raw) (expected pending/in_progress/done/blocked/cancelled)"
        )
    }

    /// 转「已取消」却没给理由（v0.16）：终态必须可回溯，缺原因在用法层就拦下。
    func cancelReasonRequired() -> String {
        t(
            "转为已取消时必须用 --reason 给出取消原因（不能为空）",
            "cancelling a task requires a non-empty --reason"
        )
    }

    /// `task update` 不能置为已取消：那条路径不记录原因，指向唯一正确的入口。
    func cancelViaStatusUpdate() -> String {
        t(
            "取消任务请用 status update <任务 ID> --status cancelled --reason <原因>",
            "use status update <task ID> --status cancelled --reason <reason> to cancel a task"
        )
    }

    func invalidSchedulingPolicy(_ raw: String) -> String {
        t("无效调度策略：\(raw)（可选 asap/alap）", "invalid scheduling policy: \(raw) (expected asap/alap)")
    }

    func invalidConstraintSpec(_ raw: String) -> String {
        t(
            "无效时限：\(raw)（格式 type:日期，如 startNoLaterThan:2026-11-05 或 ISO8601 完整形式）",
            "invalid constraint: \(raw) (format type:date, e.g. startNoLaterThan:2026-11-05 or full ISO8601)"
        )
    }

    func invalidConstraintType(_ raw: String) -> String {
        let kinds = "startNoEarlierThan/startNoLaterThan/endNoEarlierThan/endNoLaterThan"
        return t(
            "无效时限类型：\(raw)（可选 \(kinds)）",
            "invalid constraint type: \(raw) (expected \(kinds))"
        )
    }

    func invalidResourceKind(_ raw: String) -> String {
        t(
            "无效资源类型：\(raw)（可选 person/equipment/material/group）",
            "invalid resource kind: \(raw) (expected person/equipment/material/group)"
        )
    }

    func invalidAssignment(_ spec: String) -> String {
        t(
            "无效分配：\(spec)（格式 资源ID或前缀[:单位]）",
            "invalid assignment: \(spec) (format resourceID-or-prefix[:units])"
        )
    }

    func invalidAssignmentUnits(_ raw: String) -> String {
        t("无效分配单位：\(raw)（应为正数）", "invalid assignment units: \(raw) (must be positive)")
    }

    func invalidDependencySpec(_ spec: String) -> String {
        t(
            "无效相关性规格：\(spec)（格式 predecessorID[:type[:lag]]）",
            "invalid dependency: \(spec) (format predecessorID[:type[:lag]])"
        )
    }

    func invalidDependencyType(_ raw: String) -> String {
        t("无效相关性类型：\(raw)（可选 fs/ff/ss/sf）", "invalid dependency type: \(raw) (expected fs/ff/ss/sf)")
    }

    // MARK: - 标识解析（任务 / 资源前缀）

    func taskIDPrefixTooShort(_ raw: String) -> String {
        t("任务 ID 前缀至少 4 位：\(raw)", "task ID prefix must be at least 4 characters: \(raw)")
    }

    func taskNotFound(_ raw: String) -> String {
        t("找不到任务：\(raw)", "task not found: \(raw)")
    }

    func taskIDPrefixAmbiguous(_ raw: String, matches: Int) -> String {
        t(
            "任务 ID 前缀不唯一（\(matches) 个匹配）：\(raw)",
            "task ID prefix is ambiguous (\(matches) matches): \(raw)"
        )
    }

    func resourceIDPrefixTooShort(_ raw: String) -> String {
        t("资源 ID 前缀至少 4 位：\(raw)", "resource ID prefix must be at least 4 characters: \(raw)")
    }

    func resourceNotFound(_ raw: String) -> String {
        t("找不到资源：\(raw)", "resource not found: \(raw)")
    }

    func resourceIDPrefixAmbiguous(_ raw: String, matches: Int) -> String {
        t(
            "资源 ID 前缀不唯一（\(matches) 个匹配）：\(raw)",
            "resource ID prefix is ambiguous (\(matches) matches): \(raw)"
        )
    }

    func baselineIDPrefixTooShort(_ raw: String) -> String {
        t("基线 ID 前缀至少 4 位：\(raw)", "baseline ID prefix must be at least 4 characters: \(raw)")
    }

    func baselineNotFound(_ raw: String) -> String {
        t("找不到基线：\(raw)", "baseline not found: \(raw)")
    }

    func baselineIDPrefixAmbiguous(_ raw: String, matches: Int) -> String {
        t(
            "基线 ID 前缀不唯一（\(matches) 个匹配）：\(raw)",
            "baseline ID prefix is ambiguous (\(matches) matches): \(raw)"
        )
    }

    // MARK: - 输入文件解析失败（CLI 自己读的用户文件）

    func unparseableWBS(_ path: String) -> String {
        t("无法解析 WBS JSON：\(path)", "cannot parse WBS JSON: \(path)")
    }

    func unparseableBatch(_ path: String) -> String {
        t("无法解析批量回写 JSON：\(path)", "cannot parse batch update JSON: \(path)")
    }

    func batchFailures(_ count: Int) -> String {
        t("批量回写存在 \(count) 条失败", "batch update failed for \(count) entr\(count == 1 ? "y" : "ies")")
    }

    // MARK: - project

    func projectCreated(id: String, title: String) -> String {
        t("已创建项目：\(id)「\(title)」", "project created: \(id) \"\(title)\"")
    }

    func saved(path: String) -> String {
        t("已保存：\(path)", "saved: \(path)")
    }

    func updatedAt(_ timestamp: String) -> String {
        t("更新于：\(timestamp)", "updated at: \(timestamp)")
    }

    func projectLine(_ title: String) -> String {
        t("项目：\(title)", "project: \(title)")
    }

    func projectIDLine(_ id: String) -> String {
        t("项目ID：\(id)", "project id: \(id)")
    }

    func taskCountLine(_ count: Int) -> String {
        t("任务数：\(count)", "tasks: \(count)")
    }

    /// 保存/新建的格式版本行（FR-ZENO-FMT-6）。
    func formatVersionLine(written: Int, upgradedFrom: Int?) -> String {
        if let upgradedFrom, upgradedFrom < written {
            return t(
                "格式版本：v\(written)（已从 v\(upgradedFrom) 升级）",
                "format version: v\(written) (upgraded from v\(upgradedFrom))"
            )
        }
        return t("格式版本：v\(written)", "format version: v\(written)")
    }

    /// 打开时的来源版本行。
    func sourceVersionLine(source: Int, current: Int) -> String {
        let line = t(
            "源格式版本：v\(source)（当前 v\(current)）",
            "source format version: v\(source) (current v\(current))"
        )
        return source < current ? line + t("，保存后升级", ", will upgrade on save") : line
    }

    // MARK: - task

    func taskCreated(id: String, title: String) -> String {
        t("已创建任务：\(id) \(title)", "task created: \(id) \(title)")
    }

    func taskUpdated(id: String, title: String) -> String {
        t("已更新任务：\(id) \(title)", "task updated: \(id) \(title)")
    }

    func taskDeleted(id: String) -> String {
        t("已删除任务：\(id)", "task deleted: \(id)")
    }

    func taskDeletedWithSubtasks(id: String, subtasks: Int) -> String {
        t(
            "已删除任务及其 \(subtasks) 个子任务：\(id)",
            "task deleted with \(subtasks) sub\(subtasks == 1 ? "task" : "tasks"): \(id)"
        )
    }

    // MARK: - wbs

    func importedTasks(_ total: Int) -> String {
        t("已导入 \(total) 个任务", "imported \(total) task\(total == 1 ? "" : "s")")
    }

    // MARK: - schedule

    func scheduleComputed(_ count: Int) -> String {
        t("已计算排期：\(count) 个任务", "schedule computed: \(count) task\(count == 1 ? "" : "s")")
    }

    func scheduleLine(
        id: String,
        title: String,
        start: String,
        finish: String,
        duration: String,
        policy: String
    ) -> String {
        // 英文单复数：duration 是格式化后的整/小数文本，仅 "1" 取单数。
        let unit = duration == "1" ? "day" : "days"
        return t(
            "  \(id) \(title)  \(start) → \(finish)（\(duration) 天，\(policy)）",
            "  \(id) \(title)  \(start) → \(finish) (\(duration) \(unit), \(policy))"
        )
    }

    func criticalPathHeader(count: Int, slackLimit: String) -> String {
        t(
            "重要路径：\(count) 个任务（宽延限制 \(slackLimit) 天）",
            "critical path: \(count) task\(count == 1 ? "" : "s") (slack limit \(slackLimit) days)"
        )
    }

    func criticalPathLine(
        id: String,
        title: String,
        mark: String,
        totalSlack: String,
        freeSlack: String
    ) -> String {
        t(
            "  \(id) \(title)\(mark)  总宽延 \(totalSlack) 天 / 自由宽延 \(freeSlack) 天",
            "  \(id) \(title)\(mark)  total slack \(totalSlack) days / free slack \(freeSlack) days"
        )
    }

    // MARK: - violations

    var noViolations: String { t("无违例", "no violations") }

    func violationCount(_ count: Int) -> String {
        t("违例：\(count) 条", "violations: \(count)")
    }

    func violationLine(severity: String, code: String, text: String) -> String {
        t("  [\(severity)] \(code)：\(text)", "  [\(severity)] \(code): \(text)")
    }

    /// 严重级别标签（违例行首）。
    func severityLabel(_ severity: Violation.Severity) -> String {
        switch severity {
        case .error: return t("错误", "error")
        case .warning: return t("警告", "warning")
        }
    }

    /// 违例文案：由 \`ViolationReason\` 的语义与参数渲染，核心层不再携带自然语言。
    ///
    /// \`zh-Hans\` 列逐字等于 v0.8.5 的 \`ViolationEngine\` 消息模板；
    /// \`startAfterProjectWindow\`（F-0715 / D-022）是本版新增归因，v0.8.5 无对应文案，
    /// 中文按「点明用户输入致因」的要求新写。
    func violationText(_ violation: Violation) -> String {
        // 唯实现：ZenoCommands.ViolationText（CLI 与 MCP 共用，避免文案漂移）。
        ViolationText.text(violation, language: language == .zhHans ? .zhHans : .en)
    }

    /// 任务标题缺失时的回退（任务已被删除等）。
    var unknownTask: String { t("未知任务", "unknown task") }

    private func taskTitle(_ title: String?) -> String {
        title ?? unknownTask
    }

    /// 时限方向的中文名（v0.8.5 文案用「开始不早于」这类整词）。
    private func constraintName(_ kind: ConstraintKind) -> String {
        switch kind {
        case .startNoEarlierThan: return t("开始不早于", "start no earlier than")
        case .startNoLaterThan: return t("开始不晚于", "start no later than")
        case .endNoEarlierThan: return t("结束不早于", "end no earlier than")
        case .endNoLaterThan: return t("结束不晚于", "end no later than")
        }
    }

    /// 「最晚开始 / 最晚结束」里的名词。
    private func side(_ kind: ConstraintKind) -> String {
        switch kind {
        case .startNoEarlierThan, .startNoLaterThan: return t("开始", "start")
        case .endNoEarlierThan, .endNoLaterThan: return t("结束", "finish")
        }
    }

    /// 日历日文本（\`yyyy-MM-dd\`）：契约格式，不随语言变化（\`en_US_POSIX\`）。
    static func calendarDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.timeZone = .current
        return formatter.string(from: date)
    }

    // MARK: - status（单条 / 批量）

    func statusWritten(id: String, title: String, status: String, progress: Int) -> String {
        t(
            "已回写：\(id) \(title)（\(status)，进度 \(progress)%）",
            "status written: \(id) \(title) (\(status), progress \(progress)%)"
        )
    }

    /// 取消原因行（v0.16）：回执与详情共用同一措辞，避免两处口径漂移。
    /// 任务不是「已取消」时不输出该行——原因只属于终态。
    func cancelReasonLine(_ reason: String) -> String {
        t("取消原因：\(reason)", "cancel reason: \(reason)")
    }

    /// 实际开始（07-actual-dates §8）：与「实际结束」成对出现，措辞统一为「实际」。
    func actualStart(_ timestamp: String) -> String {
        t("实际开始：\(timestamp)", "actual start: \(timestamp)")
    }

    /// 实际结束（07-actual-dates §2）：复用原 completedAt 输出行，仅改标签口径。
    func actualFinish(_ timestamp: String) -> String {
        t("实际结束：\(timestamp)", "actual finish: \(timestamp)")
    }

    func groupProgress(_ percent: Int) -> String {
        t("完成度聚合：\(percent)%", "group progress: \(percent)%")
    }

    func batchEntryFailed(label: String, reason: String) -> String {
        t("失败：\(label) \(reason)", "failed: \(label) \(reason)")
    }

    var unknownError: String { t("未知错误", "unknown error") }

    func batchSummary(succeeded: Int, failed: Int) -> String {
        t(
            "批量结果：成功 \(succeeded) 条，失败 \(failed) 条",
            "batch result: \(succeeded) succeeded, \(failed) failed"
        )
    }

    // MARK: - resource

    func resourceAdded(id: String, name: String, kind: String, units: String, efficiency: String) -> String {
        t(
            "已添加资源：\(id) \(name)（\(kind)，单位 \(units)，效率 \(efficiency)）",
            "resource added: \(id) \(name) (\(kind), units \(units), efficiency \(efficiency))"
        )
    }

    func resourceLine(id: String, name: String, kind: String, units: String, efficiency: String) -> String {
        t(
            "\(id) \(name)（\(kind)，单位 \(units)，效率 \(efficiency)）",
            "\(id) \(name) (\(kind), units \(units), efficiency \(efficiency))"
        )
    }

    // MARK: - task list / detail

    func taskListLine(
        id: String,
        title: String,
        kind: String?,
        status: String,
        priority: String?,
        effort: String?,
        duration: String?,
        tags: [String],
        cancelReason: String? = nil
    ) -> String {
        var parts: [String] = [id, title]
        if let kind { parts.append("[\(kind)]") }
        var extras: [String] = [status]
        // 原因紧跟状态：读到「已取消」就能立刻看到为什么（v0.16）。
        if let cancelReason { extras.append(t("原因：\(cancelReason)", "reason: \(cancelReason)")) }
        if let priority { extras.append(priority) }
        if let effort { extras.append(t("投入 \(effort) 小时", "effort \(effort) h")) }
        if let duration {
            extras.append(t("持续 \(duration) 天", "duration \(duration) \(duration == "1" ? "day" : "days")"))
        }
        if !tags.isEmpty { extras.append(tags.map { "#\($0)" }.joined(separator: " ")) }
        parts.append(extras.joined(separator: " · "))
        return parts.joined(separator: " ")
    }

    var detailTask: String { t("任务：", "task: ") }
    var detailID: String { t("ID：", "id: ") }
    var detailKind: String { t("类型：", "kind: ") }
    var detailStatus: String { t("状态：", "status: ") }
    var detailAssignee: String { t("负责人：", "assignee: ") }
    var detailPriority: String { t("优先级：", "priority: ") }
    var detailEffort: String { t("投入：", "effort: ") }
    var detailDuration: String { t("持续：", "duration: ") }
    var detailTags: String { t("标签：", "tags: ") }
    var detailProgress: String { t("进度：", "progress: ") }
    var detailDependencies: String { t("相关性：", "dependencies: ") }
    var detailAssignments: String { t("分配：", "assignments: ") }
    var detailNotes: String { t("备注：", "notes: ") }

    func hoursUnit(_ effort: String) -> String { t("\(effort) 小时", "\(effort) h") }
    func daysUnit(_ days: String) -> String { t("\(days) 天", "\(days) \(days == "1" ? "day" : "days")") }
    func lagSuffix(_ lag: String) -> String { t(" 前导 \(lag) 天", " lag \(lag) days") }

    func dependencyRow(title: String, type: String, lag: String?) -> String {
        var text = "  - \(title)（\(type)）"
        if language == .en { text = "  - \(title) (\(type))" }
        if let lag { text += lagSuffix(lag) }
        return text
    }

    func assignmentRow(name: String, units: String) -> String {
        t("  - \(name)（\(units) 单位）", "  - \(name) (\(units) units)")
    }

    var unknownResource: String { t("未知资源", "unknown resource") }

    // MARK: - baseline（v0.13 / 08-baselines §8）

    /// 缺值占位：空缺一律「—」，绝不写 0（0 = 准时，与「无数据」不同，§4.1）。
    var varianceEmpty: String { "—" }

    /// 偏差天数（带符号）：nil → 「—」；正数显式带 `+`，负数自带 `-`。
    ///
    /// 单位随语言（中文「天」/ 英文 `d`），符号与数字不随语言变化，便于脚本比对。
    func varianceDays(_ value: Int?) -> String {
        guard let value else { return varianceEmpty }
        let signed = value > 0 ? "+\(value)" : "\(value)"
        return t("\(signed) 天", "\(signed) d")
    }

    var noBaselines: String { t("尚未创建基线", "no baselines") }

    func baselineCountLine(_ count: Int) -> String {
        t("基线：\(count) 条", "baselines: \(count)")
    }

    /// 列表行：颜色索引只写编号，不写色值 / 色名（颜色值属 App 层 DesignTokens，ADR-013）。
    func baselineLine(id: String, name: String, colorIndex: Int, createdAt: String, entries: Int) -> String {
        t(
            "  \(id) \(name)  颜色索引：\(colorIndex)  创建：\(createdAt)  条目：\(entries)",
            "  \(id) \(name)  color index: \(colorIndex)  created: \(createdAt)  entries: \(entries)"
        )
    }

    /// 创建回执：身份三字段（baselineID / name / createdAt）+ 颜色索引 + 条目数（判据 6）。
    func baselineCreated(id: String, name: String, colorIndex: Int, createdAt: String, entries: Int) -> String {
        t(
            "已创建基线：\(id) \(name) 颜色索引：\(colorIndex) 创建：\(createdAt)（\(entries) 条条目）",
            "baseline created: \(id) \(name) color index: \(colorIndex) created: \(createdAt) (\(entries) entries)"
        )
    }

    /// 改色回执：基线名 + 新颜色索引（脚本据此确认改到了哪一色）。
    func baselineColorChanged(name: String, colorIndex: Int) -> String {
        t(
            "已改色：\(name) 颜色索引：\(colorIndex)",
            "baseline recolored: \(name) color index: \(colorIndex)"
        )
    }

    /// 颜色索引不是整数：用法错误（退出码 2）。越界（如 8 / -1）不在此处拦，
    /// 由会话层以 model_baseline_color_index_invalid 统一拒绝，避免两处范围判断漂移。
    func invalidColorIndex(_ raw: String) -> String {
        t("颜色索引必须是 0…7 的整数：\(raw)", "color index must be an integer in 0...7: \(raw)")
    }

    /// 删除回执：删除前取到的身份三字段（删除后就查不到了）。
    func baselineDeleted(id: String, name: String, createdAt: String) -> String {
        t(
            "已删除基线：\(id) \(name) 创建：\(createdAt)",
            "baseline deleted: \(id) \(name) created: \(createdAt)"
        )
    }

    /// 偏差报告头：必须带 `baselineID` / 名称 / 颜色索引 / 创建时刻（§4.5、§4），
    /// 否则切换基线后的报表跨版本不可比、也对不上图上那一条的颜色。
    func varianceBaselineLine(name: String, id: String, colorIndex: Int, createdAt: String) -> String {
        t(
            "基线：\(name)（\(id)）颜色索引：\(colorIndex) 创建：\(createdAt)",
            "baseline: \(name) (\(id)) color index: \(colorIndex) created: \(createdAt)"
        )
    }

    func varianceProjectLine(_ days: String) -> String {
        t("项目结束偏差：\(days)", "project finish variance: \(days)")
    }

    func varianceSummary(late: Int, overdue: Int, withoutBaseline: Int, forecast: Int) -> String {
        t(
            "晚完成 \(late) 个 · 逾期未完成 \(overdue) 个 · 无基线 \(withoutBaseline) 个 · 含预测项 \(forecast) 个",
            "completed late \(late) · overdue open \(overdue) · without baseline \(withoutBaseline) · forecast \(forecast)"
        )
    }

    // MARK: - project summary / CSV 导出（v0.15 · 09 §4）

    /// 项目摘要的任务构成行：任务 / 群组 / 里程碑分开计数（群组与里程碑不算「任务」）。
    func summaryTaskLine(tasks: Int, groups: Int, milestones: Int) -> String {
        t(
            "任务：\(tasks) 个 · 群组 \(groups) 个 · 里程碑 \(milestones) 个",
            "tasks: \(tasks) · groups: \(groups) · milestones: \(milestones)"
        )
    }

    /// 项目摘要的状态分布行（四档恒出，含 0——缺档会让读者以为漏算）。
    func summaryStatusLine(pending: Int, inProgress: Int, done: Int, blocked: Int) -> String {
        t(
            "状态：待办 \(pending) · 进行中 \(inProgress) · 已完成 \(done) · 阻塞 \(blocked)",
            "status: pending \(pending) · in progress \(inProgress) · done \(done) · blocked \(blocked)"
        )
    }

    /// 孤儿计数（§5）：条目在、任务已删；与 CSV 孤儿节、基线面板同口径。
    func summaryOrphanLine(_ count: Int) -> String {
        t("孤儿：\(count) 条（基线条目在、任务已删）", "orphans: \(count) (baseline entry kept, task deleted)")
    }

    /// `--csv` 的路径取值名（缺值时报「缺少参数：<CSV 路径>」）。
    var operandCSVPath: String { t("CSV 路径", "CSV path") }

    /// `--csv` 与 `--json` 同时给出：两个机器出口互斥，避免半份 JSON 混进 CSV。
    var csvConflictsWithJSON: String {
        t(
            "--csv 与 --json 不能同时使用（二选一）",
            "--csv and --json are mutually exclusive"
        )
    }

    /// CSV 导出回执：路径 + 基线身份三字段（§4.5）+ 行数与孤儿数（据此核对导全了没）。
    func csvExported(
        path: String,
        baselineName: String,
        baselineID: String,
        rows: Int,
        orphans: Int
    ) -> String {
        t(
            "已导出 CSV：\(path)（基线：\(baselineName)（\(baselineID)）· 行 \(rows) · 孤儿 \(orphans)）",
            "CSV exported: \(path) (baseline: \(baselineName) (\(baselineID)) · rows \(rows) · orphans \(orphans))"
        )
    }

    /// CSV 写盘失败：路径不可写属运行时错误（退出码 1），文案给出路径与系统原因。
    func csvWriteFailed(path: String, reason: String) -> String {
        t("CSV 写入失败：\(path)（\(reason)）", "failed to write CSV: \(path) (\(reason))")
    }

    /// 偏差行：`计划偏差 开始/结束`、`实际偏差 开始/结束`（顺序固定，与检查器同口径）。
    ///
    /// - Parameters:
    ///   - span: 基线起止（「开始 → 结束」，无基线条目时为「—」）。
    ///   - plan: 计划偏差「开始/结束」，两侧各自带符号或「—」。
    ///   - actual: 实际偏差「开始/结束」，缺实际时间为「—」。
    ///   - note: 基线之后新增等附加说明；nil 不占位。
    func varianceTaskLine(
        id: String,
        title: String,
        span: String,
        plan: String,
        actual: String,
        note: String?
    ) -> String {
        var line = t(
            "  \(id) \(title)  基线 \(span)  计划偏差 \(plan)  实际偏差 \(actual)",
            "  \(id) \(title)  baseline \(span)  plan variance \(plan)  actual variance \(actual)"
        )
        if let note { line += "  " + note }
        return line
    }

    /// 基线之后新增：有任务无条目，偏差列显示「—」并说明原因（§5）。
    var baselineAddedAfterSnapshot: String {
        t("基线之后新增（无基线数据）", "added after baseline (no baseline data)")
    }

    /// `task get` 的基线段（§8）：基线名 + 基线标识。
    func detailBaseline(name: String, id: String) -> String {
        t("基线：\(name)（\(id)）", "baseline: \(name) (\(id))")
    }

    /// `task get` 的基线起止。
    func detailBaselineSpan(start: String, finish: String) -> String {
        t("基线起止：\(start) → \(finish)", "baseline span: \(start) → \(finish)")
    }

    /// `task get` 的计划偏差（预测层 vs 基线）。
    func detailPlanVariance(start: String, finish: String) -> String {
        t("计划偏差：开始 \(start) · 结束 \(finish)", "plan variance: start \(start) · finish \(finish)")
    }

    /// `task get` 的实际偏差（事实层 vs 基线）；缺实际时间为「—」，不回落成计划值。
    func detailActualVariance(start: String, finish: String) -> String {
        t("实际偏差：开始 \(start) · 结束 \(finish)", "actual variance: start \(start) · finish \(finish)")
    }

    // MARK: - 领域枚举标签

    func kindLabel(_ kind: TaskKind) -> String {
        switch kind {
        case .task: return t("任务", "task")
        case .group: return t("群组", "group")
        case .milestone: return t("里程碑", "milestone")
        }
    }

    func statusLabel(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return t("待办", "pending")
        case .inProgress: return t("进行中", "in progress")
        case .done: return t("已完成", "done")
        case .blocked: return t("阻塞", "blocked")
        case .cancelled: return t("已取消", "cancelled")
        }
    }

    func priorityLabel(_ priority: TaskPriority) -> String {
        switch priority {
        case .low: return t("低", "low")
        case .normal: return t("普通", "normal")
        case .high: return t("高", "high")
        case .critical: return t("紧急", "critical")
        }
    }

    func resourceKindLabel(_ kind: ResourceKind) -> String {
        switch kind {
        case .person: return t("人员", "person")
        case .equipment: return t("设备", "equipment")
        case .material: return t("素材", "material")
        case .group: return t("群组", "group")
        }
    }
}

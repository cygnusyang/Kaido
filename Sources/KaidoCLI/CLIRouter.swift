import Foundation
import KaidoCore
import KaidoCommands

/// CLI 用法错误：参数缺失 / 取值非法 → 退出码 2（区别于运行时错误的 1）。
struct UsageError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// \`status batch\` 的 JSON 条目：taskID 接受完整 UUID 或唯一前缀。
/// \`cancelReason\`（v0.16）只在 status 为 cancelled 时使用；缺原因由会话层逐条拒（不中断其余条目）。
private struct StatusBatchItem: Decodable {
    let taskID: String
    let status: String?
    let cancelReason: String?
    let progress: Double?
}

/// CLI 路由（ADR-005 契约同源）：子命令解析 → KaidoSession 操作 → 输出呈现。
/// 每次调用创建独立 KaidoSession；task/wbs 命令按「打开 --file → 操作 → 保存」模式执行。
///
/// 语言（F-0707）：\`--lang\` 在分发前由 \`GlobalOptions.extract\` 摘除并注入 \`Options\`，
/// 各命令只经 \`Options.strings\` 取词，白名单因此零改动、位置无关。
/// \`--json\` 输出（\`CLIOutput\`）不经过文案表，与语言无关。
struct CLIRouter {
    /// 程序入口包装：成功 0 / 运行时错误 1 / 用法错误 2。
    static func run(arguments: [String]) -> Int32 {
        run(
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    /// 可注入环境与系统语言的入口：测试无需改进程环境即可验证优先级（D-02/D-03/G-02）。
    static func run(arguments: [String], environment: [String: String], preferredLanguages: [String]) -> Int32 {
        // 先在 try 外取兜底语言：\`--lang\` 本身非法时，这条用法错误也要有语言可用。
        var language = CLILanguage.fromEnvironmentOrSystem(
            environment: environment,
            preferredLanguages: preferredLanguages
        )
        do {
            let (rest, explicit) = try GlobalOptions.extract(arguments)
            if let explicit { language = explicit }
            try dispatch(rest, language: language, emit: { print($0) })
            return 0
        } catch let error as UsageError {
            stderr(language.strings.usagePrefix(error.message))
            return 2
        } catch let error as CLIError {
            // 枚举值/相关性规格非法同属用法错误（退出码 2）。
            stderr(language.strings.usagePrefix(error.message(language)))
            return 2
        } catch {
            stderr(language.strings.errorPrefix(errorMessage(error)))
            return 1
        }
    }

    /// 解析并执行单条命令（测试可直接调用；抛出错误而非退出进程）。
    static func execute(arguments: [String]) throws {
        try execute(
            arguments: arguments,
            environment: ProcessInfo.processInfo.environment,
            preferredLanguages: Locale.preferredLanguages
        )
    }

    /// 可注入语言来源与输出出口的执行入口（接口测试用）。
    static func execute(
        arguments: [String],
        environment: [String: String],
        preferredLanguages: [String],
        emit: @escaping (String) -> Void = { print($0) }
    ) throws {
        let (rest, explicit) = try GlobalOptions.extract(arguments)
        let language = explicit ?? CLILanguage.fromEnvironmentOrSystem(
            environment: environment,
            preferredLanguages: preferredLanguages
        )
        try dispatch(rest, language: language, emit: emit)
    }

    /// 子命令分发（全局选项已摘除）。
    private static func dispatch(
        _ arguments: [String],
        language: CLILanguage,
        emit: @escaping (String) -> Void
    ) throws {
        let (group, rest) = subcommand(arguments, from: "kaido")
        // 组级命令直接带选项（如 \`kaido violations --file x.kaido\`）：下一 token 以 -- 开头即视为无子命令。
        let (command, args): (String, [String])
        if let first = rest.first, first.hasPrefix("--") {
            command = ""
            args = rest
        } else {
            (command, args) = subcommand(rest, from: group)
        }
        let options = Options(args, language: language, emit: emit)
        switch (group, command) {
        case ("project", "create"): try projectCreate(options)
        case ("project", "open"): try projectOpen(options)
        case ("project", "save"): try projectSave(options)
        case ("project", "summary"): try projectSummary(options)
        case ("task", "add"): try taskAdd(options)
        case ("task", "list"): try taskList(options)
        case ("task", "get"): try taskGet(options)
        case ("task", "update"): try taskUpdate(options)
        case ("task", "delete"): try taskDelete(options)
        case ("wbs", "import"): try wbsImport(options)
        case ("schedule", "compute"): try scheduleCompute(options)
        case ("schedule", "path"): try schedulePath(options)
        case ("violations", ""): try violations(options)
        case ("status", "update"): try statusUpdate(options)
        case ("status", "batch"): try statusBatch(options)
        case ("resource", "add"): try resourceAdd(options)
        case ("resource", "list"): try resourceList(options)
        case ("baseline", "list"): try baselineList(options)
        case ("baseline", "create"): try baselineCreate(options)
        case ("baseline", "delete"): try baselineDelete(options)
        case ("baseline", "color"): try baselineColor(options)
        case ("baseline", "variance"): try baselineVariance(options)
        default:
            let strings = options.strings
            throw UsageError(message: strings.unknownCommand(
                group: group.isEmpty ? strings.emptyLabel : group,
                command: command.isEmpty ? strings.emptyLabel : command
            ))
        }
    }

    // MARK: - project

    /// kaido project create <标题> [--file <路径>]：新建并保存到文件（默认 ./project.kaido）。
    private static func projectCreate(_ o: Options) throws {
        let s = o.strings
        let title = try o.operand(0, name: s.operandTitle)
        let start = try optionalISO(o.value(for: "--start"), field: s.operandProjectStart, strings: s)
        let end = try optionalISO(o.value(for: "--end"), field: s.operandProjectEnd, strings: s)
        let session = KaidoSession()
        let meta = try session.createProject(title: title, projectStart: start, projectEnd: end)
        let url = fileURL(o.value(for: "--file"))
        _ = try session.saveProject(to: url)
        o.emit(s.projectCreated(id: shortID(meta.id), title: meta.title))
        o.emit(s.saved(path: url.path))
        o.emit(formatVersionLine(written: KaidoFile.currentFormatVersion, upgradedFrom: nil, language: o.language))
    }

    /// kaido project open <路径>：打开并打印项目元数据。
    private static func projectOpen(_ o: Options) throws {
        let s = o.strings
        let path = try o.operand(0, name: s.operandFilePath)
        let session = KaidoSession()
        let meta = try session.openProject(at: URL(fileURLWithPath: path))
        o.emit(s.projectLine(meta.title))
        o.emit(s.projectIDLine(meta.id.uuidString))
        o.emit(s.taskCountLine(session.project?.tasks.count ?? 0))
        o.emit(sourceVersionLine(
            source: session.sourceFormatVersion ?? KaidoFile.currentFormatVersion,
            current: KaidoFile.currentFormatVersion,
            language: o.language
        ))
    }

    /// kaido project save [--file <路径>]：重新保存（默认 ./project.kaido），验证往返。
    private static func projectSave(_ o: Options) throws {
        let s = o.strings
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        // 保存会把来源版本置为 current，必须先捕获（FR-KAIDO-FMT-6）。
        let upgradedFrom = session.sourceFormatVersion
        let meta = try session.saveProject()
        o.emit(s.saved(path: session.projectURL?.path ?? ""))
        o.emit(s.updatedAt(ISO8601DateFormatter().string(from: meta.updatedAt)))
        o.emit(formatVersionLine(
            written: KaidoFile.currentFormatVersion,
            upgradedFrom: upgradedFrom,
            language: o.language
        ))
    }

    /// 保存/新建的格式版本输出行（FR-KAIDO-FMT-6）：
    /// 「格式版本：vN（已从 vM 升级）」/「格式版本：vN」。
    static func formatVersionLine(
        written: Int,
        upgradedFrom: Int?,
        language: CLILanguage = .current
    ) -> String {
        CLIStrings(language: language).formatVersionLine(written: written, upgradedFrom: upgradedFrom)
    }

    /// 打开时的来源版本输出行：「源格式版本：vM（当前 vN）」；
    /// 来源早于当前版本时追加「，保存后升级」。
    static func sourceVersionLine(source: Int, current: Int, language: CLILanguage = .current) -> String {
        CLIStrings(language: language).sourceVersionLine(source: source, current: current)
    }

    /// kaido project summary [--baseline <基线ID>] [--json] [--file <路径>]：项目级摘要 + 偏差块。
    ///
    /// 偏差块与 `baseline variance` **同源**（同一份 `BaselineVarianceReport`，同一套项目级口径），
    /// 只是不重复列任务行——逐任务明细仍走 `baseline variance`。
    /// 项目还没有基线时整块换成「尚未创建基线」：无基线可比较不等于「偏差为 0」（§4.1）。
    private static func projectSummary(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--baseline", "--json", "--file"])
        let session = KaidoSession()
        let meta = try session.openProject(at: fileURL(o.value(for: "--file")))
        let tasks = try session.listTasks()
        let baselines = try session.baselines()

        // 显式指定基线但不存在 → 报错（用户指了名却被静默换成最新基线会更糟）。
        let report: BaselineVarianceReport?
        if let raw = o.value(for: "--baseline") {
            let target = try resolveBaseline(raw, in: session, strings: s)
            report = try session.baselineVariance(baselineID: target.id)
        } else if baselines.isEmpty {
            report = nil
        } else {
            report = try session.baselineVariance()
        }

        if o.flag("--json") {
            o.emit(try CLIOutput.projectSummaryJSON(meta, tasks: tasks, report: report, baselines: baselines))
            return
        }

        o.emit(s.projectLine(meta.title))
        o.emit(s.projectIDLine(meta.id.uuidString))
        o.emit(s.summaryTaskLine(
            tasks: tasks.filter { $0.kind == .task }.count,
            groups: tasks.filter { $0.kind == .group }.count,
            milestones: tasks.filter { $0.kind == .milestone }.count
        ))
        o.emit(s.summaryStatusLine(
            pending: tasks.filter { $0.status == .pending }.count,
            inProgress: tasks.filter { $0.status == .inProgress }.count,
            done: tasks.filter { $0.status == .done }.count,
            blocked: tasks.filter { $0.status == .blocked }.count
        ))
        guard let report else {
            o.emit(s.noBaselines)
            return
        }
        o.emit(s.varianceBaselineLine(
            name: report.baselineName,
            id: report.baselineID.uuidString,
            colorIndex: CLIOutput.resolvedColorIndex(of: report.baselineID, in: baselines),
            createdAt: formatDate(report.baselineCreatedAt)
        ))
        o.emit(s.varianceProjectLine(s.varianceDays(report.projectFinishVariance)))
        o.emit(s.varianceSummary(
            late: report.lateTaskCount,
            overdue: report.overdueOpenCount,
            withoutBaseline: report.tasksWithoutBaseline,
            forecast: report.predictedTaskCount
        ))
        o.emit(s.summaryOrphanLine(report.orphans.count))
    }

    // MARK: - task

    /// kaido task add <标题> [--kind/--parent/--effort/--duration/--notes/--priority/--status/--tags/--dep/--constraint/--policy/--assignee ...]。
    private static func taskAdd(_ o: Options) throws {
        let s = o.strings
        // 先解析全部参数（用法错误在 IO 前抛出），再打开文件操作。
        let title = try o.operand(0, name: s.operandTitle)
        let kind = try CLIEnums.kind(o.value(for: "--kind"), language: o.language) ?? .task
        let rawParent = o.value(for: "--parent")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes") ?? ""
        let priority = try CLIEnums.priority(o.value(for: "--priority"), language: o.language) ?? .normal
        let status = try CLIEnums.status(o.value(for: "--status"), language: o.language) ?? .pending
        let tags = splitTags(o.value(for: "--tags"))
        let depSpecs = try o.values(for: "--dep").map { try CLIEnums.dependency($0, language: o.language) }
        let assignSpecs = try o.values(for: "--assign").map { try CLIEnums.assignment($0, language: o.language) }
        let constraint = try CLIEnums.constraint(o.value(for: "--constraint"), language: o.language)
        let policy = try CLIEnums.schedulingPolicy(o.value(for: "--policy"), language: o.language) ?? .asap
        // 负责人（US-E1-02）：不传或空串 = nil（默认无负责人）；否则设置。
        let assignee = o.value(for: "--assignee").flatMap { $0.isEmpty ? nil : $0 }

        let session = KaidoSession()
        try openForEdit(session, o)
        let parentID = try rawParent.map { try resolveTaskID($0, in: session, strings: s) }
        let deps = try depSpecs.map { try $0.resolve(in: session, strings: s) }
        let assignments = try assignSpecs.map { try $0.resolve(in: session, strings: s) }
        let id = try session.addTask(
            title: title,
            kind: kind,
            parentID: parentID,
            effortHours: effort,
            durationDays: duration,
            notes: notes,
            priority: priority,
            status: status,
            tags: tags,
            dependencies: deps,
            constraint: constraint,
            schedulingPolicy: policy,
            assignments: assignments,
            assignee: assignee
        )
        try session.saveProject()
        o.emit(s.taskCreated(id: shortID(id), title: title))
    }

    /// kaido task list [--parent <UUID>] [--filter <文本>] [--json] [--file <路径>]。
    private static func taskList(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--parent", "--filter", "--json", "--file"])
        let rawParent = o.value(for: "--parent")
        let filter = o.value(for: "--filter") ?? ""
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let parentID = try rawParent.map { try resolveTaskID($0, in: session, strings: s) }
        let tasks = try session.listTasks(parentID: parentID, filter: filter)
        if o.flag("--json") {
            // --json 与语言无关（D-04）：只编码数据，不经过文案表。
            o.emit(try CLIOutput.taskListJSON(tasks))
        } else {
            for task in tasks { o.emit(taskListLine(task, strings: s)) }
        }
    }

    /// kaido task get <ID> [--file <路径>]：多行详情。
    private static func taskGet(_ o: Options) throws {
        let s = o.strings
        let rawID = try o.operand(0, name: s.operandTaskID)
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        guard let project = session.project else { return }
        let id = try resolveTaskID(rawID, in: session, strings: s)
        let task = try session.getTask(id: id)
        var detail = taskDetail(task, project: project, strings: s)
        if let section = baselineSection(for: id, in: session, strings: s) {
            detail += "\n" + section.joined(separator: "\n")
        }
        o.emit(detail)
    }

    /// kaido task update <ID> [--title/--kind/--parent/--effort/--duration/--notes/--priority/--status/--progress/--tags/--assignee]。
    private static func taskUpdate(_ o: Options) throws {
        let s = o.strings
        let depSpecs = try o.values(for: "--dep").map { try CLIEnums.dependency($0, language: o.language) }
        let assignSpecs = try o.values(for: "--assign").map { try CLIEnums.assignment($0, language: o.language) }
        let rawID = try o.operand(0, name: s.operandTaskID)
        let title = o.value(for: "--title")
        let kind = try CLIEnums.kind(o.value(for: "--kind"), language: o.language)
        let rawParent = o.value(for: "--parent")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes")
        let priority = try CLIEnums.priority(o.value(for: "--priority"), language: o.language)
        let status = try CLIEnums.status(o.value(for: "--status"), language: o.language)
        // 取消只能走 status update：task update 的写入口不落取消原因，放过就成了「无理由终态」。
        if status == .cancelled { throw UsageError(message: s.cancelViaStatusUpdate()) }
        let progress = o.double(for: "--progress")
        let tags = o.value(for: "--tags").map(splitTags)
        let constraint = try CLIEnums.constraint(o.value(for: "--constraint"), language: o.language)
        let policy = try CLIEnums.schedulingPolicy(o.value(for: "--policy"), language: o.language)
        // 负责人（US-E1-02）：nil = 不改；空串 = 清空（清空在共享层 updateTask 统一处理）。
        let assignee = o.value(for: "--assignee")
        try o.rejectUnknown([
            "--title", "--kind", "--parent", "--effort", "--duration", "--notes",
            "--priority", "--status", "--progress", "--tags", "--dep",
            "--constraint", "--policy", "--assign", "--assignee", "--file",
        ])

        let session = KaidoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session, strings: s)
        let parentID = try rawParent.map { try resolveTaskID($0, in: session, strings: s) }
        let deps = try depSpecs.map { try $0.resolve(in: session, strings: s) }
        let assignments = try assignSpecs.map { try $0.resolve(in: session, strings: s) }
        let task = try session.updateTask(
            id: id,
            title: title,
            kind: kind,
            parentID: parentID,
            effortHours: effort,
            durationDays: duration,
            notes: notes,
            priority: priority,
            status: status,
            progress: progress,
            tags: tags,
            dependencies: depSpecs.isEmpty ? nil : deps,
            constraint: constraint,
            schedulingPolicy: policy,
            assignments: assignSpecs.isEmpty ? nil : assignments,
            assignee: assignee
        )
        try session.saveProject()
        o.emit(s.taskUpdated(id: shortID(task.id), title: task.title))
    }

    /// kaido task delete <ID> [--file <路径>]：删除任务及其全部子任务。
    private static func taskDelete(_ o: Options) throws {
        let s = o.strings
        let rawID = try o.operand(0, name: s.operandTaskID)
        let session = KaidoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session, strings: s)
        let removed = try session.deleteTaskCascade(id: id)
        try session.saveProject()
        if removed > 1 {
            o.emit(s.taskDeletedWithSubtasks(id: shortID(id), subtasks: removed - 1))
        } else {
            o.emit(s.taskDeleted(id: shortID(id)))
        }
    }

    // MARK: - wbs

    /// kaido wbs import <JSON 文件> [--parent <UUID>] [--file <路径>]。
    private static func wbsImport(_ o: Options) throws {
        let s = o.strings
        let jsonPath = try o.operand(0, name: s.operandJSONFile)
        let rawParent = o.value(for: "--parent")
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let parentID = try rawParent.map { try resolveTaskID($0, in: session, strings: s) }
        let nodes: [WBSNode]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            nodes = try JSONDecoder().decode([WBSNode].self, from: data)
        } catch {
            // 用户文件读不出/解不了：storage 层失败，不是用法错误（退出码 1）。
            throw SessionError(
                code: .fileUnreadable,
                reason: .fileUnreadable,
                message: s.unparseableWBS(jsonPath)
            )
        }
        let result = try session.importWBS(nodes: nodes, parentID: parentID)
        try session.saveProject()
        o.emit(s.importedTasks(result.total))
        for id in result.rootIDs {
            let task = try session.getTask(id: id)
            o.emit("  \(shortID(id)) \(task.title)")
        }
    }

    // MARK: - schedule（US-E2-02 / US-E2-03）

    /// kaido schedule compute [--start <ISO>] [--end <ISO>] [--file <路径>]。
    private static func scheduleCompute(_ o: Options) throws {
        let s = o.strings
        let start = try optionalISO(o.value(for: "--start"), field: s.operandProjectStart, strings: s)
        let end = try optionalISO(o.value(for: "--end"), field: s.operandProjectEnd, strings: s)
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let result = try session.computeSchedule(projectStart: start, projectEnd: end)
        let byID = session.project?.tasksByID ?? [:]
        o.emit(s.scheduleComputed(result.tasks.count))
        for t in result.tasks {
            let task = byID[t.taskID]
            let policy = task?.schedulingPolicy ?? .asap
            o.emit(s.scheduleLine(
                id: shortID(t.taskID),
                title: task?.title ?? s.unknownTask,
                start: formatDate(t.scheduledStart),
                finish: formatDate(t.scheduledFinish),
                duration: formatNumber(t.durationDays),
                policy: policy == .asap ? "ASAP" : "ALAP"
            ))
        }
    }

    /// kaido schedule path [--limit <天>] [--file <路径>]：重要路径与宽延。
    private static func schedulePath(_ o: Options) throws {
        let s = o.strings
        let limit = o.double(for: "--limit")
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let entries = try session.criticalPath(slackLimit: limit)
        let byID = session.project?.tasksByID ?? [:]
        let criticalCount = entries.filter(\.isCritical).count
        o.emit(s.criticalPathHeader(count: criticalCount, slackLimit: formatNumber(limit ?? 0)))
        for e in entries {
            let mark = e.isCritical ? " *" : ""
            o.emit(s.criticalPathLine(
                id: shortID(e.taskID),
                title: byID[e.taskID]?.title ?? s.unknownTask,
                mark: mark,
                totalSlack: formatNumber(e.totalSlackDays),
                freeSlack: formatNumber(e.freeSlackDays)
            ))
        }
    }

    // MARK: - violations（US-E2-05）

    /// kaido violations [--file <路径>]。
    private static func violations(_ o: Options) throws {
        let s = o.strings
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let vs = try session.violations()
        if vs.isEmpty {
            o.emit(s.noViolations)
            return
        }
        o.emit(s.violationCount(vs.count))
        for v in vs {
            // 码用稳定错误码（与语言无关）；文案由 reason 的语义与参数渲染。
            o.emit(s.violationLine(
                severity: s.severityLabel(v.severity),
                code: v.code.rawValue,
                text: s.violationText(v)
            ))
        }
    }

    // MARK: - status（US-E3-01 / US-E3-02）

    /// kaido status update <ID> [--status] [--reason] [--progress] [--file <路径>]。
    ///
    /// `cancelled`（v0.16）必须配 `--reason`：缺原因或纯空白在打开文件之前就报用法错误（2），
    /// 用户不必等 IO 才发现漏了理由。
    private static func statusUpdate(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--status", "--reason", "--progress", "--file"])
        let rawID = try o.operand(0, name: s.operandTaskID)
        let status = try CLIEnums.status(o.value(for: "--status"), language: o.language)
        let cancelReason = try CLIEnums.cancelReason(
            status: status, raw: o.value(for: "--reason"), language: o.language
        )
        let progress = o.double(for: "--progress")
        let session = KaidoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session, strings: s)
        let task = try session.statusUpdate(
            id: id, status: status, cancelReason: cancelReason, progress: progress
        )
        try session.saveProject()
        o.emit(s.statusWritten(
            id: shortID(task.id),
            title: task.title,
            status: s.statusLabel(task.status),
            progress: Int(task.progress * 100)
        ))
        // 回执带原因：取消之后用户要能确认「砍掉的理由」确实写进去了。
        if let reason = task.cancelReason {
            o.emit(s.cancelReasonLine(reason))
        }
        if let completed = task.completedAt {
            o.emit(s.actualFinish(formatDate(completed)))
        }
        let group = try session.groupProgress(id: id)
        o.emit(s.groupProgress(Int(group * 100)))
    }

    /// kaido status batch <JSON 文件> [--file <路径>]：批量回写，JSON 为
    /// [{"taskID":"UUID 或前缀","status":"done","progress":1}]，逐条返回成功/失败。
    private static func statusBatch(_ o: Options) throws {
        let s = o.strings
        let jsonPath = try o.operand(0, name: s.operandJSONFile)
        let session = KaidoSession()
        try openForEdit(session, o)
        let items: [StatusBatchItem]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            items = try JSONDecoder().decode([StatusBatchItem].self, from: data)
        } catch {
            throw SessionError(
                code: .fileUnreadable,
                reason: .fileUnreadable,
                message: s.unparseableBatch(jsonPath)
            )
        }

        // 逐条解析任务标识；无法解析的条目记为失败，不中断其余条目。
        struct Pending {
            let index: Int
            let input: KaidoSession.StatusUpdateInput?
            let label: String
            let error: String?
        }
        var pending: [Pending] = []
        for (index, item) in items.enumerated() {
            let status = try CLIEnums.status(item.status, language: o.language)
            do {
                let id = try resolveTaskID(item.taskID, in: session, strings: s)
                pending.append(Pending(
                    index: index,
                    // cancelReason 原样交给会话层：批次里缺原因只拒该条，不打断其余条目。
                    input: .init(
                        taskID: id,
                        status: status,
                        cancelReason: item.cancelReason,
                        progress: item.progress
                    ),
                    label: shortID(id),
                    error: nil
                ))
            } catch {
                pending.append(Pending(index: index, input: nil, label: item.taskID, error: errorMessage(error)))
            }
        }

        let inputs = pending.compactMap(\.input)
        let result = try session.statusBatch(inputs)
        try session.saveProject()

        var entriesByIndex: [Int: KaidoSession.StatusBatchResult.Entry] = [:]
        let resolvedIndices = pending.filter { $0.input != nil }.map(\.index)
        for (index, entry) in zip(resolvedIndices, result.entries) {
            entriesByIndex[index] = entry
        }

        var failed = 0
        for item in pending {
            guard let entry = entriesByIndex[item.index] else {
                failed += 1
                o.emit(s.batchEntryFailed(label: item.label, reason: item.error ?? s.unknownError))
                continue
            }
            if entry.ok, let task = entry.task {
                o.emit(s.statusWritten(
                    id: shortID(task.id),
                    title: task.title,
                    status: s.statusLabel(task.status),
                    progress: Int(task.progress * 100)
                ))
                if let reason = task.cancelReason { o.emit(s.cancelReasonLine(reason)) }
            } else {
                failed += 1
                o.emit(s.batchEntryFailed(
                    label: shortID(entry.taskID),
                    reason: entry.error ?? s.unknownError
                ))
            }
        }
        o.emit(s.batchSummary(succeeded: items.count - failed, failed: failed))
        if failed > 0 {
            // 逐条失败已打印，这里抛一条汇总错误让退出码为 1；无更贴切的稳定码，按兜底。
            throw SessionError(code: .invalidArgument, reason: .internalError, message: s.batchFailures(failed))
        }
    }

    // MARK: - resource（F-23-01 / ADR-009）

    /// kaido resource add <名称> [--type person|equipment|material|group] [--units] [--efficiency] [--file <路径>]。
    private static func resourceAdd(_ o: Options) throws {
        let s = o.strings
        let name = try o.operand(0, name: s.operandResourceName)
        let kind = try CLIEnums.resourceKind(o.value(for: "--type"), language: o.language) ?? .person
        let units = o.double(for: "--units") ?? 1
        let efficiency = o.double(for: "--efficiency") ?? 1
        let session = KaidoSession()
        try openForEdit(session, o)
        let id = try session.resourceAdd(name: name, kind: kind, units: units, efficiency: efficiency)
        try session.saveProject()
        o.emit(s.resourceAdded(
            id: shortID(id),
            name: name,
            kind: s.resourceKindLabel(kind),
            units: formatNumber(units),
            efficiency: formatNumber(efficiency)
        ))
    }

    /// kaido resource list [--file <路径>]。
    private static func resourceList(_ o: Options) throws {
        let s = o.strings
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let resources = try session.resourceList()
        for r in resources {
            o.emit(s.resourceLine(
                id: shortID(r.id),
                name: r.name,
                kind: s.resourceKindLabel(r.kind),
                units: formatNumber(r.units),
                efficiency: formatNumber(r.efficiency)
            ))
        }
    }

    // MARK: - baseline（v0.13 / 08-baselines §8）

    /// kaido baseline list [--json] [--file <路径>]：按创建顺序列出基线。
    private static func baselineList(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--json", "--file"])
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let baselines = try session.baselines()
        if o.flag("--json") {
            o.emit(try CLIOutput.baselineListJSON(baselines))
            return
        }
        guard !baselines.isEmpty else {
            o.emit(s.noBaselines)
            return
        }
        o.emit(s.baselineCountLine(baselines.count))
        let colors = CLIOutput.resolvedColorIndexes(baselines)
        for (baseline, colorIndex) in zip(baselines, colors) {
            o.emit(s.baselineLine(
                id: baseline.id.uuidString,
                name: baseline.name,
                colorIndex: colorIndex,
                createdAt: formatDate(baseline.createdAt),
                entries: baseline.entries.count
            ))
        }
    }

    /// kaido baseline create [--name <名称>] [--file <路径>]：对当前排期拍一次快照。
    ///
    /// 缺省名由会话层生成「基线 N · yyyy-MM-dd」；空名 / 纯空白名由会话层校验拒绝。
    private static func baselineCreate(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--name", "--file"])
        let name = o.value(for: "--name")
        let session = KaidoSession()
        try openForEdit(session, o)
        let baseline = try session.createBaseline(name: name)
        try session.saveProject()
        // 颜色索引按创建后的整组归一，与 list 同口径（回执里不写死 0）。
        let colorIndex = CLIOutput.resolvedColorIndex(of: baseline.id, in: try session.baselines())
        o.emit(s.baselineCreated(
            id: baseline.id.uuidString,
            name: baseline.name,
            colorIndex: colorIndex,
            createdAt: formatDate(baseline.createdAt),
            entries: baseline.entries.count
        ))
    }

    /// kaido baseline delete <基线ID> [--file <路径>]：删除一条基线（其余基线不受影响）。
    private static func baselineDelete(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--file"])
        let rawID = try o.operand(0, name: s.operandBaselineID)
        let session = KaidoSession()
        try openForEdit(session, o)
        // 回执要带身份三字段：删除后列表里就查不到了，先取（判据 6）。
        let removed = try resolveBaseline(rawID, in: session, strings: s)
        try session.deleteBaseline(id: removed.id)
        try session.saveProject()
        o.emit(s.baselineDeleted(
            id: removed.id.uuidString,
            name: removed.name,
            createdAt: formatDate(removed.createdAt)
        ))
    }

    /// kaido baseline color <基线ID> <颜色索引> [--file <路径>]：给基线换调色板颜色（0…7）。
    ///
    /// 职责划分：命令层只判「是不是整数」（用法错误，退出码 2）；范围（0…7）由会话层
    /// 统一拒绝并带 model_baseline_color_index_invalid，两处各判一遍迟早漂移。
    /// 未知 ID / 前缀歧义沿用 `resolveBaseline` 的既有用法错误路径（退出码 2）。
    private static func baselineColor(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--file"])
        // 两个位置参数：--file 的值不是操作数，必须显式排除（见 Options.operand）。
        let fileArg = o.value(for: "--file")
        let rawID = try o.operand(0, name: s.operandBaselineID, excluding: fileArg)
        let rawIndex = try o.operand(1, name: s.operandColorIndex, excluding: fileArg)
        guard let colorIndex = Int(rawIndex) else {
            throw UsageError(message: s.invalidColorIndex(rawIndex))
        }
        let session = KaidoSession()
        try openForEdit(session, o)
        let target = try resolveBaseline(rawID, in: session, strings: s)
        let updated = try session.setBaselineColor(id: target.id, colorIndex: colorIndex)
        try session.saveProject()
        o.emit(s.baselineColorChanged(
            name: updated.name,
            colorIndex: CLIOutput.resolvedColorIndex(of: updated.id, in: try session.baselines())
        ))
    }

    /// kaido baseline variance [--baseline <基线ID>] [--task <任务ID>] [--json | --csv <路径>] [--file <路径>]。
    ///
    /// - 省略 `--baseline` 时比较**最新**一条基线（与 MCP `baseline_variance` 同口径）；
    /// - `--task` 只收窄任务行，项目级聚合仍按全项目计算（聚合口径不随过滤漂移）；
    /// - 文本、`--json`、`--csv` 都必须带基线标识（§4.5），否则报表跨版本不可比；
    /// - `--csv` 与 `--json` 互斥（两个机器出口同时给会产出半份混合内容）。
    private static func baselineVariance(_ o: Options) throws {
        let s = o.strings
        try o.rejectUnknown(["--baseline", "--task", "--json", "--csv", "--file"])
        let session = KaidoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let baselineID = try o.value(for: "--baseline").map {
            try resolveBaseline($0, in: session, strings: s).id
        }
        let taskID = try o.value(for: "--task").map {
            try resolveTaskID($0, in: session, strings: s)
        }
        let report = try session.baselineVariance(baselineID: baselineID)
        let colorIndex = CLIOutput.resolvedColorIndex(of: report.baselineID, in: try session.baselines())
        let projectOrder = (session.project?.tasks ?? []).map(\.id)
        var taskIDs = VarianceCSV.orderedTaskIDs(report, projectOrder: projectOrder)
        if let taskID {
            taskIDs = taskIDs.filter { $0 == taskID }
        }

        // 两个机器出口互斥：同时给出时报用法错误，不让其中一个静默胜出。
        if o.flag("--csv"), o.flag("--json") {
            throw UsageError(message: s.csvConflictsWithJSON)
        }

        if o.flag("--csv") {
            // 紧跟的 token 若以 -- 开头，说明 --csv 没给值（如 "--csv --file p.kaido"）：
            // 直接取会把它当成路径，静默写出一个名为 --file 的垃圾文件。
            let rawPath = o.value(for: "--csv")
            guard let rawPath, !rawPath.hasPrefix("--") else {
                throw UsageError(message: s.missingOperand(s.operandCSVPath))
            }
            let url = URL(fileURLWithPath: rawPath)
            let document = VarianceCSV.document(
                report: report,
                taskIDs: taskIDs,
                titles: (session.project?.tasksByID ?? [:]).mapValues(\.title),
                // --task 收窄到单个任务时不带孤儿节：孤儿属于项目级清单，不是这个任务的明细。
                includeOrphans: taskID == nil
            )
            do {
                try Data(document.utf8).write(to: url, options: .atomic)
            } catch {
                throw CSVWriteFailure(message: s.csvWriteFailed(
                    path: url.path,
                    reason: (error as NSError).localizedDescription
                ))
            }
            o.emit(s.csvExported(
                path: url.path,
                baselineName: report.baselineName,
                baselineID: report.baselineID.uuidString,
                rows: taskIDs.count,
                orphans: taskID == nil ? report.orphans.count : 0
            ))
            return
        }

        if o.flag("--json") {
            o.emit(try CLIOutput.baselineVarianceJSON(report, taskIDs: taskIDs, colorIndex: colorIndex))
            return
        }

        o.emit(s.varianceBaselineLine(
            name: report.baselineName,
            id: report.baselineID.uuidString,
            colorIndex: colorIndex,
            createdAt: formatDate(report.baselineCreatedAt)
        ))
        o.emit(s.varianceProjectLine(s.varianceDays(report.projectFinishVariance)))
        o.emit(s.varianceSummary(
            late: report.lateTaskCount,
            overdue: report.overdueOpenCount,
            withoutBaseline: report.tasksWithoutBaseline,
            forecast: report.predictedTaskCount
        ))
        let byID = session.project?.tasksByID ?? [:]
        for id in taskIDs {
            guard let variance = report.tasks[id] else { continue }
            o.emit(s.varianceTaskLine(
                id: shortID(id),
                title: byID[id]?.title ?? s.unknownTask,
                span: baselineSpanText(variance, strings: s),
                plan: variancePair(variance.planStartVariance, variance.planFinishVariance, strings: s),
                actual: variancePair(variance.actualStartVariance, variance.actualFinishVariance, strings: s),
                note: variance.hasBaseline ? nil : s.baselineAddedAfterSnapshot
            ))
        }
    }

    /// 基线起止文本：两侧都有才算一段承诺，缺任一侧给「—」（不臆造时间）。
    private static func baselineSpanText(_ variance: TaskVariance, strings s: CLIStrings) -> String {
        guard let start = variance.baselineStart, let finish = variance.baselineFinish else {
            return s.varianceEmpty
        }
        return "\(formatDate(start)) → \(formatDate(finish))"
    }

    /// 「开始/结束」成对偏差（缺值为「—」，不写 0）。
    private static func variancePair(_ start: Int?, _ finish: Int?, strings s: CLIStrings) -> String {
        "\(s.varianceDays(start))/\(s.varianceDays(finish))"
    }

    // MARK: - 帮助

    /// 打开 --file（默认 ./project.kaido）。task/wbs 写命令统一入口。
    private static func openForEdit(_ session: KaidoSession, _ o: Options) throws {
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
    }

    private static func fileURL(_ raw: String?) -> URL {
        URL(fileURLWithPath: raw ?? "project.kaido")
    }

    /// 解析任务标识：接受完整 UUID 或唯一前缀（≥4 位），返回完整 UUID。--parent 同此规则。
    static func resolveTaskID(_ raw: String, in session: KaidoSession, strings: CLIStrings) throws -> UUID {
        if let full = UUID(uuidString: raw) { return full }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else {
            throw UsageError(message: strings.taskIDPrefixTooShort(raw))
        }
        let candidates = (session.project?.tasks ?? []).map(\.id).filter {
            $0.uuidString.lowercased().hasPrefix(prefix)
        }
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw UsageError(message: strings.taskNotFound(raw))
        default: throw UsageError(message: strings.taskIDPrefixAmbiguous(raw, matches: candidates.count))
        }
    }

    /// 解析资源标识：接受完整 UUID 或唯一前缀（≥4 位）。
    static func resolveResourceID(_ raw: String, in session: KaidoSession, strings: CLIStrings) throws -> UUID {
        if let full = UUID(uuidString: raw) { return full }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else {
            throw UsageError(message: strings.resourceIDPrefixTooShort(raw))
        }
        let candidates = (session.project?.resources ?? []).map(\.id).filter {
            $0.uuidString.lowercased().hasPrefix(prefix)
        }
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw UsageError(message: strings.resourceNotFound(raw))
        default: throw UsageError(message: strings.resourceIDPrefixAmbiguous(raw, matches: candidates.count))
        }
    }

    /// 解析基线标识：接受完整 UUID 或唯一前缀（≥4 位），返回该基线。
    ///
    /// 返回基线本身而不是 ID：删除回执要在删除前拿到名称与创建时刻（判据 6）。
    static func resolveBaseline(_ raw: String, in session: KaidoSession, strings: CLIStrings) throws -> Baseline {
        let baselines = try session.baselines()
        if let full = UUID(uuidString: raw), let match = baselines.first(where: { $0.id == full }) {
            return match
        }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else {
            throw UsageError(message: strings.baselineIDPrefixTooShort(raw))
        }
        let candidates = baselines.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw UsageError(message: strings.baselineNotFound(raw))
        default: throw UsageError(message: strings.baselineIDPrefixAmbiguous(raw, matches: candidates.count))
        }
    }

    private static func shortID(_ id: UUID) -> String {
        String(id.uuidString.prefix(8))
    }

    private static func splitTags(_ raw: String?) -> [String] {
        guard let raw else { return [] }
        return raw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 文本呈现

    /// 任务行：\`ID 标题 [类型] 状态 · 优先级 · 投入 · 持续 · #标签\`（CLI 人类输出，非 --json）。
    private static func taskListLine(_ task: TaskItem, strings s: CLIStrings) -> String {
        s.taskListLine(
            id: shortID(task.id),
            title: task.title,
            kind: task.kind != .task ? s.kindLabel(task.kind) : nil,
            status: s.statusLabel(task.status),
            priority: task.priority != .normal ? s.priorityLabel(task.priority) : nil,
            effort: task.effortHours.map(formatNumber),
            duration: task.durationDays.map(formatNumber),
            tags: task.tags,
            cancelReason: task.cancelReason
        )
    }

    /// 任务详情（多行）。
    private static func taskDetail(_ task: TaskItem, project: Project, strings s: CLIStrings) -> String {
        var lines: [String] = []
        lines.append(s.detailTask + task.title)
        lines.append(s.detailID + task.id.uuidString)
        lines.append(s.detailKind + s.kindLabel(task.kind))
        lines.append(s.detailStatus + s.statusLabel(task.status))
        // 取消原因紧跟状态（v0.16）：有值才输出，与其它可选行同口径。
        if let reason = task.cancelReason { lines.append(s.cancelReasonLine(reason)) }
        if let assignee = task.assignee, !assignee.isEmpty { lines.append(s.detailAssignee + assignee) }
        if task.priority != .normal { lines.append(s.detailPriority + s.priorityLabel(task.priority)) }
        if let effort = task.effortHours { lines.append(s.detailEffort + s.hoursUnit(formatNumber(effort))) }
        if let duration = task.durationDays { lines.append(s.detailDuration + s.daysUnit(formatNumber(duration))) }
        if !task.tags.isEmpty { lines.append(s.detailTags + task.tags.map { "#\($0)" }.joined(separator: " ")) }
        lines.append(s.detailProgress + "\(Int(task.progress * 100))%")
        // 实际时间（07-actual-dates §8）：有值才输出，缺值不占行（与其它可选行同口径）。
        if let actualStart = task.actualStart { lines.append(s.actualStart(formatDate(actualStart))) }
        if let actualFinish = task.completedAt { lines.append(s.actualFinish(formatDate(actualFinish))) }
        if !task.dependencies.isEmpty {
            lines.append(s.detailDependencies)
            for dep in task.dependencies {
                let title = project.tasks.first { $0.id == dep.predecessorID }?.title ?? s.unknownTask
                lines.append(s.dependencyRow(
                    title: title,
                    type: dep.type.rawValue.uppercased(),
                    lag: dep.lagDays != 0 ? formatNumber(dep.lagDays) : nil
                ))
            }
        }
        if !task.assignments.isEmpty {
            lines.append(s.detailAssignments)
            for assignment in task.assignments {
                let name = project.resources.first { $0.id == assignment.resourceID }?.name ?? s.unknownResource
                lines.append(s.assignmentRow(name: name, units: formatNumber(assignment.units)))
            }
        }
        if !task.notes.isEmpty { lines.append(s.detailNotes + task.notes) }
        return lines.joined(separator: "\n")
    }

    /// `task get` 的基线段（§8）：所选基线名 + 基线起止 + 计划偏差 + 实际偏差。
    ///
    /// CLI 没有「当前基线」视图状态（那是 App 的 UserDefaults），固定比较**最新**一条基线；
    /// 项目还没有基线时整段不输出——无基线可比较不是「偏差为 0」。
    private static func baselineSection(
        for taskID: UUID,
        in session: KaidoSession,
        strings s: CLIStrings
    ) -> [String]? {
        guard let report = try? session.baselineVariance() else { return nil }
        guard let variance = report.variance(for: taskID) else { return nil }
        var lines = [s.detailBaseline(name: report.baselineName, id: report.baselineID.uuidString)]
        lines.append(s.detailBaselineSpan(
            start: variance.baselineStart.map(formatDate) ?? s.varianceEmpty,
            finish: variance.baselineFinish.map(formatDate) ?? s.varianceEmpty
        ))
        lines.append(s.detailPlanVariance(
            start: s.varianceDays(variance.planStartVariance),
            finish: s.varianceDays(variance.planFinishVariance)
        ))
        lines.append(s.detailActualVariance(
            start: s.varianceDays(variance.actualStartVariance),
            finish: s.varianceDays(variance.actualFinishVariance)
        ))
        // 基线之后新增：条目缺失，四行都只能是「—」，额外说明原因（§5）。
        if !variance.hasBaseline { lines.append(s.baselineAddedAfterSnapshot) }
        return lines
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// ISO8601 日期选项解析（--start/--end 等）。
    /// 接受 ISO8601 完整形式或 YYYY-MM-DD（按 UTC 零点解释）。
    private static func optionalISO(_ raw: String?, field: String, strings: CLIStrings) throws -> Date? {
        guard let raw else { return nil }
        guard let date = CLIEnums.parseDate(raw) else {
            throw UsageError(message: strings.invalidDateOption(field: field, raw: raw))
        }
        return date
    }

    private static func errorMessage(_ error: Error) -> String {
        String(describing: error)
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

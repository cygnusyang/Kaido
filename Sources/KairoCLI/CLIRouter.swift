import Foundation
import KairoCore
import KairoCommands

/// CLI 用法错误：参数缺失 / 取值非法 → 退出码 2（区别于运行时错误的 1）。
struct UsageError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
}

/// `status batch` 的 JSON 条目：taskID 接受完整 UUID 或唯一前缀。
private struct StatusBatchItem: Decodable {
    let taskID: String
    let status: String?
    let progress: Double?
}

/// CLI 路由（ADR-005 契约同源）：子命令解析 → KairoSession 操作 → 输出呈现。
/// 每次调用创建独立 KairoSession；task/wbs 命令按「打开 --file → 操作 → 保存」模式执行。
struct CLIRouter {
    /// 程序入口包装：成功 0 / 运行时错误 1 / 用法错误 2。
    static func run(arguments: [String]) -> Int32 {
        do {
            try execute(arguments: arguments)
            return 0
        } catch let error as UsageError {
            stderr("用法错误：\(error.message)")
            return 2
        } catch let error as CLIError {
            // 枚举值/相关性规格非法同属用法错误（退出码 2）。
            stderr("用法错误：\(error)")
            return 2
        } catch {
            stderr("错误：\(errorMessage(error))")
            return 1
        }
    }

    /// 解析并执行单条命令（测试可直接调用；抛出错误而非退出进程）。
    static func execute(arguments: [String]) throws {
        let (group, rest) = subcommand(arguments, from: "kairo")
        // 组级命令直接带选项（如 `kairo violations --file x.kairo`）：下一 token 以 -- 开头即视为无子命令。
        let (command, args): (String, [String])
        if let first = rest.first, first.hasPrefix("--") {
            command = ""
            args = rest
        } else {
            (command, args) = subcommand(rest, from: group)
        }
        let options = Options(args)
        switch (group, command) {
        case ("project", "create"): try projectCreate(options)
        case ("project", "open"): try projectOpen(options)
        case ("project", "save"): try projectSave(options)
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
        default:
            let label = group.isEmpty ? "(空)" : group
            let sub = command.isEmpty ? "(空)" : command
            throw UsageError(message: "未知命令：\(label) \(sub)")
        }
    }

    // MARK: - project

    /// kairo project create <标题> [--file <路径>]：新建并保存到文件（默认 ./project.kairo）。
    private static func projectCreate(_ o: Options) throws {
        let title = try o.operand(0, name: "标题")
        let start = try optionalISO(o.value(for: "--start"), name: "项目开始")
        let end = try optionalISO(o.value(for: "--end"), name: "项目结束")
        let session = KairoSession()
        let meta = try session.createProject(title: title, projectStart: start, projectEnd: end)
        let url = fileURL(o.value(for: "--file"))
        _ = try session.saveProject(to: url)
        print("已创建项目：\(shortID(meta.id))「\(meta.title)」")
        print("已保存：\(url.path)")
    }

    /// kairo project open <路径>：打开并打印项目元数据。
    private static func projectOpen(_ o: Options) throws {
        let path = try o.operand(0, name: "文件路径")
        let session = KairoSession()
        let meta = try session.openProject(at: URL(fileURLWithPath: path))
        print("项目：\(meta.title)")
        print("项目ID：\(meta.id.uuidString)")
        print("任务数：\(session.project?.tasks.count ?? 0)")
    }

    /// kairo project save [--file <路径>]：重新保存（默认 ./project.kairo），验证往返。
    private static func projectSave(_ o: Options) throws {
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let meta = try session.saveProject()
        print("已保存：\(session.projectURL?.path ?? "")")
        print("更新于：\(ISO8601DateFormatter().string(from: meta.updatedAt))")
    }

    // MARK: - task

    /// kairo task add <标题> [--kind/--parent/--effort/--duration/--notes/--priority/--status/--tags/--dep/--constraint/--policy/--assignee ...]。
    private static func taskAdd(_ o: Options) throws {
        // 先解析全部参数（用法错误在 IO 前抛出），再打开文件操作。
        let title = try o.operand(0, name: "标题")
        let kind = try CLIEnums.kind(o.value(for: "--kind")) ?? .task
        let rawParent = o.value(for: "--parent")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes") ?? ""
        let priority = try CLIEnums.priority(o.value(for: "--priority")) ?? .normal
        let status = try CLIEnums.status(o.value(for: "--status")) ?? .pending
        let tags = splitTags(o.value(for: "--tags"))
        let depSpecs = try o.values(for: "--dep").map { try CLIEnums.dependency($0) }
        let assignSpecs = try o.values(for: "--assign").map { try CLIEnums.assignment($0) }
        let constraint = try CLIEnums.constraint(o.value(for: "--constraint"))
        let policy = try CLIEnums.schedulingPolicy(o.value(for: "--policy")) ?? .asap
        // 负责人（US-E1-02）：不传或空串 = nil（默认无负责人）；否则设置。
        let assignee = o.value(for: "--assignee").flatMap { $0.isEmpty ? nil : $0 }

        let session = KairoSession()
        try openForEdit(session, o)
        let parentID = try rawParent.map { try resolveTaskID($0, in: session) }
        let deps = try depSpecs.map { try $0.resolve(in: session) }
        let assignments = try assignSpecs.map { try $0.resolve(in: session) }
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
        print("已创建任务：\(shortID(id)) \(title)")
    }

    /// kairo task list [--parent <UUID>] [--filter <文本>] [--json] [--file <路径>]。
    private static func taskList(_ o: Options) throws {
        try o.rejectUnknown(["--parent", "--filter", "--json", "--file"])
        let rawParent = o.value(for: "--parent")
        let filter = o.value(for: "--filter") ?? ""
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let parentID = try rawParent.map { try resolveTaskID($0, in: session) }
        let tasks = try session.listTasks(parentID: parentID, filter: filter)
        if o.flag("--json") {
            print(try CLIOutput.taskListJSON(tasks))
        } else {
            for task in tasks { print(taskListLine(task)) }
        }
    }

    /// kairo task get <ID> [--file <路径>]：多行详情。
    private static func taskGet(_ o: Options) throws {
        let rawID = try o.operand(0, name: "任务 ID")
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        guard let project = session.project else { return }
        let id = try resolveTaskID(rawID, in: session)
        let task = try session.getTask(id: id)
        print(taskDetail(task, project: project))
    }

    /// kairo task update <ID> [--title/--kind/--parent/--effort/--duration/--notes/--priority/--status/--progress/--tags/--assignee]。
    private static func taskUpdate(_ o: Options) throws {
        let depSpecs = try o.values(for: "--dep").map { try CLIEnums.dependency($0) }
        let assignSpecs = try o.values(for: "--assign").map { try CLIEnums.assignment($0) }
        let rawID = try o.operand(0, name: "任务 ID")
        let title = o.value(for: "--title")
        let kind = try CLIEnums.kind(o.value(for: "--kind"))
        let rawParent = o.value(for: "--parent")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes")
        let priority = try CLIEnums.priority(o.value(for: "--priority"))
        let status = try CLIEnums.status(o.value(for: "--status"))
        let progress = o.double(for: "--progress")
        let tags = o.value(for: "--tags").map(splitTags)
        let constraint = try CLIEnums.constraint(o.value(for: "--constraint"))
        let policy = try CLIEnums.schedulingPolicy(o.value(for: "--policy"))
        // 负责人（US-E1-02）：nil = 不改；空串 = 清空（清空在共享层 updateTask 统一处理）。
        let assignee = o.value(for: "--assignee")
        try o.rejectUnknown([
            "--title", "--kind", "--parent", "--effort", "--duration", "--notes",
            "--priority", "--status", "--progress", "--tags", "--dep",
            "--constraint", "--policy", "--assign", "--assignee", "--file",
        ])

        let session = KairoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session)
        let parentID = try rawParent.map { try resolveTaskID($0, in: session) }
        let deps = try depSpecs.map { try $0.resolve(in: session) }
        let assignments = try assignSpecs.map { try $0.resolve(in: session) }
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
        print("已更新任务：\(shortID(task.id)) \(task.title)")
    }

    /// kairo task delete <ID> [--file <路径>]：删除任务及其全部子任务。
    private static func taskDelete(_ o: Options) throws {
        let rawID = try o.operand(0, name: "任务 ID")
        let session = KairoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session)
        let removed = try session.deleteTaskCascade(id: id)
        try session.saveProject()
        if removed > 1 {
            print("已删除任务及其 \(removed - 1) 个子任务：\(shortID(id))")
        } else {
            print("已删除任务：\(shortID(id))")
        }
    }

    // MARK: - wbs

    /// kairo wbs import <JSON 文件> [--parent <UUID>] [--file <路径>]。
    private static func wbsImport(_ o: Options) throws {
        let jsonPath = try o.operand(0, name: "JSON 文件")
        let rawParent = o.value(for: "--parent")
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let parentID = try rawParent.map { try resolveTaskID($0, in: session) }
        let nodes: [WBSNode]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            nodes = try JSONDecoder().decode([WBSNode].self, from: data)
        } catch {
            throw SessionError(
                code: .fileUnreadable,
                message: "无法解析 WBS JSON：\(jsonPath)"
            )
        }
        let result = try session.importWBS(nodes: nodes, parentID: parentID)
        try session.saveProject()
        print("已导入 \(result.total) 个任务")
        for id in result.rootIDs {
            let task = try session.getTask(id: id)
            print("  \(shortID(id)) \(task.title)")
        }
    }

    // MARK: - schedule（US-E2-02 / US-E2-03）

    /// kairo schedule compute [--start <ISO>] [--end <ISO>] [--file <路径>]。
    private static func scheduleCompute(_ o: Options) throws {
        let start = try optionalISO(o.value(for: "--start"), name: "项目开始")
        let end = try optionalISO(o.value(for: "--end"), name: "项目结束")
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let result = try session.computeSchedule(projectStart: start, projectEnd: end)
        let byID = session.project?.tasksByID ?? [:]
        print("已计算排期：\(result.tasks.count) 个任务")
        for t in result.tasks {
            let task = byID[t.taskID]
            let policy = task?.schedulingPolicy ?? .asap
            print("  \(shortID(t.taskID)) \(task?.title ?? "未知任务")  \(formatDate(t.scheduledStart)) → \(formatDate(t.scheduledFinish))（\(formatNumber(t.durationDays)) 天，\(policy == .asap ? "ASAP" : "ALAP")）")
        }
    }

    /// kairo schedule path [--limit <天>] [--file <路径>]：重要路径与宽延。
    private static func schedulePath(_ o: Options) throws {
        let limit = o.double(for: "--limit")
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let entries = try session.criticalPath(slackLimit: limit)
        let byID = session.project?.tasksByID ?? [:]
        let criticalCount = entries.filter(\.isCritical).count
        print("重要路径：\(criticalCount) 个任务（宽延限制 \(formatNumber(limit ?? 0)) 天）")
        for e in entries {
            let mark = e.isCritical ? " *" : ""
            print("  \(shortID(e.taskID)) \(byID[e.taskID]?.title ?? "未知任务")\(mark)  总宽延 \(formatNumber(e.totalSlackDays)) 天 / 自由宽延 \(formatNumber(e.freeSlackDays)) 天")
        }
    }

    // MARK: - violations（US-E2-05）

    /// kairo violations [--file <路径>]。
    private static func violations(_ o: Options) throws {
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let vs = try session.violations()
        if vs.isEmpty {
            print("无违例")
            return
        }
        print("违例：\(vs.count) 条")
        for v in vs {
            let sev = v.severity == .error ? "错误" : "警告"
            print("  [\(sev)] \(v.code)：\(v.message)")
        }
    }

    // MARK: - status（US-E3-01 / US-E3-02）

    /// kairo status update <ID> [--status] [--progress] [--file <路径>]。
    private static func statusUpdate(_ o: Options) throws {
        let rawID = try o.operand(0, name: "任务 ID")
        let status = try CLIEnums.status(o.value(for: "--status"))
        let progress = o.double(for: "--progress")
        let session = KairoSession()
        try openForEdit(session, o)
        let id = try resolveTaskID(rawID, in: session)
        let task = try session.statusUpdate(id: id, status: status, progress: progress)
        try session.saveProject()
        print("已回写：\(shortID(task.id)) \(task.title)（\(statusLabel(task.status))，进度 \(Int(task.progress * 100))%）")
        if let completed = task.completedAt {
            print("完成于：\(formatDate(completed))")
        }
        let group = try session.groupProgress(id: id)
        print("完成度聚合：\(Int(group * 100))%")
    }

    /// kairo status batch <JSON 文件> [--file <路径>]：批量回写，JSON 为
    /// [{"taskID":"UUID 或前缀","status":"done","progress":1}]，逐条返回成功/失败。
    private static func statusBatch(_ o: Options) throws {
        let jsonPath = try o.operand(0, name: "JSON 文件")
        let session = KairoSession()
        try openForEdit(session, o)
        let items: [StatusBatchItem]
        do {
            let data = try Data(contentsOf: URL(fileURLWithPath: jsonPath))
            items = try JSONDecoder().decode([StatusBatchItem].self, from: data)
        } catch {
            throw SessionError(code: .fileUnreadable, message: "无法解析批量回写 JSON：\(jsonPath)")
        }

        // 逐条解析任务标识；无法解析的条目记为失败，不中断其余条目。
        struct Pending {
            let index: Int
            let input: KairoSession.StatusUpdateInput?
            let label: String
            let error: String?
        }
        var pending: [Pending] = []
        for (index, item) in items.enumerated() {
            let status = try CLIEnums.status(item.status)
            do {
                let id = try resolveTaskID(item.taskID, in: session)
                pending.append(Pending(
                    index: index,
                    input: .init(taskID: id, status: status, progress: item.progress),
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

        var entriesByIndex: [Int: KairoSession.StatusBatchResult.Entry] = [:]
        let resolvedIndices = pending.filter { $0.input != nil }.map(\.index)
        for (index, entry) in zip(resolvedIndices, result.entries) {
            entriesByIndex[index] = entry
        }

        var failed = 0
        for item in pending {
            guard let entry = entriesByIndex[item.index] else {
                failed += 1
                print("失败：\(item.label) \(item.error ?? "未知错误")")
                continue
            }
            if entry.ok, let task = entry.task {
                print("已回写：\(shortID(task.id)) \(task.title)（\(statusLabel(task.status))，进度 \(Int(task.progress * 100))%）")
            } else {
                failed += 1
                print("失败：\(shortID(entry.taskID)) \(entry.error ?? "未知错误")")
            }
        }
        print("批量结果：成功 \(items.count - failed) 条，失败 \(failed) 条")
        if failed > 0 {
            throw SessionError(code: .invalidArgument, message: "批量回写存在 \(failed) 条失败")
        }
    }

    // MARK: - resource（F-23-01 / ADR-009）

    /// kairo resource add <名称> [--type person|equipment|material|group] [--units] [--efficiency] [--file <路径>]。
    private static func resourceAdd(_ o: Options) throws {
        let name = try o.operand(0, name: "资源名称")
        let kind = try CLIEnums.resourceKind(o.value(for: "--type")) ?? .person
        let units = o.double(for: "--units") ?? 1
        let efficiency = o.double(for: "--efficiency") ?? 1
        let session = KairoSession()
        try openForEdit(session, o)
        let id = try session.resourceAdd(name: name, kind: kind, units: units, efficiency: efficiency)
        try session.saveProject()
        print("已添加资源：\(shortID(id)) \(name)（\(resourceKindLabel(kind))，单位 \(formatNumber(units))，效率 \(formatNumber(efficiency))）")
    }

    /// kairo resource list [--file <路径>]。
    private static func resourceList(_ o: Options) throws {
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let resources = try session.resourceList()
        for r in resources {
            print("\(shortID(r.id)) \(r.name)（\(resourceKindLabel(r.kind))，单位 \(formatNumber(r.units))，效率 \(formatNumber(r.efficiency))）")
        }
    }

    // MARK: - 帮助

    /// 打开 --file（默认 ./project.kairo）。task/wbs 写命令统一入口。
    private static func openForEdit(_ session: KairoSession, _ o: Options) throws {
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
    }

    private static func fileURL(_ raw: String?) -> URL {
        URL(fileURLWithPath: raw ?? "project.kairo")
    }

    /// 解析任务标识：接受完整 UUID 或唯一前缀（≥4 位），返回完整 UUID。--parent 同此规则。
    static func resolveTaskID(_ raw: String, in session: KairoSession) throws -> UUID {
        if let full = UUID(uuidString: raw) { return full }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else {
            throw UsageError(message: "任务 ID 前缀至少 4 位：\(raw)")
        }
        let candidates = (session.project?.tasks ?? []).map(\.id).filter {
            $0.uuidString.lowercased().hasPrefix(prefix)
        }
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw UsageError(message: "找不到任务：\(raw)")
        default: throw UsageError(message: "任务 ID 前缀不唯一（\(candidates.count) 个匹配）：\(raw)")
        }
    }

    /// 解析资源标识：接受完整 UUID 或唯一前缀（≥4 位）。
    static func resolveResourceID(_ raw: String, in session: KairoSession) throws -> UUID {
        if let full = UUID(uuidString: raw) { return full }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else {
            throw UsageError(message: "资源 ID 前缀至少 4 位：\(raw)")
        }
        let candidates = (session.project?.resources ?? []).map(\.id).filter {
            $0.uuidString.lowercased().hasPrefix(prefix)
        }
        switch candidates.count {
        case 1: return candidates[0]
        case 0: throw UsageError(message: "找不到资源：\(raw)")
        default: throw UsageError(message: "资源 ID 前缀不唯一（\(candidates.count) 个匹配）：\(raw)")
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

    private static func taskListLine(_ task: TaskItem) -> String {
        var parts: [String] = [shortID(task.id), task.title]
        if task.kind != .task { parts.append("[\(kindLabel(task.kind))]") }
        var extras: [String] = [statusLabel(task.status)]
        if task.priority != .normal { extras.append(priorityLabel(task.priority)) }
        if let effort = task.effortHours { extras.append("投入 \(formatNumber(effort)) 小时") }
        if let duration = task.durationDays { extras.append("持续 \(formatNumber(duration)) 天") }
        if !task.tags.isEmpty { extras.append(task.tags.map { "#\($0)" }.joined(separator: " ")) }
        parts.append(extras.joined(separator: " · "))
        return parts.joined(separator: " ")
    }

    private static func taskDetail(_ task: TaskItem, project: Project) -> String {
        var lines: [String] = []
        lines.append("任务：\(task.title)")
        lines.append("ID：\(task.id.uuidString)")
        lines.append("类型：\(kindLabel(task.kind))")
        lines.append("状态：\(statusLabel(task.status))")
        if let assignee = task.assignee, !assignee.isEmpty { lines.append("负责人：\(assignee)") }
        if task.priority != .normal { lines.append("优先级：\(priorityLabel(task.priority))") }
        if let effort = task.effortHours { lines.append("投入：\(formatNumber(effort)) 小时") }
        if let duration = task.durationDays { lines.append("持续：\(formatNumber(duration)) 天") }
        if !task.tags.isEmpty { lines.append("标签：\(task.tags.map { "#\($0)" }.joined(separator: " "))") }
        lines.append("进度：\(Int(task.progress * 100))%")
        if !task.dependencies.isEmpty {
            lines.append("相关性：")
            for dep in task.dependencies {
                let title = project.tasks.first { $0.id == dep.predecessorID }?.title ?? "未知任务"
                var text = "  - \(title)（\(dep.type.rawValue.uppercased())）"
                if dep.lagDays != 0 { text += " 前导 \(formatNumber(dep.lagDays)) 天" }
                lines.append(text)
            }
        }
        if !task.assignments.isEmpty {
            lines.append("分配：")
            for assignment in task.assignments {
                let name = project.resources.first { $0.id == assignment.resourceID }?.name ?? "未知资源"
                lines.append("  - \(name)（\(formatNumber(assignment.units)) 单位）")
            }
        }
        if !task.notes.isEmpty { lines.append("备注：\(task.notes)") }
        return lines.joined(separator: "\n")
    }

    private static func kindLabel(_ kind: TaskKind) -> String {
        switch kind {
        case .task: return "任务"
        case .group: return "群组"
        case .milestone: return "里程碑"
        }
    }

    private static func statusLabel(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return "待办"
        case .inProgress: return "进行中"
        case .done: return "已完成"
        case .blocked: return "阻塞"
        }
    }

    private static func priorityLabel(_ priority: TaskPriority) -> String {
        switch priority {
        case .low: return "低"
        case .normal: return "普通"
        case .high: return "高"
        case .critical: return "紧急"
        }
    }

    private static func formatNumber(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    private static func formatDate(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }

    /// ISO8601 日期选项解析（--start/--end 等）。
    /// 接受 ISO8601 完整形式或 YYYY-MM-DD（按 UTC 零点解释）。
    private static func optionalISO(_ raw: String?, name: String) throws -> Date? {
        guard let raw else { return nil }
        guard let date = CLIEnums.parseDate(raw) else {
            throw UsageError(message: "无效的\(name)日期：\(raw)（ISO8601 或 YYYY-MM-DD）")
        }
        return date
    }

    private static func resourceKindLabel(_ kind: ResourceKind) -> String {
        switch kind {
        case .person: return "人员"
        case .equipment: return "设备"
        case .material: return "素材"
        case .group: return "群组"
        }
    }

    private static func errorMessage(_ error: Error) -> String {
        String(describing: error)
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

import Foundation
import KairoCore
import KairoCommands

/// CLI 用法错误：参数缺失 / 取值非法 → 退出码 2（区别于运行时错误的 1）。
struct UsageError: Error, CustomStringConvertible {
    var message: String
    var description: String { message }
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
        } catch {
            stderr("错误：\(errorMessage(error))")
            return 1
        }
    }

    /// 解析并执行单条命令（测试可直接调用；抛出错误而非退出进程）。
    static func execute(arguments: [String]) throws {
        let (group, rest) = subcommand(arguments, from: "kairo")
        let (command, args) = subcommand(rest, from: group)
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
        let session = KairoSession()
        let meta = try session.createProject(title: title)
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

    /// kairo task add <标题> [--kind/--parent/--effort/--duration/--notes/--priority/--status/--tags/--dep ...]。
    private static func taskAdd(_ o: Options) throws {
        // 先解析全部参数（用法错误在 IO 前抛出），再打开文件操作。
        let title = try o.operand(0, name: "标题")
        let kind = try CLIEnums.kind(o.value(for: "--kind")) ?? .task
        let parentID = try optionalUUID(o.value(for: "--parent"), name: "父任务")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes") ?? ""
        let priority = try CLIEnums.priority(o.value(for: "--priority")) ?? .normal
        let status = try CLIEnums.status(o.value(for: "--status")) ?? .pending
        let tags = splitTags(o.value(for: "--tags"))
        let deps = try o.values(for: "--dep").map { try CLIEnums.dependency($0) }

        let session = KairoSession()
        try openForEdit(session, o)
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
            dependencies: deps
        )
        try session.saveProject()
        print("已创建任务：\(shortID(id)) \(title)")
    }

    /// kairo task list [--parent <UUID>] [--filter <文本>] [--file <路径>]。
    private static func taskList(_ o: Options) throws {
        let parentID = try optionalUUID(o.value(for: "--parent"), name: "父任务")
        let filter = o.value(for: "--filter") ?? ""
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        let tasks = try session.listTasks(parentID: parentID, filter: filter)
        for task in tasks { print(taskListLine(task)) }
    }

    /// kairo task get <ID> [--file <路径>]：多行详情。
    private static func taskGet(_ o: Options) throws {
        let id = try requireUUID(o.operand(0, name: "任务 ID"))
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
        guard let project = session.project else { return }
        let task = try session.getTask(id: id)
        print(taskDetail(task, project: project))
    }

    /// kairo task update <ID> [--title/--kind/--parent/--effort/--duration/--notes/--priority/--status/--progress/--tags]。
    private static func taskUpdate(_ o: Options) throws {
        guard o.values(for: "--dep").isEmpty else {
            throw UsageError(message: "task update 暂不支持 --dep（相关性当前契约中不可更新）")
        }
        let id = try requireUUID(o.operand(0, name: "任务 ID"))
        let title = o.value(for: "--title")
        let kind = try CLIEnums.kind(o.value(for: "--kind"))
        let parentID = try optionalUUID(o.value(for: "--parent"), name: "父任务")
        let effort = o.double(for: "--effort")
        let duration = o.double(for: "--duration")
        let notes = o.value(for: "--notes")
        let priority = try CLIEnums.priority(o.value(for: "--priority"))
        let status = try CLIEnums.status(o.value(for: "--status"))
        let progress = o.double(for: "--progress")
        let tags = o.value(for: "--tags").map(splitTags)

        let session = KairoSession()
        try openForEdit(session, o)
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
            tags: tags
        )
        try session.saveProject()
        print("已更新任务：\(shortID(task.id)) \(task.title)")
    }

    /// kairo task delete <ID> [--file <路径>]。
    private static func taskDelete(_ o: Options) throws {
        let id = try requireUUID(o.operand(0, name: "任务 ID"))
        let session = KairoSession()
        try openForEdit(session, o)
        _ = try session.deleteTask(id: id)
        try session.saveProject()
        print("已删除任务：\(shortID(id))")
    }

    // MARK: - wbs

    /// kairo wbs import <JSON 文件> [--parent <UUID>] [--file <路径>]。
    private static func wbsImport(_ o: Options) throws {
        let jsonPath = try o.operand(0, name: "JSON 文件")
        let parentID = try optionalUUID(o.value(for: "--parent"), name: "父任务")
        let session = KairoSession()
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
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

    // MARK: - 帮助

    /// 打开 --file（默认 ./project.kairo）。task/wbs 写命令统一入口。
    private static func openForEdit(_ session: KairoSession, _ o: Options) throws {
        _ = try session.openProject(at: fileURL(o.value(for: "--file")))
    }

    private static func fileURL(_ raw: String?) -> URL {
        URL(fileURLWithPath: raw ?? "project.kairo")
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

    private static func errorMessage(_ error: Error) -> String {
        String(describing: error)
    }

    private static func stderr(_ text: String) {
        FileHandle.standardError.write(Data((text + "\n").utf8))
    }
}

import Foundation
import KairoCore

/// 命令层统一错误（接口层结构化错误契约；MCP 工具与 CLI 共用）。
public struct SessionError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Equatable, Sendable {
        case projectNotOpen = "project_not_open"
        case taskNotFound = "task_not_found"
        case invalidArgument = "invalid_argument"
        case fileUnreadable = "file_unreadable"
        case unsupportedFormat = "unsupported_format"
    }

    public var code: Code
    public var message: String
    public var taskID: UUID?

    public init(code: Code, message: String, taskID: UUID? = nil) {
        self.code = code
        self.message = message
        self.taskID = taskID
    }

    public var description: String { message }
}

/// MCP 与 CLI 共享的命令实现层（ADR-005 契约同源）。
/// 持有当前项目与会话状态；project / task / wbs 操作全部经由此处，
/// 两个接口层只做参数路由与输出呈现。
public final class KairoSession {
    public private(set) var project: Project?
    public private(set) var projectURL: URL?

    public init() {}

    // MARK: - 项目

    /// 新建项目（US-E1-01）：返回项目元数据，含项目 ID。
    @discardableResult
    public func createProject(title: String) throws -> ProjectMetadata {
        let project = Project()
        project.metadata.title = title
        project.metadata.updatedAt = Date()
        self.project = project
        projectURL = nil
        return project.metadata
    }

    /// 打开 .kairo 项目文件。
    @discardableResult
    public func openProject(at url: URL) throws -> ProjectMetadata {
        let project: Project
        do {
            project = try KairoFile.load(from: url)
        } catch let error as KairoFileError {
            throw SessionError(code: .unsupportedFormat, message: error.description)
        } catch {
            throw SessionError(
                code: .fileUnreadable,
                message: "无法读取项目文件：\(url.lastPathComponent)"
            )
        }
        self.project = project
        projectURL = url
        return project.metadata
    }

    /// 记录项目保存路径（应用层另存为完成后回填，供后续直存）。
    public func setProjectURL(_ url: URL) {
        projectURL = url
    }

    /// 保存项目；未指定路径时使用已打开项目的路径。
    @discardableResult
    public func saveProject(to url: URL? = nil) throws -> ProjectMetadata {
        guard let project else { throw notOpen() }
        let target = url ?? projectURL
        guard let target else {
            throw SessionError(
                code: .invalidArgument,
                message: "未指定保存路径（请提供 --path 或先打开项目）"
            )
        }
        project.metadata.updatedAt = Date()
        do {
            try KairoFile.save(project, to: target)
        } catch {
            throw SessionError(code: .fileUnreadable, message: "保存失败：\(error.localizedDescription)")
        }
        projectURL = target
        return project.metadata
    }

    // MARK: - 任务 CRUD

    @discardableResult
    public func addTask(
        title: String,
        kind: TaskKind = .task,
        parentID: UUID? = nil,
        effortHours: Double? = nil,
        durationDays: Double? = nil,
        notes: String = "",
        priority: TaskPriority = .normal,
        status: TaskStatus = .pending,
        tags: [String] = [],
        dependencies: [TaskDependency] = []
    ) throws -> UUID {
        guard let project else { throw notOpen() }
        if let parentID, project.tasksByID[parentID] == nil {
            throw SessionError(code: .invalidArgument, message: "父任务不存在", taskID: parentID)
        }
        let task = TaskItem(
            title: title,
            notes: notes,
            priority: priority,
            status: status,
            tags: tags,
            kind: kind,
            parentID: parentID,
            effortHours: effortHours,
            durationDays: durationDays,
            dependencies: dependencies
        )
        project.add(task)
        return task.id
    }

    public func listTasks(parentID: UUID? = nil, filter: String = "") throws -> [TaskItem] {
        guard let project else { throw notOpen() }
        var tasks = project.tasks
        if let parentID {
            tasks = tasks.filter { $0.parentID == parentID }
        }
        if !filter.isEmpty {
            tasks = AIFilterTranslator.apply(clauses: AIFilterTranslator.translate(filter), to: tasks)
        }
        return tasks
    }

    public func getTask(id: UUID) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let task = project.tasksByID[id] else {
            throw SessionError(code: .taskNotFound, message: "任务不存在", taskID: id)
        }
        return task
    }

    @discardableResult
    public func updateTask(
        id: UUID,
        title: String? = nil,
        kind: TaskKind? = nil,
        parentID: UUID? = nil,
        effortHours: Double? = nil,
        durationDays: Double? = nil,
        notes: String? = nil,
        priority: TaskPriority? = nil,
        status: TaskStatus? = nil,
        progress: Double? = nil,
        tags: [String]? = nil
    ) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, message: "任务不存在", taskID: id)
        }
        var task = project.tasks[index]
        if let title { task.title = title }
        if let kind { task.kind = kind }
        if let parentID { task.parentID = parentID }
        if let effortHours { task.effortHours = effortHours }
        if let durationDays { task.durationDays = durationDays }
        if let notes { task.notes = notes }
        if let priority { task.priority = priority }
        if let status { task.status = status }
        if let progress { task.progress = min(max(progress, 0), 1) }
        if let tags { task.tags = tags }
        project.tasks[index] = task
        return task
    }

    @discardableResult
    public func deleteTask(id: UUID) throws -> Bool {
        guard let project else { throw notOpen() }
        guard project.tasksByID[id] != nil else {
            throw SessionError(code: .taskNotFound, message: "任务不存在", taskID: id)
        }
        project.remove(id: id)
        // 指向被删任务的相关性一并移除（US-E1-02 验收）。
        for (index, task) in project.tasks.enumerated() where task.dependencies.contains(where: { $0.predecessorID == id }) {
            var updated = task
            updated.dependencies.removeAll { $0.predecessorID == id }
            project.tasks[index] = updated
        }
        return true
    }

    // MARK: - WBS 批量导入（US-E1-04）

    /// 把嵌套标题/kind/子节点树展开为 parentID 结构。
    @discardableResult
    public func importWBS(nodes: [WBSNode], parentID: UUID? = nil) throws -> WBSImportResult {
        guard let project else { throw notOpen() }
        if let parentID, project.tasksByID[parentID] == nil {
            throw SessionError(code: .invalidArgument, message: "父任务不存在", taskID: parentID)
        }
        var rootIDs: [UUID] = []
        var idByTitle: [String: UUID] = [:]
        var warnings: [String] = []

        func walk(_ node: WBSNode, _ parent: UUID?) {
            let id = UUID()
            let kind = node.kind ?? (node.children.isEmpty ? .task : .group)
            var effort = node.effortHours
            var duration = node.durationDays
            // 里程碑：投入/持续时间恒为 0（US-E1-03）。
            if kind == .milestone {
                effort = 0
                duration = 0
            }
            // 显式传入 id：与 rootIDs / idByTitle 记录保持一致（否则返回的 ID 与任务实际 ID 不符）。
            let task = TaskItem(
                id: id,
                title: node.title,
                kind: kind,
                parentID: parent,
                effortHours: effort,
                durationDays: duration
            )
            project.add(task)
            if parent == nil { rootIDs.append(id) }
            idByTitle[node.title] = id
            for child in node.children { walk(child, id) }
        }
        for node in nodes { walk(node, parentID) }

        return WBSImportResult(
            rootIDs: rootIDs,
            idByTitle: idByTitle,
            total: idByTitle.count,
            warnings: warnings
        )
    }

    // MARK: - 私有

    private func notOpen() -> SessionError {
        SessionError(code: .projectNotOpen, message: "未打开项目（请先 project open / project create）")
    }
}

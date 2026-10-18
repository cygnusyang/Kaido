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

    // MARK: - 排期与违例查询（US-E2-02 / US-E2-03 / US-E2-05）

    /// 最近一次排期结果（schedule_compute 缓存；critical_path / violations 复用）。
    public private(set) var lastSchedule: ScheduleResult?

    /// 计算排期并缓存结果（ADR-007：经 KairoCore 纯函数，命令层不重复实现）。
    @discardableResult
    public func computeSchedule(projectStart: Date? = nil, projectEnd: Date? = nil) throws -> ScheduleResult {
        guard let project else { throw notOpen() }
        let result = ScheduleEngine.compute(
            tasks: project.tasks,
            resources: project.resources,
            projectStart: projectStart,
            projectEnd: projectEnd
        )
        lastSchedule = result
        return result
    }

    /// 未排期时先计算一次（缓存复用）。
    private func scheduleOrCompute() throws -> ScheduleResult {
        if let lastSchedule { return lastSchedule }
        return try computeSchedule()
    }

    /// 违例列表（US-E2-05）：未排期时先按当前项目计算。
    public func violations() throws -> [Violation] {
        guard let project else { throw notOpen() }
        let result = try scheduleOrCompute()
        return ViolationEngine.check(result: result, tasks: project.tasks)
    }

    /// 重要路径与宽延（US-E2-03 / F-21-01）：总宽延 ≤ slackLimit 的任务集。
    public func criticalPath(slackLimit: Double? = nil) throws -> [CriticalPathEntry] {
        let result = try scheduleOrCompute()
        return CriticalPathEngine.compute(result: result, slackLimit: slackLimit)
    }

    // MARK: - 状态回写（US-E3-01 / US-E3-02）

    /// 单任务状态/进度回写：状态置 done 时记录完成时间并把进度置 1；
    /// 进度超出 0...1 拒绝并返回参数错误（US-E3-01 验收）。
    @discardableResult
    public func statusUpdate(id: UUID, status: TaskStatus? = nil, progress: Double? = nil) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, message: "任务不存在", taskID: id)
        }
        if let progress, !(0...1).contains(progress) {
            throw SessionError(code: .invalidArgument, message: "进度必须介于 0 与 1 之间", taskID: id)
        }
        var task = project.tasks[index]
        if let status {
            task.status = status
            if status == .done {
                task.progress = 1
                if task.completedAt == nil { task.completedAt = Date() }
            }
        }
        if let progress, task.status != .done {
            task.progress = progress
        }
        project.tasks[index] = task
        return task
    }

    /// 群组完成度（US-E3-02 / F-20-03）：按投入加权聚合全部后代叶子任务；
    /// 群组容器自身不产生投入，无投入的叶子按权重 1 计；非群组（无后代）返回自身进度。
    public func groupProgress(id: UUID) throws -> Double {
        guard let project else { throw notOpen() }
        guard let task = project.tasksByID[id] else {
            throw SessionError(code: .taskNotFound, message: "任务不存在", taskID: id)
        }
        let leaves = leafDescendants(of: id, in: project)
        guard !leaves.isEmpty else { return task.progress }
        let total = leaves.reduce(0.0) { $0 + ($1.effortHours ?? 1) }
        let done = leaves.reduce(0.0) { $0 + ($1.effortHours ?? 1) * $1.progress }
        guard total > 0 else { return task.progress }
        return done / total
    }

    /// 后代叶子任务：仍含子任务的群组容器被展开，只有叶子（无子任务）参与加权。
    private func leafDescendants(of id: UUID, in project: Project) -> [TaskItem] {
        var result: [TaskItem] = []
        for task in project.tasks where task.parentID == id {
            if project.tasks.contains(where: { $0.parentID == task.id }) {
                result.append(contentsOf: leafDescendants(of: task.id, in: project))
            } else {
                result.append(task)
            }
        }
        return result
    }

    // MARK: - 资源（F-23-01 / ADR-009）

    /// 新增资源（人员/设备/素材/群组）；单位与效率必须为正。
    @discardableResult
    public func resourceAdd(
        name: String,
        kind: ResourceKind = .person,
        units: Double = 1.0,
        efficiency: Double = 1.0
    ) throws -> UUID {
        guard let project else { throw notOpen() }
        if units <= 0 {
            throw SessionError(code: .invalidArgument, message: "资源单位必须为正数")
        }
        if efficiency <= 0 {
            throw SessionError(code: .invalidArgument, message: "资源效率必须为正数")
        }
        let resource = Resource(name: name, kind: kind, units: units, efficiency: efficiency)
        project.resources.append(resource)
        return resource.id
    }

    /// 列出项目资源。
    public func resourceList() throws -> [Resource] {
        guard let project else { throw notOpen() }
        return project.resources
    }

    // MARK: - 私有

    private func notOpen() -> SessionError {
        SessionError(code: .projectNotOpen, message: "未打开项目（请先 project open / project create）")
    }
}

import Foundation
import KairoCore

/// 命令层统一错误（接口层结构化错误契约；MCP 工具与 CLI 共用）。
///
/// 两层码（F-0703）：
/// - code：冻结的粗粒度分类（5 值），CLI 退出码与既有 MCP 消费者的匹配依据，不改值；
/// - reason：细粒度稳定码（KairoErrorCode），取代「按 message 文本匹配」的脆弱用法。
///
/// message 仍保留：阶段一 CLI 的人类输出逐字等于 v0.8.5，MCP 的错误 message 也保持中文；
/// 核心层与视图层一律不读它（读 code / reason 后自行渲染）。
public struct SessionError: Error, Equatable, Sendable, CustomStringConvertible {
    public enum Code: String, Equatable, Sendable {
        case projectNotOpen = "project_not_open"
        case taskNotFound = "task_not_found"
        case invalidArgument = "invalid_argument"
        case fileUnreadable = "file_unreadable"
        case unsupportedFormat = "unsupported_format"
    }

    public var code: Code
    /// 细粒度稳定错误码（接口层输出；与语言无关）。
    public var reason: KairoErrorCode
    /// 人类可读说明（阶段一中文原样；核心/视图不读）。
    public var message: String
    public var taskID: UUID?

    public init(
        code: Code,
        reason: KairoErrorCode,
        message: String,
        taskID: UUID? = nil
    ) {
        self.code = code
        self.reason = reason
        self.message = message
        self.taskID = taskID
    }

    public var description: String { message }
}

/// 载入期的规范化警告（F-0703）：只带码与参数，中文 / 英文由调用方渲染。
///
/// 典型场景：旧数据里「有子项但 kind 不是 group」的任务在载入时被提升为群组，
/// 用户需要知道项目被改动过。
public struct LoadWarning: Codable, Hashable, Sendable {
    public var code: KairoErrorCode
    public var taskID: UUID?
    public var taskTitle: String?

    public init(code: KairoErrorCode, taskID: UUID? = nil, taskTitle: String? = nil) {
        self.code = code
        self.taskID = taskID
        self.taskTitle = taskTitle
    }
}

/// 可选字段补丁（ADR-013）：区分「不修改」「设为值」「清空」。
public enum FieldPatch<T: Sendable>: Sendable {
    case unchanged
    case set(T)
    case clear
}

/// 任务字段补丁（ADR-013）：`updateTask(id:patch:)` 使用；可选字段支持清空。
public struct TaskPatch: Sendable {
    public var title: String?
    public var notes: String?
    public var priority: TaskPriority?
    public var status: TaskStatus?
    /// 取消原因：仅当 `status == .cancelled` 时使用，缺失即拒绝该次补丁。
    public var cancelReason: String?
    public var progress: Double?
    public var tags: [String]?
    public var kind: TaskKind?
    public var schedulingPolicy: SchedulingPolicy?
    public var dependencies: [TaskDependency]?
    public var assignments: [TaskAssignment]?
    public var startDate: FieldPatch<Date> = .unchanged
    public var dueDate: FieldPatch<Date> = .unchanged
    public var assignee: FieldPatch<String> = .unchanged
    public var parentID: FieldPatch<UUID> = .unchanged
    public var effortHours: FieldPatch<Double> = .unchanged
    public var durationDays: FieldPatch<Double> = .unchanged
    public var constraint: FieldPatch<SchedulingConstraint> = .unchanged

    public init() {}
}

/// MCP 与 CLI 共享的命令实现层（ADR-005 契约同源）。
/// 持有当前项目与会话状态；project / task / wbs 操作全部经由此处，
/// 两个接口层只做参数路由与输出呈现。
public final class KairoSession {
    public private(set) var project: Project?
    public private(set) var projectURL: URL?
    /// 是否存在未保存修改（ADR-013 / 外部更新检测）。
    public private(set) var hasUnsavedChanges = false
    /// 写操作版本号：每次变更递增，供异步加载判断期间是否有新编辑。
    public private(set) var revision: UInt64 = 0
    /// 当前项目来源文件的格式版本；新建项目或尚未打开文件时为 nil。
    public private(set) var sourceFormatVersion: Int?

    /// 来源文件早于当前格式，保存后即完成升级（FR-KAIRO-FMT）。
    public var needsFormatUpgrade: Bool {
        sourceFormatVersion.map { $0 < KairoFile.currentFormatVersion } ?? false
    }

    public init() {}

    // MARK: - 缓存与脏标记

    /// 任一写操作后置脏；读取排期时按需重算一次。
    private func markChanged() {
        lastSchedule = nil
        hasUnsavedChanges = true
        revision &+= 1
    }

    private func markSaved() {
        hasUnsavedChanges = false
    }

    // MARK: - 项目

    /// 新建项目（US-E1-01）：返回项目元数据，含项目 ID。
    @discardableResult
    public func createProject(
        title: String,
        projectStart: Date? = nil,
        projectEnd: Date? = nil
    ) throws -> ProjectMetadata {
        let project = Project()
        project.metadata.title = title
        project.metadata.projectStart = projectStart
        project.metadata.projectEnd = projectEnd
        project.metadata.updatedAt = Date()
        self.project = project
        projectURL = nil
        sourceFormatVersion = nil
        markChanged()
        markSaved()
        return project.metadata
    }

    /// 打开 .kairo 项目文件。
    @discardableResult
    public func openProject(at url: URL) throws -> ProjectMetadata {
        let decoded: DecodedProject
        do {
            // 保留来源版本：迁移在读取时完成，但磁盘仍可能是旧格式直至保存。
            decoded = try KairoFile.read(from: url)
        } catch let error as KairoFileError {
            // 粗码 code 保持 v0.8.5 口径（决定 CLI 退出码与 MCP 分类）；
            // 细码 reason 四例透传，取代「按 message 文本猜是哪一种格式问题」。
            let code: SessionError.Code
            let reason: KairoErrorCode
            switch error {
            case .unsupportedFormatVersion:
                code = .unsupportedFormat
                reason = .unsupportedFormat
            case .noMigrationPath:
                code = .unsupportedFormat
                reason = .noMigrationPath
            case .migrationFailed:
                code = .unsupportedFormat
                reason = .migrationFailed
            case .malformedFormatVersion:
                code = .fileUnreadable
                reason = .malformedFormatVersion
            }
            throw SessionError(code: code, reason: reason, message: error.description)
        } catch {
            throw SessionError(
                code: .fileUnreadable,
                reason: .fileUnreadable,
                message: "无法读取项目文件：\(url.lastPathComponent)"
            )
        }
        adoptProject(
            decoded.project, from: url, formatVersion: decoded.sourceFormatVersion
        )
        return decoded.project.metadata
    }

    /// 接管已在后台解码的项目（应用层异步打开，避免主线程阻塞）。
    ///
    /// - Parameter formatVersion: 来源文件的格式版本。生产路径的取值为
    ///   `1...KairoFile.currentFormatVersion`（读取时已校验）；测试接缝可传 0
    ///   模拟早于首个可迁移版本的来源。默认值仅用于接管已是当前版本的项目；
    ///   打开旧版文件时必须显式传入 `DecodedProject.sourceFormatVersion`。
    public func adoptProject(
        _ project: Project,
        from url: URL,
        formatVersion: Int = KairoFile.currentFormatVersion
    ) {
        normalizeGroupKinds(in: project)
        self.project = project
        projectURL = url
        sourceFormatVersion = formatVersion
        markChanged()
        markSaved()
    }

    /// 文件导出器已把快照写入磁盘：回填路径并清除脏标记，避免重复写文件。
    /// 导出内容始终是当前格式，因此来源版本同步为当前版本。
    public func noteExported(to url: URL) {
        projectURL = url
        sourceFormatVersion = KairoFile.currentFormatVersion
        markSaved()
    }

    /// 加载规范化警告（如「有子项的任务已按群组处理」）：只带码与参数，文案由调用方渲染。
    public private(set) var loadWarnings: [LoadWarning] = []

    /// 更新项目元数据；开始/结束日期可显式清空。
    @discardableResult
    public func updateProjectMetadata(
        title: String? = nil,
        projectStart: FieldPatch<Date> = .unchanged,
        projectEnd: FieldPatch<Date> = .unchanged,
        direction: ScheduleDirection? = nil
    ) throws -> ProjectMetadata {
        guard let project else { throw notOpen() }
        if let title { project.metadata.title = title }
        if let direction { project.metadata.direction = direction }
        Self.apply(projectStart, to: &project.metadata.projectStart)
        Self.apply(projectEnd, to: &project.metadata.projectEnd)
        project.metadata.updatedAt = Date()
        markChanged()
        return project.metadata
    }

    /// 当前项目值快照（撤销栈与呈现层输入）。
    public func snapshot() throws -> ProjectState {
        guard let project else { throw notOpen() }
        return ProjectState(project: project)
    }

    /// 用快照恢复项目（撤销/重做）。
    public func restore(_ state: ProjectState) throws {
        guard let project else { throw notOpen() }
        state.apply(to: project)
        project.metadata.updatedAt = Date()
        markChanged()
    }

    /// 任务首次获得子项时提升为群组，保证「有子项 ⇒ kind == .group」始终成立。
    private func promoteToGroupIfNeeded(_ parentID: UUID?, in project: Project) {
        guard let parentID,
              let index = project.tasks.firstIndex(where: { $0.id == parentID }),
              project.tasks[index].kind != .group else { return }
        project.tasks[index].kind = .group
    }

    /// 群组唯一判据为 `kind == .group`；有子项但类型不符的旧数据在加载时规范化。
    private func normalizeGroupKinds(in project: Project) {
        let parentIDs = Set(project.tasks.compactMap(\.parentID))
        var warnings: [LoadWarning] = []
        for (index, task) in project.tasks.enumerated()
        where parentIDs.contains(task.id) && task.kind != .group {
            project.tasks[index].kind = .group
            warnings.append(LoadWarning(
                code: .groupPromoted,
                taskID: task.id,
                taskTitle: task.title
            ))
        }
        loadWarnings = warnings
    }

    /// 保存项目；未指定路径时使用已打开项目的路径。
    @discardableResult
    public func saveProject(to url: URL? = nil) throws -> ProjectMetadata {
        guard let project else { throw notOpen() }
        let target = url ?? projectURL
        guard let target else {
            throw SessionError(
                code: .invalidArgument,
                reason: .noSavePath,
                message: "未指定保存路径（请提供 --path 或先打开项目）"
            )
        }
        project.metadata.updatedAt = Date()
        // 写路径独占的补色点：旧文件缺 colorIndex 的基线在这里补齐并随本次保存落盘；
        // 打开路径不调用，避免只读打开给未修改的文件平白置脏（§4）。
        BaselinePalette.ensureColors(in: &project.baselines)
        do {
            try KairoFile.save(project, to: target)
        } catch {
            throw SessionError(
                code: .fileUnreadable,
                reason: .writeFailed,
                message: "保存失败：\(error.localizedDescription)"
            )
        }
        projectURL = target
        sourceFormatVersion = KairoFile.currentFormatVersion
        markSaved()
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
        dependencies: [TaskDependency] = [],
        constraint: SchedulingConstraint? = nil,
        schedulingPolicy: SchedulingPolicy = .asap,
        assignments: [TaskAssignment] = [],
        startDate: Date? = nil,
        dueDate: Date? = nil,
        assignee: String? = nil
    ) throws -> UUID {
        guard let project else { throw notOpen() }
        if let parentID, project.tasksByID[parentID] == nil {
            throw SessionError(code: .invalidArgument, reason: .parentNotFound, message: "父任务不存在", taskID: parentID)
        }
        // 终态只能由状态回写进入：新建即 cancelled 必然缺原因，拒绝而不是落一条不可回溯的记录。
        if status == .cancelled {
            throw Self.cancelReasonRequired(
                taskID: nil,
                message: "新建任务不能直接为已取消（请先建任务，再以原因回写状态）"
            )
        }
        promoteToGroupIfNeeded(parentID, in: project)
        try validate(assignments: assignments, in: project)
        let task = TaskItem(
            title: title,
            notes: notes,
            startDate: startDate,
            dueDate: dueDate,
            priority: priority,
            status: status,
            tags: tags,
            assignee: Self.normalizedAssignee(assignee),
            kind: kind,
            parentID: parentID,
            effortHours: effortHours,
            durationDays: durationDays,
            dependencies: dependencies,
            constraint: constraint,
            schedulingPolicy: schedulingPolicy,
            assignments: assignments
        )
        project.add(task)
        markChanged()
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
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
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
        tags: [String]? = nil,
        dependencies: [TaskDependency]? = nil,
        constraint: SchedulingConstraint? = nil,
        schedulingPolicy: SchedulingPolicy? = nil,
        assignments: [TaskAssignment]? = nil,
        assignee: String? = nil
    ) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        if let assignments { try validate(assignments: assignments, in: project) }
        var task = project.tasks[index]
        if let title { task.title = title }
        if let kind {
            task.kind = kind
            try validateKind(of: task, id: id, in: project)
        }
        if let parentID {
            task.parentID = parentID
            try validateParent(of: task, id: id, in: project)
        }
        if let effortHours { task.effortHours = effortHours }
        if let durationDays { task.durationDays = durationDays }
        if let notes { task.notes = notes }
        if let priority { task.priority = priority }
        if let status { task.status = status }
        if let progress { task.progress = min(max(progress, 0), 1) }
        if let tags { task.tags = tags }
        if let dependencies { task.dependencies = dependencies }
        if let constraint { task.constraint = constraint }
        if let schedulingPolicy { task.schedulingPolicy = schedulingPolicy }
        if let assignments { task.assignments = assignments }
        // 负责人字段（US-E1-02）：nil = 不改；非 nil 空串/纯空白 = 清空（D-004 trim）。
        if let assignee { task.assignee = Self.normalizedAssignee(assignee) }
        project.tasks[index] = task
        if let parentID { promoteToGroupIfNeeded(parentID, in: project) }
        markChanged()
        return task
    }

    /// 补丁式字段更新（ADR-013）：可选字段可显式清空；状态与进度走统一回写入口。
    @discardableResult
    public func updateTask(id: UUID, patch: TaskPatch) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        if let assignments = patch.assignments { try validate(assignments: assignments, in: project) }
        if let progress = patch.progress, !(0...1).contains(progress) {
            throw SessionError(code: .invalidArgument, reason: .progressOutOfRange, message: "进度必须介于 0 与 1 之间", taskID: id)
        }
        // 与 statusUpdate 同一约束：补丁把状态改成 cancelled 时也必须给原因，
        // 校验放在任何字段写入之前——失败即返回，不留半改记录。
        var cancelReason: String?
        if patch.status == .cancelled {
            guard let trimmed = Self.normalizedCancelReason(patch.cancelReason) else {
                throw Self.cancelReasonRequired(taskID: id)
            }
            cancelReason = trimmed
        }
        var task = project.tasks[index]
        if let title = patch.title { task.title = title }
        if let notes = patch.notes { task.notes = notes }
        if let priority = patch.priority { task.priority = priority }
        if let tags = patch.tags { task.tags = tags }
        if let kind = patch.kind {
            task.kind = kind
            try validateKind(of: task, id: id, in: project)
        }
        if let schedulingPolicy = patch.schedulingPolicy { task.schedulingPolicy = schedulingPolicy }
        if let dependencies = patch.dependencies { task.dependencies = dependencies }
        if let assignments = patch.assignments { task.assignments = assignments }
        Self.apply(patch.startDate, to: &task.startDate)
        Self.apply(patch.dueDate, to: &task.dueDate)
        switch patch.assignee {
        case .unchanged: break
        case .set(let name): task.assignee = Self.normalizedAssignee(name)
        case .clear: task.assignee = nil
        }
        Self.apply(patch.parentID, to: &task.parentID)
        Self.apply(patch.effortHours, to: &task.effortHours)
        Self.apply(patch.durationDays, to: &task.durationDays)
        Self.apply(patch.constraint, to: &task.constraint)
        Self.applyStatus(
            status: patch.status, progress: patch.progress,
            cancelReason: cancelReason, now: Date(), to: &task
        )
        // 仅父级实际变更时校验与提升，避免逐键更新做全量子树遍历。
        if case .set = patch.parentID {
            try validateParent(of: task, id: id, in: project)
        }
        project.tasks[index] = task
        if case .set = patch.parentID {
            promoteToGroupIfNeeded(task.parentID, in: project)
        }
        markChanged()
        return task
    }

    /// 父任务引用必须存在且不能指向自身；父级首次获得子项时提升为群组。
    private func validateParent(of task: TaskItem, id: UUID, in project: Project) throws {
        guard let parentID = task.parentID else { return }
        guard parentID != id else {
            throw SessionError(
                code: .invalidArgument,
                reason: .parentNotFound,
                message: "父任务不能是任务自身",
                taskID: id
            )
        }
        guard project.tasksByID[parentID] != nil else {
            throw SessionError(code: .invalidArgument, reason: .parentNotFound, message: "父任务不存在", taskID: parentID)
        }
        guard !OutlineEditor.subtreeIDs(of: id, in: project.tasks).contains(parentID) else {
            throw SessionError(
                code: .invalidArgument,
                reason: .moveIntoSubtree,
                message: "不能把任务移动到自身或后代之下",
                taskID: id
            )
        }
    }

    /// 有子项的任务必须是群组；拒绝经由 CLI/MCP 显式降级类型。
    private func validateKind(of task: TaskItem, id: UUID, in project: Project) throws {
        guard task.kind != .group,
              project.tasks.contains(where: { $0.parentID == id }) else { return }
        throw SessionError(
            code: .invalidArgument,
            reason: .parentNotFound,
            message: "任务存在子项，不能改为非群组类型",
            taskID: id
        )
    }

    private static func apply<V>(_ patch: FieldPatch<V>, to value: inout V?) {
        switch patch {
        case .unchanged: break
        case .set(let newValue): value = newValue
        case .clear: value = nil
        }
    }

    /// D-004：负责人输入集中归一——trim 首尾空白；纯空白视为清空（nil）。
    /// addTask / 旧式 updateTask / 补丁 updateTask 三个写路径共用。
    private static func normalizedAssignee(_ name: String?) -> String? {
        guard let name else { return nil }
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 校验分配引用的资源存在（US-E1-05）；悬空引用在写入前拒绝。
    private func validate(assignments: [TaskAssignment], in project: Project) throws {
        let resourceIDs = Set(project.resources.map(\.id))
        for assignment in assignments where !resourceIDs.contains(assignment.resourceID) {
            throw SessionError(
                code: .invalidArgument,
                reason: .resourceNotFound,
                message: "资源不存在",
                taskID: assignment.resourceID
            )
        }
    }

    /// 删除任务；存在后代时一并删除，避免 MCP/CLI 绕过界面确认后留下悬空 parentID。
    @discardableResult
    public func deleteTask(id: UUID) throws -> Bool {
        _ = try deleteSubtree(id: id)
        return true
    }

    /// 级联删除任务及其全部后代，返回受影响任务数；同时清理悬空依赖。
    @discardableResult
    public func deleteTaskCascade(id: UUID) throws -> Int {
        try deleteSubtree(id: id)
    }

    private func deleteSubtree(id: UUID) throws -> Int {
        guard let project else { throw notOpen() }
        guard project.tasksByID[id] != nil else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        let removed = OutlineEditor.subtreeIDs(of: id, in: project.tasks)
        let remaining = project.tasks.filter { !removed.contains($0.id) }
        // 指向被删任务的相关性一并移除（US-E1-02 验收）。
        project.replaceTasks(
            DependencyEditing.removingDanglingReferences(to: removed, in: remaining)
        )
        markChanged()
        return removed.count
    }

    // MARK: - 大纲移动（F-14-02 / ADR-013）

    /// Tab 缩进；无上一同级任务时返回 nil。
    @discardableResult
    public func indentTask(id: UUID) throws -> [TaskItem]? {
        guard let project else { throw notOpen() }
        guard let updated = OutlineEditor.indent(id, in: project.tasks) else { return nil }
        project.replaceTasks(updated)
        promoteToGroupIfNeeded(project.tasksByID[id]?.parentID, in: project)
        markChanged()
        return updated
    }

    /// Shift-Tab 出缩进；已是顶层时返回 nil。
    @discardableResult
    public func outdentTask(id: UUID) throws -> [TaskItem]? {
        guard let project else { throw notOpen() }
        guard let updated = OutlineEditor.outdent(id, in: project.tasks) else { return nil }
        project.replaceTasks(updated)
        markChanged()
        return updated
    }

    /// 拖拽重排：移动到目标父级与索引；拒绝移入自身或后代。
    @discardableResult
    public func moveTask(id: UUID, toParent parentID: UUID?, at index: Int) throws -> [TaskItem] {
        guard let project else { throw notOpen() }
        switch OutlineMoving.move(id, toParent: parentID, at: index, in: project.tasks) {
        case .success(let updated):
            project.replaceTasks(updated)
            promoteToGroupIfNeeded(parentID, in: project)
            markChanged()
            return updated
        case .failure(let error):
            let message: String
            let reason: KairoErrorCode
            switch error {
            case .taskNotFound:
                message = "任务不存在"
                reason = .taskNotFound
            case .targetNotFound:
                message = "目标父级不存在"
                reason = .parentNotFound
            case .moveIntoSubtree:
                message = "不能把任务移动到自身或后代之下"
                reason = .moveIntoSubtree
            }
            throw SessionError(code: .invalidArgument, reason: reason, message: message, taskID: id)
        }
    }

    // MARK: - 相关性编辑（F-30-08 / ADR-013）

    /// 添加或更新依赖（同前驱归一为一条）；成环被拒绝。
    @discardableResult
    public func addDependency(
        to taskID: UUID,
        predecessorID: UUID,
        type: TaskDependency.DependencyType = .fs,
        lagDays: Double = 0
    ) throws -> TaskItem {
        guard let project else { throw notOpen() }
        let dependency = TaskDependency(
            predecessorID: predecessorID, type: type, lagDays: lagDays
        )
        switch DependencyEditing.add(dependency, to: taskID, in: project.tasks) {
        case .success(let updated):
            project.replaceTasks(updated)
            markChanged()
            return project.tasksByID[taskID]!
        case .failure(let error):
            let message: String
            let reason: KairoErrorCode
            switch error {
            case .taskNotFound:
                message = "任务不存在"
                reason = .taskNotFound
            case .predecessorNotFound:
                message = "前驱任务不存在"
                reason = .dependencyPredecessorNotFound
            case .selfDependency:
                message = "任务不能依赖自身"
                reason = .dependencySelf
            case .cycle:
                message = "该依赖会形成相关性环"
                reason = .dependencyCycle
            }
            throw SessionError(code: .invalidArgument, reason: reason, message: message, taskID: taskID)
        }
    }

    /// 删除依赖；依赖不存在时原样返回。
    @discardableResult
    public func removeDependency(from taskID: UUID, predecessorID: UUID) throws -> TaskItem {
        guard let project else { throw notOpen() }
        switch DependencyEditing.remove(predecessorID: predecessorID, from: taskID, in: project.tasks) {
        case .success(let updated):
            project.replaceTasks(updated)
            markChanged()
            return project.tasksByID[taskID]!
        case .failure:
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: taskID)
        }
    }

    // MARK: - WBS 批量导入（US-E1-04）

    /// 把嵌套标题/kind/子节点树展开为 parentID 结构。
    @discardableResult
    public func importWBS(nodes: [WBSNode], parentID: UUID? = nil) throws -> WBSImportResult {
        guard let project else { throw notOpen() }
        if let parentID, project.tasksByID[parentID] == nil {
            throw SessionError(code: .invalidArgument, reason: .parentNotFound, message: "父任务不存在", taskID: parentID)
        }
        var rootIDs: [UUID] = []
        var idByTitle: [String: UUID] = [:]

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
        markChanged()

        return WBSImportResult(
            rootIDs: rootIDs,
            idByTitle: idByTitle,
            total: idByTitle.count,
            warnings: []
        )
    }

    // MARK: - 排期与违例查询（US-E2-02 / US-E2-03 / US-E2-05）

    /// 最近一次排期结果（schedule_compute 缓存；critical_path / violations 复用）。
    public private(set) var lastSchedule: ScheduleResult?

    /// 排期实际计算次数（测试观测缝：D-014 断言纯视图动作不触发重算）。
    public private(set) var scheduleComputeCount = 0

    /// 计算排期并缓存结果（ADR-007：经 KairoCore 纯函数，命令层不重复实现）。
    @discardableResult
    public func computeSchedule(projectStart: Date? = nil, projectEnd: Date? = nil) throws -> ScheduleResult {
        guard let project else { throw notOpen() }
        scheduleComputeCount += 1
        let result = ScheduleEngine.compute(
            tasks: project.tasks,
            resources: project.resources,
            projectStart: projectStart ?? project.metadata.projectStart,
            projectEnd: projectEnd ?? project.metadata.projectEnd,
            direction: project.metadata.direction,
            // 无日期任务以项目创建日期为锚（D-029）：不随「今天」漂移。
            createdAt: project.metadata.createdAt
        )
        lastSchedule = result
        return result
    }

    /// 未排期时先计算一次（缓存复用）。
    /// 公开供呈现快照复用：写操作经 `markChanged` 置空缓存后才重算，
    /// 纯视图动作（如日宽调整）命中缓存不重算（D-014）。
    public func scheduleOrCompute() throws -> ScheduleResult {
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

    /// 单任务状态/进度回写：状态置 done 时记录实际结束并把进度置 1；
    /// 首次开工（并入 in_progress 或进度 > 0）记录实际开始；
    /// 进度超出 0...1 拒绝并返回参数错误（US-E3-01 验收）。
    ///
    /// 已取消终态（v0.16）：转入 `cancelled` 必须给非空 `cancelReason`——缺省或纯空白
    /// 一律拒绝（`model_cancel_reason_required`），任务不被修改；写入前按首尾去空白归一。
    /// 转入 `cancelled` 清空实际结束；离开 `cancelled` 清空原因；原因只属于该状态。
    ///
    /// - Parameter now: 实际时间戳来源（默认当前时刻）。测试一律注入，不读墙钟。
    @discardableResult
    public func statusUpdate(
        id: UUID,
        status: TaskStatus? = nil,
        cancelReason: String? = nil,
        progress: Double? = nil,
        now: Date = Date()
    ) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        if let progress, !(0...1).contains(progress) {
            throw SessionError(code: .invalidArgument, reason: .progressOutOfRange, message: "进度必须介于 0 与 1 之间", taskID: id)
        }
        // 取消原因只为终态而存在：进入 cancelled 先校验，失败即返回、不落库。
        var reason: String?
        if status == .cancelled {
            guard let trimmed = Self.normalizedCancelReason(cancelReason) else {
                throw Self.cancelReasonRequired(taskID: id)
            }
            reason = trimmed
        }
        var task = project.tasks[index]
        Self.applyStatus(status: status, progress: progress, cancelReason: reason, now: now, to: &task)
        project.tasks[index] = task
        markChanged()
        return task
    }

    /// 人工写入实际开始（07-actual-dates §4）：`nil` = 清除。
    ///
    /// 非 nil 且任务为 `.pending` 时顺带置 `.inProgress`（有实际开始即已开工）；
    /// `.done` / `.blocked` 不改状态——补录历史不重开任务。
    /// 实际结束早于实际开始时抛 `model_actual_date_order_invalid`，任务不被修改。
    @discardableResult
    public func setActualStart(id: UUID, date: Date?) throws -> TaskItem {
        try mutateTask(id: id) { task in
            guard let date else {
                task.actualStart = nil
                return
            }
            try Self.validateActualDateOrder(start: date, finish: task.completedAt, taskID: id)
            task.actualStart = date
            if task.status == .pending { task.status = .inProgress }
        }
    }

    /// 人工写入实际结束（07-actual-dates §4）：`nil` = 只清除实际结束，不改状态。
    ///
    /// 非 nil → 与 done 同语义（状态 `.done`、进度 1）；实际结束早于实际开始时抛
    /// `model_actual_date_order_invalid`，任务不被修改。
    @discardableResult
    public func setActualFinish(id: UUID, date: Date?) throws -> TaskItem {
        try mutateTask(id: id) { task in
            guard let date else {
                task.completedAt = nil
                return
            }
            try Self.validateActualDateOrder(start: task.actualStart, finish: date, taskID: id)
            task.completedAt = date
            task.status = .done
            task.progress = 1
            // 与 statusUpdate 同语义：离开 cancelled 即清原因（实际结束是完成而非取消）。
            task.cancelReason = nil
        }
    }

    /// 实际开始/结束的先后校验：结束早于开始即非法（相等合法——零时长任务）。
    private static func validateActualDateOrder(start: Date?, finish: Date?, taskID: UUID) throws {
        guard let start, let finish, finish < start else { return }
        throw SessionError(
            code: .invalidArgument,
            reason: .actualDateOrderInvalid,
            message: "实际结束不能早于实际开始",
            taskID: taskID
        )
    }

    /// 单任务就地修改的公共外壳：定位 → 修改 → 回写 → 置脏。
    ///
    /// 闭包内抛错时不回写（任务保持原值），因此校验失败不会留下半改状态。
    @discardableResult
    private func mutateTask(id: UUID, _ body: (inout TaskItem) throws -> Void) throws -> TaskItem {
        guard let project else { throw notOpen() }
        guard let index = project.tasks.firstIndex(where: { $0.id == id }) else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        var task = project.tasks[index]
        try body(&task)
        project.tasks[index] = task
        markChanged()
        return task
    }

    /// 取消原因归一：去首尾空白后仍非空才算填了理由（纯空白等于没写）。
    private static func normalizedCancelReason(_ raw: String?) -> String? {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }

    /// 缺取消原因的拒绝（终态必须可回溯，否则无法回答「为什么不做」）。
    private static func cancelReasonRequired(
        taskID: UUID?,
        message: String = "转为已取消时必须填写取消原因"
    ) -> SessionError {
        SessionError(
            code: .invalidArgument,
            reason: .cancelReasonRequired,
            message: message,
            taskID: taskID
        )
    }

    /// 统一状态回写入口（07-actual-dates §3 的唯一触发点）：
    /// - `done`（含进度达 1）→ 实际结束 = now、进度 1；离开 `done` 清空实际结束；
    /// - `cancelled` → 清空实际结束、写入取消原因（非空由调用方先校验），离开即清原因；
    /// - 并入 `.inProgress` 或进度 > 0 且尚无实际开始 → 实际开始 = now；
    /// - 实际开始只在 nil 时写（首次为准），回退状态不清空；
    /// - 从 pending/blocked 直跳 `done` 不补实际开始（不臆造未观测到的开工时刻）；
    /// - 已取消任务忽略进度回写：终态不会因 progress 达 1 悄悄变成 done。
    private static func applyStatus(
        status: TaskStatus?,
        progress: Double?,
        cancelReason: String?,
        now: Date,
        to task: inout TaskItem
    ) {
        if let status {
            task.status = status
            switch status {
            case .done:
                task.progress = 1
                if task.completedAt == nil { task.completedAt = now }
            case .cancelled:
                // 没做完就没有完成时刻；实际开始不清（已发生的开工是历史事实）。
                task.completedAt = nil
                task.cancelReason = cancelReason
            case .inProgress:
                task.completedAt = nil
                if task.actualStart == nil { task.actualStart = now }
            case .pending, .blocked:
                task.completedAt = nil
            }
            // 原因只属于 cancelled：离开时清空，避免半改状态残留。
            if status != .cancelled { task.cancelReason = nil }
        }
        if let progress, task.status != .done, task.status != .cancelled {
            task.progress = min(max(progress, 0), 1)
            if task.progress >= 1 {
                task.progress = 1
                task.status = .done
                if task.completedAt == nil { task.completedAt = now }
            } else if task.progress > 0, task.actualStart == nil {
                // 有进度即已开工；不改状态，避免隐式状态跳变。
                task.actualStart = now
            }
        }
    }

    // MARK: - 批量回写（US-E3-02）

    /// 单条批量回写输入。
    public struct StatusUpdateInput: Sendable {
        public var taskID: UUID
        public var status: TaskStatus?
        /// 取消原因（转 `cancelled` 时必填，其余状态忽略）。
        public var cancelReason: String?
        public var progress: Double?

        public init(
            taskID: UUID,
            status: TaskStatus? = nil,
            cancelReason: String? = nil,
            progress: Double? = nil
        ) {
            self.taskID = taskID
            self.status = status
            self.cancelReason = cancelReason
            self.progress = progress
        }
    }

    /// 批量回写结果：逐条成功/失败明细，失败项不中断后续条目。
    public struct StatusBatchResult: Codable, Sendable {
        public struct Entry: Codable, Sendable {
            public var taskID: UUID
            public var ok: Bool
            public var task: TaskItem?
            public var error: String?

            public init(taskID: UUID, ok: Bool, task: TaskItem? = nil, error: String? = nil) {
                self.taskID = taskID
                self.ok = ok
                self.task = task
                self.error = error
            }
        }

        public var entries: [Entry]
        public var succeeded: Int
        public var failed: Int

        public init(entries: [Entry]) {
            self.entries = entries
            self.succeeded = entries.filter(\.ok).count
            self.failed = entries.count - succeeded
        }
    }

    /// 批量回写多个任务的状态/进度（US-E3-02）：按清单逐条更新，返回成功与失败明细。
    public func statusBatch(_ updates: [StatusUpdateInput]) throws -> StatusBatchResult {
        guard project != nil else { throw notOpen() }
        var entries: [StatusBatchResult.Entry] = []
        for update in updates {
            do {
                let task = try statusUpdate(
                    id: update.taskID,
                    status: update.status,
                    cancelReason: update.cancelReason,
                    progress: update.progress
                )
                entries.append(.init(taskID: update.taskID, ok: true, task: task))
            } catch let error as SessionError {
                entries.append(.init(taskID: update.taskID, ok: false, error: error.message))
            } catch {
                entries.append(.init(taskID: update.taskID, ok: false, error: error.localizedDescription))
            }
        }
        return StatusBatchResult(entries: entries)
    }

    /// 群组完成度（US-E3-02 / F-20-03）：按投入加权聚合全部后代叶子任务；
    /// 群组容器自身不产生投入，无投入的叶子按权重 1 计；非群组（无后代）返回自身进度。
    public func groupProgress(id: UUID) throws -> Double {
        guard let project else { throw notOpen() }
        guard let task = project.tasksByID[id] else {
            throw SessionError(code: .taskNotFound, reason: .taskNotFound, message: "任务不存在", taskID: id)
        }
        // 已取消的叶子不进加权分母（终态不参与完成度）：整棵子树都取消时回退群组自身进度。
        let leaves = leafDescendants(of: id, in: project).filter { $0.status != .cancelled }
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

    // MARK: - 基线（v0.13 / 08-baselines §8）

    /// 基线列表（按创建顺序）。
    public func baselines() throws -> [Baseline] {
        guard let project else { throw notOpen() }
        return project.baselines
    }

    /// 对当前排期结果拍一次快照（进度与计划时间一并冻结）。
    ///
    /// - 条目数 = 已排期任务数：未排期任务没有时间可比，不入条目（§3）。
    /// - 群组以自身聚合时间入条目，偏差按群组自身比较，不由子任务求和推导。
    /// - 默认名「基线 N · yyyy-MM-dd」，N 为创建序号（在本会话的项目内递增）。
    ///
    /// - Parameter now: 快照时刻与默认名日期来源；测试一律注入，不读墙钟。
    @discardableResult
    public func createBaseline(name: String? = nil, now: Date = Date()) throws -> Baseline {
        guard let project else { throw notOpen() }
        let result = try scheduleOrCompute()
        let resolvedName = try Self.validateBaselineName(
            name ?? BaselineEngine.defaultName(index: project.baselines.count + 1, date: now)
        )
        // 写路径入口先补色（§4）：旧文件缺 colorIndex 的条目按创建顺序补齐，
        // 新建基线再取最小未用索引——否则最新一条会抢走首色，与自下而上轨道顺序不符。
        BaselinePalette.ensureColors(in: &project.baselines)
        var baseline = BaselineEngine.snapshot(
            tasks: project.tasks,
            schedules: BaselineEngine.scheduleIndex(from: result),
            name: resolvedName,
            anchor: result.projectStart,
            now: now
        )
        // 取「当前未被占用的最小索引」：删除中间一条后新建会复用空缺，已有索引不动。
        baseline.colorIndex = BaselinePalette.colorIndex(for: project.baselines)
        project.baselines.append(baseline)
        markChanged()
        return baseline
    }

    /// 基线改名：只改名字，不动创建时刻、锚点与条目（基线不可变）。
    @discardableResult
    public func renameBaseline(id: UUID, name: String) throws -> Baseline {
        guard let project else { throw notOpen() }
        guard let index = project.baselines.firstIndex(where: { $0.id == id }) else {
            throw baselineNotFound(id)
        }
        // 写路径入口先补色（§4）：补齐后再改，其余基线颜色不动。
        BaselinePalette.ensureColors(in: &project.baselines)
        project.baselines[index].name = try Self.validateBaselineName(name)
        markChanged()
        return project.baselines[index]
    }

    /// 改色（§4）：只改调色板索引，不动条目、名字与创建时刻。
    ///
    /// - Parameter colorIndex: 合法范围 0 … `BaselinePalette.count - 1`；越界直接拒绝，
    ///   不落库、不置脏（快照里出现越界索引只会让读路径反复纠正）。
    /// - 与创建同等粒度：一次调用 = 一个撤销点。
    @discardableResult
    public func setBaselineColor(id: UUID, colorIndex: Int) throws -> Baseline {
        guard let project else { throw notOpen() }
        guard let index = project.baselines.firstIndex(where: { $0.id == id }) else {
            throw baselineNotFound(id)
        }
        guard (0..<BaselinePalette.count).contains(colorIndex) else {
            throw SessionError(
                code: .invalidArgument,
                reason: .baselineColorIndexInvalid,
                message: "颜色索引越界：\(colorIndex)（合法范围 0…\(BaselinePalette.count - 1)）"
            )
        }
        // 写路径入口先补色（§4）：改色之前先把旧文件缺的索引补齐，避免后补时撞上新色。
        BaselinePalette.ensureColors(in: &project.baselines)
        project.baselines[index].colorIndex = colorIndex
        markChanged()
        return project.baselines[index]
    }

    /// 删除基线（§11：允许删除，界面上由调用方做二次确认）；其余基线不受影响。
    public func deleteBaseline(id: UUID) throws {
        guard let project else { throw notOpen() }
        guard let index = project.baselines.firstIndex(where: { $0.id == id }) else {
            throw baselineNotFound(id)
        }
        // 写路径入口先补色（§4）：补齐后再删，其余颜色不因删除而重排。
        BaselinePalette.ensureColors(in: &project.baselines)
        project.baselines.remove(at: index)
        markChanged()
    }

    /// 偏差报告（§4）：`baselineID` 为 nil 时比较最新一条基线。
    ///
    /// - Parameter now: 「今天」的唯一来源（逾期天数）；测试一律注入，不读墙钟。
    public func baselineVariance(baselineID: UUID? = nil, now: Date = Date()) throws -> BaselineVarianceReport {
        guard let project else { throw notOpen() }
        let baseline: Baseline
        if let baselineID {
            guard let found = project.baselines.first(where: { $0.id == baselineID }) else {
                throw baselineNotFound(baselineID)
            }
            baseline = found
        } else {
            guard let latest = project.baselines.last else {
                throw SessionError(
                    code: .invalidArgument,
                    reason: .baselineNotFound,
                    message: "项目还没有基线（请先创建基线）"
                )
            }
            baseline = latest
        }
        let result = try scheduleOrCompute()
        return BaselineEngine.variance(
            baseline: baseline,
            tasks: project.tasks,
            schedules: BaselineEngine.scheduleIndex(from: result),
            now: now
        )
    }

    /// 基线名边界校验：去首尾空白后不得为空（空名会让报表无法区分基线）。
    private static func validateBaselineName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SessionError(
                code: .invalidArgument,
                reason: .baselineNameEmpty,
                message: "基线名不能为空"
            )
        }
        return trimmed
    }

    private func baselineNotFound(_ id: UUID) -> SessionError {
        SessionError(
            code: .invalidArgument,
            reason: .baselineNotFound,
            message: "基线不存在：\(id.uuidString)"
        )
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
            throw SessionError(code: .invalidArgument, reason: .resourceUnitInvalid, message: "资源单位必须为正数")
        }
        if efficiency <= 0 {
            throw SessionError(code: .invalidArgument, reason: .resourceEfficiencyInvalid, message: "资源效率必须为正数")
        }
        let resource = Resource(name: name, kind: kind, units: units, efficiency: efficiency)
        project.resources.append(resource)
        markChanged()
        return resource.id
    }

    /// 列出项目资源。
    public func resourceList() throws -> [Resource] {
        guard let project else { throw notOpen() }
        return project.resources
    }

    // MARK: - 私有

    private func notOpen() -> SessionError {
        SessionError(
            code: .projectNotOpen,
            reason: .projectNotOpen,
            message: "未打开项目（请先 project open / project create）"
        )
    }
}

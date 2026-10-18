import Foundation
import KairoCore
import KairoCommands

/// 应用层可观察门面：包装 KairoSession 命令层（ADR-004 / ADR-005 契约同源）。
/// 会话为命令层事实源（与 MCP、CLI 同一操作路径）；本门面把会话项目镜像为
/// @Published 供 SwiftUI 刷新，文件打开 / 保存统一经会话。
/// 主区域视图模式（F-12-02 视图切换）。
enum ViewMode: String, CaseIterable, Identifiable {
    case outline, gantt

    var id: String { rawValue }

    var title: String {
        switch self {
        case .outline: return "任务"
        case .gantt: return "甘特"
        }
    }
}

@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var project: Project
    /// 当前选中任务（大纲、甘特与命令层共享）。
    @Published var selection: UUID?
    @Published var viewMode: ViewMode = .outline
    @Published var showViolations = false
    @Published var showFindBar = false
    @Published var showCommandPalette = false
    /// 当前项目的排期违例（US-E4-07）；项目每次变更后重算。
    @Published private(set) var violations: [Violation] = []
    /// 最近一次排期结果（检查器展示计划开始/结束与宽延）。
    @Published private(set) var schedule: ScheduleResult?
    private let session: KairoSession

    init() {
        let session = KairoSession()
        self.session = session
        _ = try? session.createProject(title: "未命名项目")
        // 首启动演示数据（Sprint 0 保留）：任务直接加入会话项目（同一实例引用）。
        let seed = SeedData.makeProject()
        for task in seed.tasks { session.project?.add(task) }
        self.project = session.project ?? Project()
        recomputeViolations()
    }

    /// 已打开项目的保存路径（nil = 尚未保存过）。
    var projectURL: URL? { session.projectURL }

    /// 打开 .kairo：经会话校验格式（含 formatVersion）并载入。
    func open(url: URL) throws {
        _ = try session.openProject(at: url)
        project = session.project ?? project
        recomputeViolations()
        objectWillChange.send()
    }

    /// 保存到指定路径（nil = 使用已打开路径）。
    func save(to url: URL? = nil) throws {
        _ = try session.saveProject(to: url)
        objectWillChange.send()
    }

    /// 另存为完成后记录路径（供后续 ⌘S 直存）。
    func rememberSaveURL(_ url: URL) {
        session.setProjectURL(url)
    }

    func add(_ task: TaskItem) {
        project.add(task)
        recomputeViolations()
        objectWillChange.send()
    }

    func update(_ task: TaskItem) {
        project.update(task)
        recomputeViolations()
        objectWillChange.send()
    }

    func remove(id: UUID) {
        project.remove(id: id)
        recomputeViolations()
        objectWillChange.send()
    }

    /// 新建任务 / 群组 / 里程碑；parentID 缺省时挂在当前选中任务下。
    @discardableResult
    func addTask(kind: TaskKind, parentID: UUID? = nil) -> UUID {
        let title: String
        switch kind {
        case .task: title = "新任务"
        case .group: title = "新群组"
        case .milestone: title = "新里程碑"
        }
        let task = TaskItem(title: title, kind: kind, parentID: parentID ?? selection)
        add(task)
        selection = task.id
        return task.id
    }

    func indentSelected() {
        guard let selection else { return }
        indent(selection)
    }

    func outdentSelected() {
        guard let selection else { return }
        outdent(selection)
    }

    func insertSiblingAfterSelection() {
        guard let selection else { return }
        let id = insertSibling(after: selection)
        self.selection = id
    }

    // MARK: - 大纲层级编辑（US-E4-03）

    /// Tab：缩进为上一同级任务的子任务。
    func indent(_ id: UUID) {
        guard let updated = OutlineEditor.indent(id, in: project.tasks) else { return }
        applyOutline(updated)
    }

    /// Shift-Tab：上移一级，子树随行。
    func outdent(_ id: UUID) {
        guard let updated = OutlineEditor.outdent(id, in: project.tasks) else { return }
        applyOutline(updated)
    }

    /// Return：在任务之后新建同级任务；选中群组时新任务成为其子项。
    @discardableResult
    func insertSibling(after id: UUID, title: String = "新任务") -> UUID {
        let parentID = OutlineEditor.siblingParent(for: id, in: project.tasks)
        let task = TaskItem(title: title, parentID: parentID)
        project.insert(task, after: id)
        recomputeViolations()
        objectWillChange.send()
        return task.id
    }

    private func applyOutline(_ tasks: [TaskItem]) {
        project.replaceTasks(tasks)
        recomputeViolations()
        objectWillChange.send()
    }

    /// 排期结果随项目字段变化重算；违例引擎在结果上运行（ADR-007）。
    /// 项目时间线未设时引擎按任务推导，不阻断面板展示。
    private func recomputeViolations() {
        let result = ScheduleEngine.compute(
            tasks: project.tasks,
            resources: project.resources,
            projectStart: project.metadata.projectStart,
            projectEnd: project.metadata.projectEnd
        )
        schedule = result
        violations = ViolationEngine.check(result: result, tasks: project.tasks)
    }
}

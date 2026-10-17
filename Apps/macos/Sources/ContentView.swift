import SwiftUI
import KairoCore

/// Main window: AI filter bar, optional find bar, task list and detail editor.
struct ContentView: View {
    @ObservedObject var store: ProjectStore
    @ObservedObject var find: FindModel

    @State private var filterText = ""
    @State private var selectedTaskID: UUID?
    @State private var showFindBar = false
    @State private var scrollTargetID: UUID?
    @State private var adapter = FindAdapter()
    @FocusState private var findFieldFocused: Bool

    /// 纯逻辑项目模型（只读访问；变更经 `store` 路由以触发通知）。
    private var project: Project { store.project }

    private var clauses: [FilterClause] {
        AIFilterTranslator.translate(filterText)
    }

    private var filterTokens: [String] {
        AIFilterTranslator.tokenize(filterText)
    }

    private var filteredTasks: [TaskItem] {
        project.filteredTasks(clauses: clauses)
    }

    private var selectedTask: TaskItem? {
        guard let id = selectedTaskID else { return nil }
        return project.tasks.first { $0.id == id }
    }

    /// 按 parentID 构树（根为 parentID == nil）；List(children:) 渲染层级。
    private var rootNodes: [TaskNode] {
        let byParent = Dictionary(grouping: filteredTasks) { $0.parentID }
        func build(_ task: TaskItem) -> TaskNode {
            let children = (byParent[task.id] ?? []).map(build)
            return TaskNode(task: task, children: children.isEmpty ? nil : children)
        }
        return (byParent[nil] ?? []).map(build)
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider()
            HStack(spacing: 0) {
                ScrollViewReader { proxy in
                    TaskOutlineList(selection: $selectedTaskID, nodes: rootNodes)
                    .onChange(of: scrollTargetID) { _, target in
                        guard let target else { return }
                        withAnimation { proxy.scrollTo(target, anchor: .center) }
                        scrollTargetID = nil
                    }
                }
                if let selectedTask {
                    Divider()
                    DetailPane(task: binding(for: selectedTask), project: project)
                        .frame(width: 320)
                }
            }
        }
        .background(findShortcutButton)
        .onAppear {
            adapter.reveal = { index in revealMatch(at: index) }
            refreshFindTarget()
        }
        .onChange(of: filteredTasks) { _, _ in refreshFindTarget() }
        .onChange(of: find.lastFindString) { _, _ in find.rescan() }
        .onChange(of: find.regexMode) { _, _ in find.rescan() }
        .toolbar {
            ToolbarItem {
                Menu {
                    Button("任务") { addTask(kind: .task) }
                    Button("群组") { addTask(kind: .group) }
                    Button("里程碑") { addTask(kind: .milestone) }
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .help("新建任务 / 群组 / 里程碑")
            }
        }
        .frame(minWidth: 760, minHeight: 480)
    }

    // MARK: - Subviews

    private var searchHeader: some View {
        VStack(spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("智能筛选或搜索任务…", text: $filterText)
                    .textFieldStyle(.roundedBorder)
            }
            if !clauses.isEmpty {
                filterChipRow
            }
            if showFindBar {
                findBar
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var filterChipRow: some View {
        HStack(spacing: 6) {
            Text(AIFilterTranslator.explanation(for: clauses))
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 0)
            ForEach(Array(filterTokens.enumerated()), id: \.offset) { index, token in
                FilterChip(label: chipLabel(for: token)) {
                    removeToken(at: index)
                }
            }
        }
    }

    private var findBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "text.magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("查找文本", text: $find.lastFindString)
                .textFieldStyle(.roundedBorder)
                .focused($findFieldFocused)
                .onSubmit { find.findNext() }
            Text("\(find.currentIndex.map { $0 + 1 } ?? 0)/\(find.matchCount)")
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(minWidth: 44, alignment: .trailing)
            Button {
                find.findPrevious()
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(find.matchCount == 0)
            Button {
                find.findNext()
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(find.matchCount == 0)
            Button {
                find.regexMode.toggle()
            } label: {
                Text(".*")
                    .font(.system(.caption, design: .monospaced))
            }
            .buttonStyle(.bordered)
            .tint(find.regexMode ? Color.accentColor : Color.secondary)
            .help("正则模式")
        }
    }

    /// Invisible ⌘F target that shows the find bar and focuses its field.
    private var findShortcutButton: some View {
        Button("查找") {
            showFindBar = true
            DispatchQueue.main.async {
                findFieldFocused = true
            }
        }
        .keyboardShortcut("f", modifiers: .command)
        .hidden()
    }

    // MARK: - Helpers

    private func chipLabel(for token: String) -> String {
        switch AIFilterTranslator.translate(token).first {
        case .term(let term): return term.displayText
        case .overdue: return "逾期"
        case .dueToday: return "今天到期"
        case nil: return token
        }
    }

    private func removeToken(at index: Int) {
        var tokens = filterTokens
        guard tokens.indices.contains(index) else { return }
        tokens.remove(at: index)
        filterText = tokens.joined(separator: " ")
    }

    /// 新建任务 / 群组 / 里程碑；选中任务时作为其子项加入。
    private func addTask(kind: TaskKind) {
        let title: String
        switch kind {
        case .task: title = "新任务"
        case .group: title = "新群组"
        case .milestone: title = "新里程碑"
        }
        store.add(TaskItem(title: title, kind: kind, parentID: selectedTaskID))
    }

    private func binding(for task: TaskItem) -> Binding<TaskItem> {
        Binding(
            get: { self.project.tasks.first { $0.id == task.id } ?? task },
            set: { self.store.update($0) }
        )
    }

    private func refreshFindTarget() {
        adapter.texts = filteredTasks.map(\.findableText)
        find.attach(target: adapter)
    }

    private func revealMatch(at index: Int) {
        let tasks = filteredTasks
        guard tasks.indices.contains(index) else { return }
        let task = tasks[index]
        selectedTaskID = task.id
        scrollTargetID = task.id
    }
}

/// Bridges the visible task rows to `FindController`.
@MainActor
private final class FindAdapter: @MainActor FindTarget {
    var texts: [String] = []
    var reveal: ((Int) -> Void)?

    var findableText: [String] { texts }

    func revealMatch(at index: Int) {
        reveal?(index)
    }
}

// MARK: - Row / badge / chip views

/// 层级树节点（List(children:) 渲染结构；children 为空即叶子）。
private struct TaskNode: Identifiable {
    let task: TaskItem
    var children: [TaskNode]?
    var id: UUID { task.id }
}

/// 树行包装：给类型检查器一个具体返回类型，避免 List(children:) 泛型推断超时。
private struct TaskTreeRow: View {
    let node: TaskNode
    var body: some View {
        TaskRow(task: node.task)
            .tag(node.task.id)
            .id(node.task.id)
    }
}

/// 层级大纲列表：把泛型 List(selection:children:) 隔离到独立类型，规避类型检查超时。
private struct TaskOutlineList: View {
    @Binding var selection: UUID?
    let nodes: [TaskNode]

    var body: some View {
        List(nodes, children: \TaskNode.children, selection: $selection) { node in
            TaskTreeRow(node: node)
        }
        .listStyle(.inset)
    }
}

private struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            kindIcon
            Image(systemName: statusImage)
                .foregroundStyle(statusColor)
                .frame(width: 16)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(task.title)
                        .lineLimit(1)
                        .fontWeight(task.kind == .group ? .semibold : .regular)
                    if task.priority != .normal {
                        PriorityBadge(priority: task.priority)
                    }
                    Spacer()
                    dueDateText
                }
                HStack(spacing: 6) {
                    ForEach(task.tags, id: \.self) { tag in
                        Text("#\(tag)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    if let assignee = task.assignee {
                        Text(assignee)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if task.status != .done, task.progress > 0 {
                    ProgressView(value: task.progress)
                        .frame(maxWidth: 200)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private var statusImage: String {
        switch task.status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .done: return "checkmark.circle.fill"
        case .blocked: return "exclamationmark.triangle"
        }
    }

    /// 里程碑菱形标记；群组/任务不加前缀图标（群组靠加粗 + 大纲展开三角区分）。
    @ViewBuilder
    private var kindIcon: some View {
        if task.kind == .milestone {
            Image(systemName: "diamond")
                .foregroundStyle(.indigo)
                .frame(width: 16)
                .padding(.top, 2)
        }
    }

    private var statusColor: Color {
        switch task.status {
        case .pending: return .secondary
        case .inProgress: return .blue
        case .done: return .green
        case .blocked: return .orange
        }
    }

    @ViewBuilder
    private var dueDateText: some View {
        if let due = task.dueDate {
            Text(due.formatted(date: .abbreviated, time: .omitted))
                .font(.caption)
                .foregroundStyle(task.isOverdue ? Color.red : Color.secondary)
        }
    }
}

private struct PriorityBadge: View {
    let priority: TaskPriority

    var body: some View {
        Text(priorityLabel(priority))
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(priorityColor.opacity(0.15), in: Capsule())
            .foregroundStyle(priorityColor)
    }

    private var priorityColor: Color {
        switch priority {
        case .low: return .gray
        case .normal: return .blue
        case .high: return .orange
        case .critical: return .red
        }
    }
}

private struct FilterChip: View {
    let label: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.caption)
            Button(action: onRemove) {
                Image(systemName: "xmark.circle.fill")
                    .font(.caption2)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .background(Color.accentColor.opacity(0.12), in: Capsule())
    }
}

// MARK: - Detail editor

private struct DetailPane: View {
    @Binding var task: TaskItem
    let project: Project

    var body: some View {
        Form {
            Section("任务") {
                TextField("标题", text: $task.title)
                TextField("备注", text: $task.notes, axis: .vertical)
                    .lineLimit(3...8)
            }
            Section("状态与优先级") {
                Picker("状态", selection: $task.status) {
                    ForEach(TaskStatus.allCases, id: \.self) { status in
                        Text(statusLabel(status)).tag(status)
                    }
                }
                Picker("优先级", selection: $task.priority) {
                    ForEach(TaskPriority.allCases, id: \.self) { priority in
                        Text(priorityLabel(priority)).tag(priority)
                    }
                }
            }
            Section("排期") {
                DatePicker("截止日期", selection: dueDateBinding, displayedComponents: .date)
                if task.isOverdue {
                    Label("已逾期", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.red)
                }
            }
            Section("负责人") {
                TextField("负责人", text: assigneeBinding)
            }
            Section("进度") {
                HStack {
                    Slider(value: $task.progress, in: 0...1)
                    Text("\(Int(task.progress * 100))%")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
            if !task.dependencies.isEmpty {
                Section("相关性") {
                    ForEach(task.dependencies, id: \.self) { dependency in
                        Text(dependencyTitle(dependency))
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    private var dueDateBinding: Binding<Date> {
        Binding(
            get: { task.dueDate ?? Date() },
            set: { task.dueDate = $0 }
        )
    }

    private var assigneeBinding: Binding<String> {
        Binding(
            get: { task.assignee ?? "" },
            set: { task.assignee = $0.isEmpty ? nil : $0 }
        )
    }

    private func dependencyTitle(_ dependency: TaskDependency) -> String {
        let name = project.tasks.first { $0.id == dependency.predecessorID }?.title ?? "未知任务"
        return "\(name)（\(dependency.type.rawValue.uppercased())）"
    }
}

// MARK: - Shared label helpers

private func statusLabel(_ status: TaskStatus) -> String {
    switch status {
    case .pending: return "待办"
    case .inProgress: return "进行中"
    case .done: return "已完成"
    case .blocked: return "阻塞"
    }
}

private func priorityLabel(_ priority: TaskPriority) -> String {
    switch priority {
    case .low: return "低"
    case .normal: return "普通"
    case .high: return "高"
    case .critical: return "紧急"
    }
}

extension TaskItem {
    /// Text the find bar searches over for this row.
    var findableText: String {
        [title, notes, tags.joined(separator: " "), assignee ?? ""]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

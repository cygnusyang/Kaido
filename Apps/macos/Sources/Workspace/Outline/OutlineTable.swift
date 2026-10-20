import SwiftUI
import UniformTypeIdentifiers
import KairoCore
import KairoPresentation

/// 大纲行列表。
///
/// 只输出行骨架，不持有滚动容器：计划模式与时间画布共用同一个纵向
/// `ScrollView`（ADR-013 第 5 条），大纲模式下画布列为零宽。
struct OutlineRowsList: View {
    @ObservedObject var store: WorkspaceStore
    let rows: [PlanRow]
    let layout: OutlineColumnLayout
    @Binding var editingTaskID: UUID?

    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(rows) { row in
                OutlineRowView(
                    store: store,
                    row: row,
                    layout: layout,
                    editingTaskID: $editingTaskID
                )
                .frame(height: DesignTokens.rowHeight)
                .id(row.id)
                // 行分隔线由行视图以底部 overlay 自绘（不占布局空间）：
                // 左列总高必须严格等于 行数 × rowHeight，与画布 28pt 节距对齐。
            }
        }
        .frame(width: layout.totalWidth, alignment: .topLeading)
        .background(DesignTokens.surfaceBase)
    }
}

/// 列宽计算：非标题列随大纲宽度等比压缩，标题列吃掉剩余宽度。
struct OutlineColumnLayout {
    let columns: [OutlineColumn]
    let totalWidth: CGFloat
    let focused: Bool

    /// 压缩系数：以 600pt 为基准，最窄压到 0.6；聚焦标签栏不压缩。
    private var scale: CGFloat {
        focused ? 1 : min(max(totalWidth / 600, 0.6), 1)
    }

    func width(of column: OutlineColumn) -> CGFloat {
        if column == .title {
            return max(totalWidth - fixedWidthTotal, focused ? 0 : 120)
        }
        return CGFloat(column.width(bodyFontSize: 13)) * scale
    }

    private var fixedWidthTotal: CGFloat {
        columns.filter { $0 != .title }.reduce(0) { $0 + width(of: $1) }
    }
}

struct OutlineHeaderView: View {
    let layout: OutlineColumnLayout

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layout.columns, id: \.self) { column in
                Text(headerTitle(column))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: layout.width(of: column), alignment: .leading)
            }
        }
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        .frame(width: layout.totalWidth)
        .background(DesignTokens.surfaceChrome)
    }

    private func headerTitle(_ column: OutlineColumn) -> String {
        switch column {
        case .status: return ""
        case .violation: return "!"
        case .number: return "#"
        case .title: return "任务"
        case .predecessors: return "前置"
        case .start: return "开始"
        case .finish: return "结束"
        case .duration: return "持续"
        case .assignee: return "负责人"
        case .progress: return "完成"
        }
    }
}

private struct OutlineRowView: View {
    @ObservedObject var store: WorkspaceStore
    let row: PlanRow
    let layout: OutlineColumnLayout
    @Binding var editingTaskID: UUID?

    @State private var hovering = false
    @State private var dropTargeted = false
    @FocusState private var titleFocused: Bool

    private var isSelected: Bool { store.selection == row.id }

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layout.columns, id: \.self) { column in
                cell(column)
                    .frame(width: layout.width(of: column), alignment: .leading)
                    .clipped()
            }
        }
        .background(background)
        .contentShape(Rectangle())
        .onTapGesture { store.dispatch(.select(row.id)) }
        .onHover { hovering = $0 }
        .modifier(DragReorderModifier(
            enabled: store.allowsDragReorder,
            taskID: row.id,
            store: store,
            isTargeted: $dropTargeted
        ))
        .overlay(alignment: .bottom) {
            // 行分隔线画进行内底部，不占布局空间，保证行列表节距 = rowHeight。
            Rectangle()
                .fill(DesignTokens.separator)
                .frame(height: 1)
                .opacity(0.35)
            // 普通行插入到目标之后，插入线画在目标下缘（覆盖分隔线）；群组以整行高亮表示「放入」。
            if dropTargeted && row.kind != .group {
                Rectangle()
                    .fill(DesignTokens.accentStrong)
                    .frame(height: 2)
            }
        }
        .contextMenu { contextMenu }
        .help(row.title)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    private var background: Color {
        if dropTargeted { return DesignTokens.accentStrong.opacity(0.08) }
        if isSelected { return DesignTokens.selection }
        if row.isHighlighted { return DesignTokens.selection.opacity(0.55) }
        if hovering { return DesignTokens.hoverOverlay }
        return .clear
    }

    @ViewBuilder
    private func cell(_ column: OutlineColumn) -> some View {
        switch column {
        case .status:
            statusCell
        case .violation:
            violationCell
        case .number:
            Text(row.outlineNumber)
                .font(.system(size: DesignTokens.captionFontSize))
                .monospacedDigit()
                .foregroundStyle(DesignTokens.textSecondary)
                .padding(.horizontal, 4)
        case .title:
            titleCell
        case .predecessors:
            EditableTextCell(
                text: row.predecessorsText.isEmpty ? "—" : row.predecessorsText,
                value: row.predecessorsText,
                enabled: !row.isAggregate,
                onCommit: { store.dispatch(.setPredecessors(row.id, $0)) }
            )
        case .start:
            dateCell(row.scheduledStart)
        case .finish:
            dateCell(row.scheduledFinish)
        case .duration:
            EditableTextCell(
                text: row.durationDays.map { Display.duration($0) } ?? "—",
                value: row.durationDays.map { String(format: "%g", $0) } ?? "",
                enabled: !row.isAggregate,
                onCommit: { store.dispatch(.setDuration(row.id, Double($0))) }
            )
        case .assignee:
            EditableTextCell(
                text: row.assignee ?? "—",
                value: row.assignee ?? "",
                enabled: !row.isAggregate,
                onCommit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    store.dispatch(.setAssignee(row.id, trimmed.isEmpty ? nil : trimmed))
                }
            )
        case .progress:
            progressCell
        }
    }

    private func dateCell(_ date: Date?) -> some View {
        Text(Display.date(date))
            .font(.system(size: DesignTokens.bodyFontSize))
            .monospacedDigit()
            .foregroundStyle(row.isOverdue
                ? DesignTokens.semanticText(DesignTokens.overdue, isSelected: isSelected)
                : DesignTokens.textSecondary)
            .padding(.horizontal, 4)
    }

    private var statusCell: some View {
        Menu {
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button {
                    store.dispatch(.setStatus(row.id, status))
                } label: {
                    Label(
                        Display.statusTitle(status),
                        systemImage: Display.statusSymbol(status)
                    )
                }
            }
        } label: {
            Image(systemName: Display.statusSymbol(row.status))
                .font(.system(size: 12))
                .foregroundStyle(DesignTokens.semanticText(
                    statusColor,
                    isSelected: isSelected
                ))
                .frame(width: 18, height: 24)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help(Display.statusTitle(row.status))
    }

    private var statusColor: Color {
        switch row.status {
        case .pending: return DesignTokens.textSecondary
        case .inProgress: return DesignTokens.accentStrong
        case .blocked: return DesignTokens.violationWarning
        case .done: return DesignTokens.statusSuccess
        }
    }

    private var violationCell: some View {
        Group {
            if row.violationCount > 0 {
                HStack(spacing: 1) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 10))
                    if row.violationCount > 1 {
                        Text("\(row.violationCount)")
                            .font(.system(size: 9))
                    }
                }
                .foregroundStyle(DesignTokens.semanticText(
                    row.violationSeverity == .error
                        ? DesignTokens.violationError
                        : DesignTokens.violationWarning,
                    isSelected: isSelected
                ))
                .frame(width: 18)
                .help("\(row.violationCount) 条违例")
            } else {
                Color.clear.frame(width: 18)
            }
        }
    }

    private var titleCell: some View {
        HStack(spacing: 3) {
            if row.hasChildren {
                Button {
                    store.dispatch(.toggleExpanded(row.id))
                } label: {
                    Image(systemName: row.isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .frame(width: 14, height: 20)
                }
                .buttonStyle(.plain)
            } else {
                Color.clear.frame(width: 14)
            }

            if row.kind == .group {
                Image(systemName: "folder")
                    .font(.system(size: 10))
                    .foregroundStyle(DesignTokens.textSecondary)
            } else if row.kind == .milestone {
                Image(systemName: "diamond.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(DesignTokens.accentStrong)
            }

            if editingTaskID == row.id {
                TextField("任务标题", text: Binding(
                    get: { row.title },
                    set: { store.dispatch(.rename(row.id, $0)) }
                ))
                .textFieldStyle(.plain)
                .font(.system(size: DesignTokens.bodyFontSize))
                .focused($titleFocused)
                .onAppear {
                    DispatchQueue.main.async { titleFocused = true }
                }
                .onSubmit {
                    titleFocused = false
                    editingTaskID = nil
                }
                .onExitCommand {
                    titleFocused = false
                    editingTaskID = nil
                }
                .onChange(of: titleFocused) { _, focused in
                    // 失焦只结束本行编辑；跨行的编辑目标可能已被另一行接管。
                    if !focused, editingTaskID == row.id { editingTaskID = nil }
                }
            } else {
                Text(row.title.isEmpty ? "未命名" : row.title)
                    .font(.system(
                        size: DesignTokens.bodyFontSize,
                        weight: row.kind == .group ? .semibold : .regular
                    ))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .onTapGesture(count: 2) { editingTaskID = row.id }
                    .accessibilityLabel(row.title)
            }

            if row.priority == .critical {
                Text("!")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignTokens.semanticText(
                        DesignTokens.violationWarning,
                        isSelected: isSelected
                    ))
                    .help("紧急")
            }
            if row.isOverdue {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.semanticText(
                        DesignTokens.overdue,
                        isSelected: isSelected
                    ))
                    .help("已逾期")
            }
            if row.deadlineRisk {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.semanticText(
                        DesignTokens.violationWarning,
                        isSelected: isSelected
                    ))
                    .help("计划结束晚于截止日期")
            }
            if !row.hasSchedule, let reason = row.unscheduledReason {
                Text(Display.unscheduledReason(reason))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.leading, CGFloat(row.depth) * 14 + 2)
        .padding(.trailing, 4)
    }

    private var progressCell: some View {
        HStack(spacing: 4) {
            if row.isAggregate {
                Text(Display.percent(row.progress))
                    .font(.system(size: DesignTokens.bodyFontSize))
                    .monospacedDigit()
                    .foregroundStyle(DesignTokens.textSecondary)
            } else {
                EditableTextCell(
                    text: Display.percent(row.progress),
                    value: "\(Int((row.progress * 100).rounded()))",
                    enabled: true,
                    onCommit: { text in
                        guard let value = Double(text) else { return }
                        store.dispatch(.setProgress(row.id, value / 100))
                    }
                )
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(DesignTokens.progressTrack)
                    Capsule()
                        .fill(DesignTokens.progressFill)
                        .frame(width: max(0, geo.size.width * min(max(row.progress, 0), 1)))
                }
            }
            .frame(width: 28, height: 4)
        }
        .padding(.horizontal, 4)
    }

    @ViewBuilder
    private var contextMenu: some View {
        Button("新建同级任务") {
            store.dispatch(.createSibling(after: row.id))
        }
        Button("新建子任务") {
            store.dispatch(.createTask(parentID: row.id, kind: .task))
        }
        Button("复制任务链接") {
            store.dispatch(.copyTaskLink(row.id))
        }
        Divider()
        Button("缩进") { store.dispatch(.indent(row.id)) }
        Button("减少缩进") { store.dispatch(.outdent(row.id)) }
        if row.kind == .group {
            Divider()
            Button("新建群组") { store.dispatch(.createTask(parentID: row.id, kind: .group)) }
            Button("新建里程碑") { store.dispatch(.createTask(parentID: row.id, kind: .milestone)) }
        }
        Divider()
        Button("删除", role: .destructive) {
            store.requestDelete(id: row.id)
        }
    }
}

/// 筛选激活时不注册拖拽手势，避免「可拖但目标不可见」的半成品交互。
private struct DragReorderModifier: ViewModifier {
    let enabled: Bool
    let taskID: UUID
    let store: WorkspaceStore
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content
                .onDrag {
                    store.dispatch(.select(taskID))
                    return NSItemProvider(object: taskID.uuidString as NSString)
                }
                .onDrop(
                    of: [.plainText],
                    delegate: OutlineRowDropDelegate(
                        targetID: taskID,
                        store: store,
                        isTargeted: $isTargeted
                    )
                )
        } else {
            content
        }
    }
}

/// 单行拖拽重排：拖到群组行成为子项，拖到普通行插为其后同级。
private struct OutlineRowDropDelegate: DropDelegate {
    let targetID: UUID
    let store: WorkspaceStore
    @Binding var isTargeted: Bool

    func validateDrop(info: DropInfo) -> Bool {
        info.hasItemsConforming(to: [.plainText])
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        DropProposal(operation: .move)
    }

    func dropEntered(info: DropInfo) {
        isTargeted = true
        Task { @MainActor in store.scheduleDropExpand(on: targetID) }
    }

    func dropExited(info: DropInfo) {
        isTargeted = false
        Task { @MainActor in store.cancelDropExpand(on: targetID) }
    }

    func performDrop(info: DropInfo) -> Bool {
        isTargeted = false
        Task { @MainActor in store.cancelDropExpand(on: targetID) }
        guard let provider = info.itemProviders(for: [.plainText]).first else {
            return false
        }
        provider.loadObject(ofClass: NSString.self) { object, _ in
            guard let string = object as? String,
                  let draggedID = UUID(uuidString: string) else { return }
            Task { @MainActor in
                guard let target = store.moveTarget(
                    draggedID: draggedID,
                    onto: targetID
                ) else { return }
                store.dispatch(.move(draggedID, parentID: target.parentID, index: target.index))
            }
        }
        return true
    }
}

/// 就地文本编辑：单击选中，双击进入编辑，Return 提交，Esc 取消。
private struct EditableTextCell: View {
    let text: String
    let value: String
    let enabled: Bool
    let onCommit: (String) -> Void

    @State private var editing = false
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        Group {
            if editing {
                TextField("", text: $draft)
                    .textFieldStyle(.plain)
                    .font(.system(size: DesignTokens.bodyFontSize))
                    .focused($focused)
                    .onSubmit { commit() }
                    .onExitCommand { editing = false }
                    .onChange(of: focused) { _, isFocused in
                        if !isFocused { commit() }
                    }
            } else {
                Text(text)
                    .font(.system(size: DesignTokens.bodyFontSize))
                    .foregroundStyle(enabled ? DesignTokens.textPrimary : DesignTokens.textSecondary)
                    .lineLimit(1)
                    .onTapGesture(count: 2) {
                        guard enabled else { return }
                        draft = value
                        editing = true
                        DispatchQueue.main.async { focused = true }
                    }
            }
        }
        .padding(.horizontal, 4)
    }

    private func commit() {
        guard editing else { return }
        editing = false
        focused = false
        onCommit(draft)
    }
}

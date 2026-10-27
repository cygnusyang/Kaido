import AppKit
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
    /// 行区域列交界拖宽（D-033）：与表头手柄共用同一条回调链。
    /// 缺省空实现：只读渲染（测试、截图）不接也能跑，行为与引入本机制前一致。
    var onResizeChanged: (OutlineColumn, CGFloat) -> Void = { _, _ in }
    var onResizeEnded: (Bool) -> Void = { _ in }
    var onResizeReset: (OutlineColumn) -> Void = { _ in }

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
        .clipped()
        .background(DesignTokens.surfaceBase)
        // 交界命中带盖在行之上：表头手柄只有 44pt 高，用户在行上抓交界必须也能调宽（D-033）。
        // 覆盖层用 offset 定位、不占布局：行节距仍严格等于 rowHeight（与画布对齐）。
        .overlay(alignment: .topLeading) {
            OutlineColumnResizeOverlay(
                layout: layout,
                onResizeChanged: onResizeChanged,
                onResizeEnded: onResizeEnded,
                onResizeReset: onResizeReset
            )
        }
    }
}

/// 列宽计算：非标题列随大纲宽度等比压缩，标题列吃掉剩余宽度。
struct OutlineColumnLayout {
    let columns: [OutlineColumn]
    let totalWidth: CGFloat
    let focused: Bool
    /// 用户列宽覆盖（点，F-14-20）：命中时不再乘压缩系数，否则拖宽无效。
    var widthOverrides: [OutlineColumn: Double] = [:]
    /// 拖拽中的预览草稿（列 + 点宽）：优先于覆盖值，松手才提交。
    var liveResize: (column: OutlineColumn, width: CGFloat)? = nil
    /// 内容自适应宽度（点，#48）：键缺省 = 该列仍用派生宽（乘压缩系数）。
    ///
    /// 值**不乘**压缩系数：序号被压窄就是「显示不全」，宁可挤掉任务说明的余量。
    /// 用户显式拖过的宽度仍然优先——那是用户看过内容后的主动选择（`widthRange` 兜住过窄的值）。
    var contentWidths: [OutlineColumn: CGFloat] = [:]

    /// 压缩系数：以 600pt 为基准，最窄压到 0.6；聚焦标签栏不压缩。
    private var scale: CGFloat {
        focused ? 1 : min(max(totalWidth / 600, 0.6), 1)
    }

    /// 列宽优先级：拖拽草稿 → 用户覆盖值（不压缩）→ 内容自适应宽（不压缩）→ 默认派生宽（乘压缩系数）。
    /// 三者皆无、即无用户配置时与引入本机制前逐位一致。
    func width(of column: OutlineColumn) -> CGFloat {
        if column == .title {
            return max(totalWidth - fixedWidthTotal, focused ? 0 : 120)
        }
        if let live = liveResize, live.column == column {
            return max(live.width, 0)
        }
        // 聚焦标签栏（180pt）忽略用户宽度，避免计划模式拖过的宽度在聚焦模式里串味。
        if !focused, let override = widthOverrides[column] {
            return CGFloat(override)
        }
        // 内容自适应（#48）：按当前项目实际内容量出来的宽度，不参与压缩。
        if !focused, let content = contentWidths[column] {
            return content
        }
        return CGFloat(column.width(bodyFontSize: 13)) * scale
    }

    private var fixedWidthTotal: CGFloat {
        columns.filter { $0 != .title }.reduce(0) { $0 + width(of: $1) }
    }

    /// 可拖宽列的交界（D-033）：行区域据此铺命中带，表头手柄也按同一右缘定位。
    ///
    /// 三条边界规则：弹性列（任务说明）不参与；聚焦标签栏整体不提供调宽；
    /// 列宽合计溢出大纲宽时，落在视口外（`x > totalWidth`）的交界直接丢弃——
    /// 那里已被裁切，铺出来的命中带用户点不到，只会挡住行点击。
    func resizeBoundaries() -> [OutlineColumnBoundary] {
        guard !focused else { return [] }
        var boundaries: [OutlineColumnBoundary] = []
        var edge: CGFloat = 0
        for column in columns {
            edge += width(of: column)
            guard OutlineColumnPreferences.isResizable(column), edge <= totalWidth else { continue }
            boundaries.append(
                OutlineColumnBoundary(column: column, x: edge, isLast: columns.last == column)
            )
        }
        return boundaries
    }

    /// 各列中点（点，相对大纲左缘）与列顺序一一对应：表头拖拽重排的落点判定用。
    ///
    /// 中点而非边界：落点在左半区就排到该列之前、右半区排到之后，
    /// 与 Excel / 表格类应用的拖拽手感一致；边界判定在列窄时（18pt 图标列）会过于灵敏。
    func columnMidpoints() -> [(column: OutlineColumn, midX: CGFloat)] {
        var edge: CGFloat = 0
        return columns.map { column in
            let width = width(of: column)
            defer { edge += width }
            return (column, edge + width / 2)
        }
    }

    /// 行首重排握把的左缘（点，相对大纲左缘）：优先序号列——该格无交互，单击即选中，
    /// 覆盖它不损失任何操作；聚焦标签栏没有序号列时退到违例列（图标列同样无交互）。
    /// 状态列只有 18pt 且有菜单，任何情况下都不做握把宿主。
    var dragGripOffset: CGFloat {
        for host in [OutlineColumn.number, .violation] {
            guard let index = columns.firstIndex(of: host) else { continue }
            return columns[..<index].reduce(0) { $0 + width(of: $1) }
        }
        return 0
    }
}

/// 列交界（D-033）：`x` 是列右缘，`band` 是行区域命中带。
///
/// 命中带内缩进列内（`x - hotZone ... x`），与表头手柄同一口径，光标落在同一位置；
/// 末列右缘就是大纲/画布分界手柄，整带再内缩一个热区，两种拖拽不互相抢。
struct OutlineColumnBoundary: Equatable {
    let column: OutlineColumn
    let x: CGFloat
    let isLast: Bool

    var band: ClosedRange<CGFloat> {
        let hot = OutlineColumnResizeMetrics.hotZone
        return isLast ? (x - 2 * hot)...(x - hot) : (x - hot)...x
    }
}

/// 列交界手势口径（D-033）：表头手柄与行区域命中带必须取同一组数值，
/// 否则同一列在表头与行上手感不一致（历史上表头 6pt、行上无命中区）。
enum OutlineColumnResizeMetrics {
    /// 交界命中带宽度（点）：6pt 实测抓不住，统一放宽到 8pt。
    static let hotZone: CGFloat = 8
    /// 提交阈值（点）：小于该位移视为抖动，避免单击交界写入粘滞覆盖值。
    static let commitThreshold: CGFloat = 2
}

/// 重排握把口径（D-033）。
enum OutlineReorderMetrics {
    /// 握把宽度（点）：窄于 12pt 按不住，宽于 16pt 会吃掉序号列的可读宽度。
    static let gripWidth: CGFloat = 12

    /// 表头拖拽重排的启动位移（点）：与列交界热区同值 8pt（D-033）。
    ///
    /// 小于该值的按下松手仍按单击处理——否则「点了下列头」会被当成一次 0 位移重排。
    static let minimumDrag: CGFloat = 8

    /// 插入位置竖线宽度（点）。
    static let insertionLineWidth: CGFloat = 2
}

/// 表头拖拽重排的坐标空间（v0.16 / #12）：落点要换算成「相对大纲左缘的 x」，
/// 只能是表头自身命名空间——手势挂在单元格上，用 .local 会得到单元格内的相对坐标。
enum OutlineHeaderSpace {
    static let name = "kairo.outline.header"
}

/// 大纲表头：列标题 + 每列右缘的调宽手柄 + 右键列显隐菜单（F-14-20）。
///
/// 手柄只在表头出现；列宽拖拽期间只回调预览草稿（`onResizeChanged`），
/// 松手才由 `onResizeEnded` 提交一次，避免每帧落盘（设计 R1）。
struct OutlineHeaderView: View {
    let layout: OutlineColumnLayout
    /// 当前隐藏的列：右键菜单勾选态的数据源。
    let hiddenColumns: Set<OutlineColumn>
    let onResizeChanged: (OutlineColumn, CGFloat) -> Void
    /// 松手：参数为「是否应提交」（<2pt 视为误触，只清草稿）。
    let onResizeEnded: (Bool) -> Void
    let onResizeReset: (OutlineColumn) -> Void
    let onToggleColumn: (OutlineColumn) -> Void
    /// 拖拽重排落点（v0.16 / #12）：参数为（被拖列，插入下标）。
    /// 下标语义见 `OutlineColumnPreferences.movedOrder(_:visible:moving:toInsertionIndex:)`。
    let onMoveColumn: (OutlineColumn, Int) -> Void
    /// 右键「重置列顺序」：回到 `OutlineColumnPreferences.defaultOrder`。
    let onResetColumnOrder: () -> Void

    /// 正在被拖的列（nil = 未在重排）：拖动时置灰自身、显示插入位置竖线。
    @State private var dragging: OutlineColumn?
    /// 拖动中的落点 x（点，相对大纲左缘）。
    @State private var dropX: CGFloat?

    var body: some View {
        HStack(spacing: 0) {
            ForEach(layout.columns, id: \.self) { column in
                Text(headerTitle(column))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(1)
                    .padding(.horizontal, 4)
                    .frame(width: layout.width(of: column), alignment: .leading)
                    // 分界：列头中部拖 = 重排（v0.16），右缘 8pt 拖 = 调宽（overlay 在上层，
                    // highPriorityGesture 先拿到命中，两套手势不抢）。
                    .contentShape(Rectangle())
                    .opacity(dragging == column ? 0.45 : 1)
                    // 聚焦标签栏不提供重排：那里列集合恒为三列、不受用户顺序影响，
                    // 拖动只会改到看不见的全局偏好（拖了没反应，却悄悄改了别的标签页）。
                    .gesture(reorderGesture(column), including: layout.focused ? .none : .all)
                    .help(I18n.t("outline.column_order.help", "Drag the column header to reorder columns"))
                    .overlay(alignment: .trailing) {
                        // 聚焦标签栏不提供调宽；末列手柄内缩一个热区，避开大纲右边界手柄。
                        if OutlineColumnPreferences.isResizable(column), !layout.focused {
                            OutlineColumnResizeHandle(
                                baseWidth: layout.width(of: column),
                                isLastColumn: layout.columns.last == column,
                                onChanged: { onResizeChanged(column, $0) },
                                onEnded: onResizeEnded,
                                onReset: { onResizeReset(column) }
                            )
                        }
                    }
            }
        }
        // 手势落点要相对大纲左缘，命名空间只能挂在表头自身（见 `OutlineHeaderSpace`）。
        .coordinateSpace(name: OutlineHeaderSpace.name)
        .frame(maxHeight: .infinity, alignment: .bottom)
        .padding(.bottom, 4)
        // leading 锚定 + 裁切：列宽总和超过大纲宽时从右侧裁切，与行列表的 topLeading 一致。
        .frame(width: layout.totalWidth, alignment: .topLeading)
        .clipped()
        .overlay(alignment: .topLeading) { insertionLine }
        .background(DesignTokens.surfaceChrome)
        .contextMenu { columnMenu }
    }

    /// 插入位置竖线：拖动中显示，落在「松手后该列会占据的左缘」。
    @ViewBuilder
    private var insertionLine: some View {
        if dragging != nil, let dropX {
            Rectangle()
                .fill(DesignTokens.accentStrong)
                .frame(width: OutlineReorderMetrics.insertionLineWidth)
                .offset(x: clampedDropX(dropX))
                .allowsHitTesting(false)
        }
    }

    /// 竖线夹取到表头范围内（半宽内缩），避免贴边时被 `.clipped()` 裁掉半条。
    private func clampedDropX(_ x: CGFloat) -> CGFloat {
        let half = OutlineReorderMetrics.insertionLineWidth / 2
        return min(max(x - half, 0), max(layout.totalWidth - OutlineReorderMetrics.insertionLineWidth, 0))
    }

    /// 表头中部拖拽 = 重排：位移不足 `minimumDrag` 不启动（仍是单击语义）。
    private func reorderGesture(_ column: OutlineColumn) -> some Gesture {
        DragGesture(
            minimumDistance: OutlineReorderMetrics.minimumDrag,
            coordinateSpace: .named(OutlineHeaderSpace.name)
        )
        .onChanged { value in
            dragging = column
            dropX = value.location.x
        }
        .onEnded { value in
            let index = insertionIndex(at: value.location.x, excluding: column)
            let moved = dragging
            dragging = nil
            dropX = nil
            guard let moved else { return }
            onMoveColumn(moved, index)
        }
    }

    /// 落点 → 插入下标：中点为分界，且**不含被拖列**（拖动期间列宽不变，位置可直接复用）。
    private func insertionIndex(at x: CGFloat, excluding column: OutlineColumn) -> Int {
        let midpoints = layout.columnMidpoints()
            .filter { $0.column != column }
            .map { Double($0.midX) }
        return OutlineColumnPreferences.insertionIndex(dropX: Double(x), midpoints: midpoints)
    }

    /// 列显隐菜单：序号/任务说明固定显示，不出现在开关列表（`configurable` 已排除）。
    ///
    /// 末尾固定一条「重置列顺序」：拖乱之后必须有出口，否则只能逐列往回拖（且拖不回被隐藏列的槽位）。
    @ViewBuilder
    private var columnMenu: some View {
        ForEach(OutlineColumnPreferences.toggleable, id: \.self) { column in
            Toggle(isOn: Binding(
                get: { !hiddenColumns.contains(column) },
                set: { _ in onToggleColumn(column) }
            )) {
                // 标签只写列名：勾选态本身表达显示/隐藏。
                Text(I18n.t("outline.column_toggle.label", "%1$@ column", Display.outlineColumnTitle(column)))
            }
        }
        Divider()
        Button(I18n.t("outline.column_order.reset", "Reset Column Order")) {
            onResetColumnOrder()
        }
    }

    private func headerTitle(_ column: OutlineColumn) -> String {
        switch column {
        case .status: return ""
        case .violation: return "!"
        case .number: return "#"
        case .title: return I18n.t("column.header.title", "Task")
        case .predecessors: return I18n.t("column.header.predecessors", "Pred.")
        case .start: return I18n.t("column.start", "Start")
        case .finish: return I18n.t("column.finish", "Finish")
        case .actualStart: return I18n.t("column.actual_start", "Actual start")
        case .actualFinish: return I18n.t("column.actual_finish", "Actual finish")
        case .baselineStart: return I18n.t("column.baseline_start", "Baseline start")
        case .baselineFinish: return I18n.t("column.baseline_finish", "Baseline finish")
        case .startVariance: return I18n.t("column.start_variance", "Plan start variance")
        case .finishVariance: return I18n.t("column.finish_variance", "Plan finish variance")
        case .duration: return I18n.t("column.header.duration", "Dur.")
        case .assignee: return I18n.t("column.header.assignee", "Owner")
        case .progress: return I18n.t("column.header.progress", "Done")
        }
    }
}

/// 表头列宽手柄：叠在列右缘的 8pt 热区（口径见 `OutlineColumnResizeMetrics`）。
///
/// 行区域另有整列高度的同类命中带（`OutlineColumnResizeOverlay`），两者共用同一组
/// 宽度与提交阈值，保证表头与行上手感一致（D-033）。
///
/// - hover 切左右调整光标并显示 1pt 高亮（设计 §2）；
/// - 拖拽以手势开始时的列宽为基准，避免与已回写的预览草稿重复累加；
/// - 双击复位该列（删除覆盖值）。
private struct OutlineColumnResizeHandle: View {
    /// 手势开始时的列宽（点）；每次求值由表头按当前布局给出。
    let baseWidth: CGFloat
    /// 是否末列：末列右缘与大纲右边界手柄重合，需内缩让出热区。
    var isLastColumn: Bool = false
    let onChanged: (CGFloat) -> Void
    /// 松手：参数为「是否应提交」——抖动不足 2pt（误触）时只清草稿、不写覆盖值。
    let onEnded: (Bool) -> Void
    let onReset: () -> Void

    @State private var dragBase: CGFloat?
    @State private var hovering = false

    /// 右缘热区：与行区域命中带同值，避免「表头抓得住、行上抓不住」。
    private static let hotZoneWidth = OutlineColumnResizeMetrics.hotZone
    /// 提交阈值：与行区域同值。
    private static let commitThreshold = OutlineColumnResizeMetrics.commitThreshold

    var body: some View {
        Color.clear
            .frame(width: Self.hotZoneWidth)
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(DesignTokens.accentStrong)
                    .frame(width: 1)
                    .opacity(hovering || dragBase != nil ? 1 : 0)
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            // 表头位于滚动容器之外的固定区，仍用 highPriorityGesture 与行选中手势隔离。
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragBase == nil { dragBase = baseWidth }
                        guard let base = dragBase else { return }
                        onChanged(base + value.translation.width)
                    }
                    .onEnded { value in
                        dragBase = nil
                        onEnded(abs(value.translation.width) >= Self.commitThreshold)
                    }
            )
            .onTapGesture(count: 2) { onReset() }
            // 拖拽被系统中断（切模式/换项目/窗口失焦）时 onEnded 不保证触发：
            // 这里兜底清草稿并复位光标，避免未提交宽度长期驻留。
            .onDisappear {
                if dragBase != nil {
                    dragBase = nil
                    onEnded(false)
                }
                if hovering {
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
            .offset(x: isLastColumn ? -Self.hotZoneWidth : 0)
            .accessibilityHidden(true)
            .help(I18n.t("outline.column_width.help", "Drag to resize the column; double-click to reset"))
    }
}

/// 行区域列交界命中带（D-033）：把表头那 8pt 热区沿整列高度铺下来。
///
/// 表头手柄只有 44pt 高，用户在行上把光标放到列交界处左右拖过去没有任何响应——
/// 既没调宽，也没选中（指针移动让行 tap 失效），这正是 D-033 的「拖了半天没反应」。
/// 这里按 `layout.resizeBoundaries()` 铺命中带，回调、阈值、双击复位与表头完全同一套。
struct OutlineColumnResizeOverlay: View {
    let layout: OutlineColumnLayout
    let onResizeChanged: (OutlineColumn, CGFloat) -> Void
    let onResizeEnded: (Bool) -> Void
    let onResizeReset: (OutlineColumn) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.resizeBoundaries(), id: \.column) { boundary in
                OutlineColumnResizeBand(
                    baseWidth: layout.width(of: boundary.column),
                    onChanged: { onResizeChanged(boundary.column, $0) },
                    onEnded: onResizeEnded,
                    onReset: { onResizeReset(boundary.column) }
                )
                .frame(width: OutlineColumnResizeMetrics.hotZone)
                .offset(x: boundary.band.lowerBound)
            }
        }
        // 只有命中带参与命中：带外的行点击、右键菜单、拖拽重排照常穿透到行。
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// 单条交界命中带：hover 变左右调整光标 + 1pt 高亮，拖动改预览宽，双击复位。
private struct OutlineColumnResizeBand: View {
    /// 手势开始时的列宽（点）：以起点为基准，不回读已回写的预览草稿。
    let baseWidth: CGFloat
    let onChanged: (CGFloat) -> Void
    /// 松手：参数为「是否应提交」（<2pt 视为误触，只清草稿）。
    let onEnded: (Bool) -> Void
    let onReset: () -> Void

    @State private var dragBase: CGFloat?
    @State private var hovering = false

    var body: some View {
        Color.clear
            .contentShape(Rectangle())
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(DesignTokens.accentStrong)
                    .frame(width: 1)
                    .opacity(hovering || dragBase != nil ? 1 : 0)
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.resizeLeftRight.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            // 覆盖层位于行之上：highPriorityGesture 保证按下即进调宽，不被行 tap 抢走。
            .highPriorityGesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragBase == nil { dragBase = baseWidth }
                        guard let base = dragBase else { return }
                        onChanged(base + value.translation.width)
                    }
                    .onEnded { value in
                        dragBase = nil
                        onEnded(abs(value.translation.width) >= OutlineColumnResizeMetrics.commitThreshold)
                    }
            )
            .onTapGesture(count: 2) { onReset() }
            // 拖拽被系统中断（切模式/换项目/窗口失焦）时 onEnded 不保证触发：兜底清草稿。
            .onDisappear {
                if dragBase != nil {
                    dragBase = nil
                    onEnded(false)
                }
                if hovering {
                    hovering = false
                    NSCursor.arrow.set()
                }
            }
            .help(I18n.t("outline.column_width.help", "Drag to resize the column; double-click to reset"))
            .accessibilityHidden(true)
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
    /// 行内状态菜单选了「已取消」：先弹原因层（D-037），确认后才提交。
    @State private var cancelPromptRow: UUID?

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
        // 重排只挂本 modifier 的 onDrop：拖拽源在行首握把（见下），行本身不再注册 onDrag，
        // 否则指针一抖就被拖拽会话接管，单击选中会丢失（D-033）。
        .modifier(ReorderDropModifier(
            enabled: store.allowsDragReorder,
            taskID: row.id,
            store: store,
            isTargeted: $dropTargeted
        ))
        .overlay(alignment: .leading) {
            // 行首握把：显式拖拽入口，单击握把同样是选中（序号格本来无交互）。
            if store.allowsDragReorder {
                OutlineReorderGrip(store: store, taskID: row.id)
                    .offset(x: layout.dragGripOffset)
            }
        }
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

    /// 基线承诺日期列的 tooltip（区别于排期结果列）。
    private static let baselineDateHelp = I18n.t("column.baseline.help", "Committed baseline date")

    /// 偏差列 tooltip：说明符号方向（列名只说「计划偏差」，方向在这里讲清）。
    private static let varianceHelp = I18n.t(
        "column.variance.help",
        "Plan variance (plan − baseline). Positive = later, negative = earlier."
    )

    /// 只读日期列（实际开始 / 实际结束 / 基线起止）：大纲只展示，编辑入口在检查器。
    /// 口径与既有日期列一致（`Display.date`，无值 `—`）。
    private func readOnlyDateCell(_ value: Date?, help: String? = nil) -> some View {
        Text(Display.date(value))
            .font(.system(size: DesignTokens.captionFontSize))
            .monospacedDigit()
            .foregroundStyle(value == nil ? DesignTokens.textSecondary : DesignTokens.textPrimary)
            .padding(.horizontal, 4)
            .lineLimit(1)
            .help(help ?? Display.date(value))
            .accessibilityLabel(value.map { Display.longDate($0) } ?? Display.placeholder)
    }

    /// 偏差列（v0.13）：只读、带符号；正数用逾期色、负数用成功色，空缺/0 走次要色。
    ///
    /// 空缺显示占位符而不是 0：0 表示准时，二者不能混（08 §4.1）。
    private func varianceCell(_ days: Int?) -> some View {
        Text(Display.varianceDays(days))
            .font(.system(size: DesignTokens.captionFontSize))
            .monospacedDigit()
            .foregroundStyle(varianceColor(days))
            .padding(.horizontal, 4)
            .lineLimit(1)
            .help(Self.varianceHelp)
            .accessibilityLabel(Display.varianceDays(days))
    }

    private func varianceColor(_ days: Int?) -> Color {
        guard let days else { return DesignTokens.textSecondary }
        if days > 0 {
            return DesignTokens.semanticText(DesignTokens.overdue, isSelected: isSelected)
        }
        if days < 0 {
            return DesignTokens.semanticText(DesignTokens.statusSuccess, isSelected: isSelected)
        }
        return DesignTokens.textSecondary
    }

    @ViewBuilder
    private func cell(_ column: OutlineColumn) -> some View {
        switch column {
        case .status:
            statusCell
        case .violation:
            violationCell
        case .number:
            // 序号右对齐（数字列惯例）：左对齐时多级序号（1.1 / 10.12）会贴着列左缘
            // 被行裁剪吃掉首位，用户看到的就是「序号显示不全」（v0.14.5）。
            Text(row.outlineNumber)
                .font(.system(size: DesignTokens.captionFontSize))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(DesignTokens.textSecondary)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .padding(.trailing, 6)
        case .title:
            titleCell
        case .predecessors:
            EditableTextCell(
                text: row.predecessorsText.isEmpty ? "—" : row.predecessorsText,
                value: row.predecessorsText,
                enabled: OutlineTextCellEditing.isEditable(column: .predecessors, isAggregate: row.isAggregate),
                onCommit: { store.dispatch(.setPredecessors(row.id, $0)) }
            )
        case .start:
            OutlineDateCell(
                column: .start,
                row: row,
                isSelected: isSelected,
                onOpen: { store.dispatch(.select(row.id)) },
                onCommit: { store.dispatch(.setTaskStart(row.id, $0)) }
            )
        case .finish:
            OutlineDateCell(
                column: .finish,
                row: row,
                isSelected: isSelected,
                onOpen: { store.dispatch(.select(row.id)) },
                onCommit: { date in
                    // 结束列不提供「清除」，`nil` 只可能来自清除（该列 `allowsClear` 为假，实际不可达）。
                    // 起点取同一快照行：Store 会用它做「排期已变化」与「结束晚于开始」两重校验（设计 R2）。
                    // 参数由策略纯函数给出：列禁用或快照没有排期起点时整体不提交，
                    // 不拿结束日兜底当起点（那会折算成 0 天并掩盖真实原因）。
                    guard let date,
                          let commit = OutlineDateEditing.finishCommit(row: row, finish: date) else {
                        return
                    }
                    store.dispatch(.setTaskFinish(
                        row.id,
                        finish: commit.finish,
                        start: commit.start
                    ))
                }
            )
        case .actualStart:
            readOnlyDateCell(row.actualStart)
        case .actualFinish:
            readOnlyDateCell(row.actualFinish)
        case .baselineStart:
            readOnlyDateCell(row.baselineStart, help: Self.baselineDateHelp)
        case .baselineFinish:
            readOnlyDateCell(row.baselineFinish, help: Self.baselineDateHelp)
        case .startVariance:
            varianceCell(row.planStartVariance)
        case .finishVariance:
            varianceCell(row.planFinishVariance)
        case .duration:
            EditableTextCell(
                text: row.durationDays.map { Display.duration($0) } ?? "—",
                value: row.durationDays.map { String(format: "%g", $0) } ?? "",
                enabled: OutlineTextCellEditing.isEditable(column: .duration, isAggregate: row.isAggregate),
                onCommit: { store.dispatch(.setDuration(row.id, Double($0))) }
            )
        case .assignee:
            EditableTextCell(
                text: row.assignee ?? "—",
                value: row.assignee ?? "",
                enabled: OutlineTextCellEditing.isEditable(column: .assignee, isAggregate: row.isAggregate),
                onCommit: { text in
                    let trimmed = text.trimmingCharacters(in: .whitespaces)
                    store.dispatch(.setAssignee(row.id, trimmed.isEmpty ? nil : trimmed))
                }
            )
        case .progress:
            progressCell
        }
    }

    private var statusCell: some View {
        Menu {
            // 「已取消」必须先填原因（D-037）：行内菜单同样走弹层，不再把该项藏起来 ——
            // 判据由 `OutlineStatusAction` 统一给出，检查器与本处共用一份，避免两处规则分叉。
            ForEach(TaskStatus.allCases, id: \.self) { status in
                Button {
                    switch OutlineStatusAction.forSelection(status, current: row.status) {
                    case .apply(let target):
                        store.dispatch(.setStatus(row.id, target))
                    case .promptCancelReason:
                        cancelPromptRow = row.id
                    }
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
        .sheet(isPresented: Binding(
            get: { cancelPromptRow != nil },
            set: { if !$0 { cancelPromptRow = nil } }
        )) {
            CancelReasonDialog(taskTitle: row.title) { reason in
                if let taskID = cancelPromptRow {
                    store.dispatch(.cancelTask(taskID, reason: reason))
                }
                cancelPromptRow = nil
            }
        }
    }

    private var statusColor: Color {
        switch row.status {
        case .pending: return DesignTokens.textSecondary
        case .inProgress: return DesignTokens.accentStrong
        case .blocked: return DesignTokens.violationWarning
        case .done: return DesignTokens.statusSuccess
        case .cancelled: return DesignTokens.textSecondary
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
                .help(I18n.t("outline.violation_count.help", "%1$ld violations", row.violationCount))
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
                TextField(I18n.t("outline.title.placeholder", "Task title"), text: Binding(
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
                Text(row.title.isEmpty ? I18n.t("outline.untitled", "Untitled") : row.title)
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
                    .help(Display.priorityTitle(.critical))
            }
            if row.isOverdue {
                Image(systemName: "clock")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.semanticText(
                        DesignTokens.overdue,
                        isSelected: isSelected
                    ))
                    .help(I18n.t("outline.overdue", "Overdue"))
            }
            if row.deadlineRisk {
                Image(systemName: "exclamationmark.circle")
                    .font(.system(size: 9))
                    .foregroundStyle(DesignTokens.semanticText(
                        DesignTokens.violationWarning,
                        isSelected: isSelected
                    ))
                    .help(I18n.t("outline.deadline_risk.help", "Scheduled finish is after the due date"))
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
        Button(I18n.t("action.new_sibling", "New Sibling Task")) {
            store.dispatch(.createSibling(after: row.id))
        }
        Button(I18n.t("action.new_child", "New Subtask")) {
            store.dispatch(.createTask(parentID: row.id, kind: .task))
        }
        Button(I18n.t("action.copy_task_link", "Copy Task Link")) {
            store.dispatch(.copyTaskLink(row.id))
        }
        Divider()
        Button(I18n.t("action.indent", "Indent")) { store.dispatch(.indent(row.id)) }
        Button(I18n.t("action.outdent", "Outdent")) { store.dispatch(.outdent(row.id)) }
        if row.kind == .group {
            Divider()
            Button(I18n.t("action.new_group", "New Group")) { store.dispatch(.createTask(parentID: row.id, kind: .group)) }
            Button(I18n.t("action.new_milestone", "New Milestone")) { store.dispatch(.createTask(parentID: row.id, kind: .milestone)) }
        }
        Divider()
        Button(I18n.t("action.delete", "Delete"), role: .destructive) {
            store.requestDelete(id: row.id)
        }
    }
}

/// 行只做落点，不做拖拽源：筛选激活时不注册任何拖拽，避免「可拖但目标不可见」的半成品交互。
///
/// 拖拽源（`onDrag`）在行首握把 `OutlineReorderGrip` 上。整行挂 `onDrag` 会在指针
/// 按下并轻微移动时启动拖拽会话，把单击选中吃掉（D-033：用户报「选不中」）。
private struct ReorderDropModifier: ViewModifier {
    let enabled: Bool
    let taskID: UUID
    let store: WorkspaceStore
    @Binding var isTargeted: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(
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

/// 行首拖拽握把（D-033）：重排的唯一拖拽入口。
///
/// 位置取序号列（`layout.dragGripOffset`）：该格无交互，单击握把同样派发选中，
/// 所以这 12pt 不损失任何操作；状态列只有 18pt 且带菜单，覆盖它会让状态菜单点不到。
/// 悬停握把本身才显示三颗竖排小点，行悬停不遮挡序号读数。
private struct OutlineReorderGrip: View {
    @ObservedObject var store: WorkspaceStore
    let taskID: UUID

    @State private var hovering = false

    private static let help = I18n.t(
        "outline.reorder_grip.help",
        "Drag to reorder; click to select"
    )

    var body: some View {
        Color.clear
            .frame(width: OutlineReorderMetrics.gripWidth)
            .contentShape(Rectangle())
            .overlay {
                VStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in
                        Circle()
                            .fill(DesignTokens.textSecondary)
                            .frame(width: 2, height: 2)
                    }
                }
                .opacity(hovering ? 1 : 0)
            }
            .onHover { inside in
                hovering = inside
                if inside {
                    NSCursor.openHand.set()
                } else {
                    NSCursor.arrow.set()
                }
            }
            .onDrag {
                // 拖拽起手即选中：与整行点击的语义一致，重排过程中检查器跟着走。
                store.dispatch(.select(taskID))
                return NSItemProvider(object: taskID.uuidString as NSString)
            }
            // 单击握把仍然是「选中这一行」：手势挂在 onDrag 之外，普通点击不会被吃掉。
            .onTapGesture { store.dispatch(.select(taskID)) }
            .help(Self.help)
            .accessibilityLabel(Self.help)
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

/// 大纲日期单元格（F-14-19）：显示排期值，点击开月历弹层写回。
///
/// 只服务 `.start` / `.finish` 两列。可编辑性、禁用原因、最小可选日、清除显隐
/// 全部取自 `OutlineDateEditing`（纯函数策略）——单元格不判语义，也不持有 store：
/// 选中与写回经 `onOpen` / `onCommit` 回到行的接线点。
private struct OutlineDateCell: View {
    /// 日期列（`.start` / `.finish`）。
    let column: OutlineColumn
    let row: PlanRow
    let isSelected: Bool
    /// 弹层打开前回调（行选中同步）。
    let onOpen: () -> Void
    /// 提交选中日期；`nil` 只可能来自「清除」（仅开始列提供）。
    let onCommit: (Date?) -> Void

    /// 弹层开关与浏览月独立于标题编辑的 `editingTaskID`：翻月不改值，重开保留上月视图。
    @State private var isPresented = false
    /// 浏览月恒为「当月 1 日」：与 `CalendarGrid` 的口径一致，首次打开时再定位到选中值所在月。
    @State private var visibleMonth = CalendarGrid.month(containing: Date()).firstDay
    /// 上次打开时看到的值：用来识别「值被外部改动」（撤销、画布拖拽、检查器改写）。
    @State private var knownValue: Date?
    @State private var hasKnownValue = false

    /// 结束列越界格的 tooltip / 无障碍说明；与检查器「结束」行同一文案。
    private static let finishBoundaryHint = I18n.t("date.field.finish_boundary_hint", "The finish must be later than the start, at least 1 day")

    var body: some View {
        // 单一视图 + 条件 help：`if let / else` 会因分支切换换掉视图类型，连带丢掉 @State
        //（弹层开关、浏览月），tooltip 也就成了「一显示就重建」。
        content.modifier(OutlineDateHelpModifier(text: helpText))
    }

    /// 文案 + 点击 + 弹层；tooltip 由 `body` 按需附加（空文案不生成 tooltip）。
    private var content: some View {
        Text(Display.date(value))
            .font(.system(size: DesignTokens.bodyFontSize))
            .monospacedDigit()
            .foregroundStyle(foreground)
            .padding(.horizontal, 4)
            .contentShape(Rectangle())
            .onTapGesture(perform: toggle)
            .popover(
                isPresented: $isPresented,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                CalendarPopover(
                    label: label,
                    selection: selection,
                    minimumDate: minimumDate,
                    allowsClear: column == .start,
                    canClear: OutlineDateEditing.canClear(column: column, row: row),
                    quickActions: DateQuickAction.allCases,
                    preview: { previewText(for: $0) },
                    disabledDayHint: column == .finish ? Self.finishBoundaryHint : nil,
                    visibleMonth: $visibleMonth,
                    onPick: commit,
                    onDismiss: { isPresented = false }
                )
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(Display.isoDate(value))
            .accessibilityHint(isEnabled ? I18n.t("date.field.open_calendar", "Open the calendar to pick a date") : (disabledReason ?? ""))
            .accessibilityAddTraits(isEnabled ? .isButton : [])
    }

    // MARK: - 策略

    private var isEnabled: Bool {
        OutlineDateEditing.isEnabled(column: column, row: row)
    }

    /// 不可编辑时的解释文案；可编辑为 nil（文案由视图按语义原因查 Catalog，F-0705）。
    private var disabledReason: String? {
        Display.dateFieldDisabledReason(OutlineDateEditing.availability(column: column, row: row))
    }

    private var minimumDate: Date? {
        OutlineDateEditing.minimumDate(column: column, row: row)
    }

    /// 列显示值：开始列是排期起点（可能被依赖后移）；结束列是排期排他端点。
    ///
    /// 结束日夹取到最小可选日（设计 R3）：亚日持续时间会让原始结束日落在
    /// 「起点 + 1 天」之前，弹层里就会出现「已选中但不可选」的死格。
    /// 口径与检查器一致（`DateFieldValueMath.clampedFinish`）。
    private var value: Date? {
        switch column {
        case .start:
            return row.scheduledStart
        case .finish:
            guard let finish = row.scheduledFinish else { return nil }
            return DateFieldValueMath.clampedFinish(finish, minimumDate: minimumDate)
        default:
            return nil
        }
    }

    /// 弹层选中值 = 真正可编辑的那个值：开始列是意图起点（`startDate`，未设置时回落排期起点），
    /// 结束列与显示值同源。
    ///
    /// 与 `value` 分开是因为开始列「显示排期、编辑意图」（设计 §2）：显示值可能由依赖推后，
    /// 弹层里要落在用户实际设置的那一天，否则「已选中」与「能清除」会指向两个不同的日期。
    private var selection: Date? {
        switch column {
        case .start:
            return row.startDate ?? row.scheduledStart
        case .finish:
            return value
        default:
            return nil
        }
    }

    private var label: String {
        column == .start ? I18n.t("column.start", "Start") : I18n.t("column.finish", "Finish")
    }

    /// 无障碍标签：与检查器同一措辞（「开始日期」/「结束日期」）。
    private var accessibilityLabel: String {
        column == .start ? I18n.t("date.field.name.start", "Start date") : I18n.t("date.field.name.finish", "Finish date")
    }

    private var foreground: Color {
        guard isEnabled else { return DesignTokens.textSecondary }
        return row.isOverdue
            ? DesignTokens.semanticText(DesignTokens.overdue, isSelected: isSelected)
            : DesignTokens.textPrimary
    }

    /// tooltip：禁用时说明原因；开始列启用态说明「显示排期、编辑意图」的口径差异（设计 §2）。
    private var helpText: String? {
        guard isEnabled else { return disabledReason }
        return column == .start ? I18n.t("date.field.start_help", "Sets the earliest start date; dependencies may push the schedule later") : nil
    }

    // MARK: - 交互

    private func toggle() {
        // 行级 tap 手势会被单元格手势抢先吃掉，选中在这里主动同步（设计 §3.2 / R1）；
        // 禁用行同样同步选中，只是不开弹层——点禁用格仍能选中该行，不至于「点了没反应」。
        onOpen()
        guard isEnabled else { return }
        // 弹层已开时点击就是关闭（toggle），不重新定位浏览月。
        guard !isPresented else {
            isPresented = false
            return
        }
        // 首次打开定位到选中值所在月；只有外部改动（撤销、画布拖拽、检查器改写）
        // 才重新定位，否则保留用户上次翻到的月份。
        let changedExternally = hasKnownValue && !isSameDay(knownValue, selection)
        if !hasKnownValue || changedExternally {
            visibleMonth = CalendarGrid.month(containing: selection ?? Date()).firstDay
        }
        knownValue = selection
        hasKnownValue = true
        isPresented = true
    }

    private func commit(_ date: Date?) {
        knownValue = date
        hasKnownValue = true
        if let date {
            visibleMonth = CalendarGrid.month(containing: date).firstDay
        }
        isPresented = false
        onCommit(date)
    }

    private func isSameDay(_ lhs: Date?, _ rhs: Date?) -> Bool {
        switch (lhs, rhs) {
        case (nil, nil): return true
        case let (lhs?, rhs?): return Calendar.current.isDate(lhs, inSameDayAs: rhs)
        default: return false
        }
    }

    /// 弹层预览行：「开始 2026-10-22」/「结束 2026-10-25 · 4 天」。
    private func previewText(for candidate: Date?) -> String? {
        guard let candidate else { return nil }
        guard column == .finish,
              let start = row.scheduledStart,
              let days = ScheduleDateMath.durationDays(start: start, finish: candidate) else {
            return "\(label) \(Display.isoDate(candidate))"
        }
        return "\(label) \(Display.isoDate(candidate)) · \(Display.duration(days))"
    }
}

/// 只在有文案时附加 tooltip（空文案不生成 tooltip）。
///
/// 用 modifier 包住条件分支，调用方视图保持单一类型：`if let / else` 换分支会换视图类型，
/// 连带丢掉单元格的 `@State`（弹层开关、浏览月）。
private struct OutlineDateHelpModifier: ViewModifier {
    let text: String?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let text {
            content.help(text)
        } else {
            content
        }
    }
}

/// 大纲文本列（依赖 / 持续时间 / 负责人）的可编辑性（v0.16 / issue #16）。
///
/// 依赖列对群组行同样开放：群组的依赖由用户显式维护，不从子任务汇总得出，
/// 汇总口径只适用于日期、持续时间与进度。日期列不经过这里：OutlineDateEditing
/// 仍按 isAggregate 只读。纯函数，脱离 SwiftUI 可单测。
enum OutlineTextCellEditing {
    static func isEditable(column: OutlineColumn, isAggregate: Bool) -> Bool {
        switch column {
        case .predecessors:
            return true
        default:
            return !isAggregate
        }
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

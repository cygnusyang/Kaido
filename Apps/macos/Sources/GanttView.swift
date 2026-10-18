import SwiftUI
import KairoCore

/// 甘特视图基础（US-E4-04）：任务条、日期标头、缩放与非工作时段着色。
///
/// 布局几何由 `GanttLayoutEngine`（KairoCore 纯函数）计算，本视图只负责绘制
/// 与交互：拖动日期标头平移时间窗、缩放菜单切换日/周/月或「适合项目」、
/// 点击任务条或左侧标题选中任务。
struct GanttView: View {
    let tasks: [TaskItem]
    let schedule: ScheduleResult?
    let selection: UUID?
    let violationIDs: Set<UUID>
    let onSelect: (UUID?) -> Void

    @State private var zoom: GanttZoom = .week
    @State private var fitToWidth = true
    /// 用户平移后的窗口起点；nil = 取内容范围起点。
    @State private var windowStart: Date?
    /// 拖动开始时固定的每日宽度，避免从「适合项目」切到档位宽度时跳动。
    @State private var pinnedDayWidth: Double?
    @State private var dragAnchor: Date?

    private let labelWidth: CGFloat = 190
    private let rowHeight: CGFloat = 24
    private let headerHeight: CGFloat = 30

    /// 初始缩放与视窗参数供测试注入；应用内调用使用默认值。
    init(
        tasks: [TaskItem],
        schedule: ScheduleResult?,
        selection: UUID?,
        violationIDs: Set<UUID>,
        onSelect: @escaping (UUID?) -> Void,
        initialZoom: GanttZoom = .week,
        fitsToWidth: Bool = true,
        initialWindowStart: Date? = nil
    ) {
        self.tasks = tasks
        self.schedule = schedule
        self.selection = selection
        self.violationIDs = violationIDs
        self.onSelect = onSelect
        _zoom = State(initialValue: initialZoom)
        _fitToWidth = State(initialValue: fitsToWidth)
        _windowStart = State(initialValue: initialWindowStart)
    }

    private var calendar: Calendar { Calendar.current }

    var body: some View {
        GeometryReader { geo in
            let chartWidth = max(geo.size.width - labelWidth - 1, 120)
            let layout = makeLayout(chartWidth: chartWidth)
            VStack(spacing: 0) {
                headerRow(layout)
                Divider()
                ScrollView(.vertical) {
                    chartRows(layout)
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
    }

    // MARK: - 布局

    private func makeLayout(chartWidth: CGFloat) -> GanttLayout {
        let cal = calendar
        if fitToWidth,
           let content = GanttLayoutEngine.contentRange(tasks: tasks, schedule: schedule, calendar: cal) {
            let width = GanttLayoutEngine.fitDayWidth(
                contentRange: content,
                viewWidth: Double(chartWidth),
                calendar: cal
            )
            return GanttLayoutEngine.make(
                tasks: tasks,
                schedule: schedule,
                calendar: cal,
                zoom: zoom,
                viewWidth: Double(chartWidth),
                windowStart: content.start,
                dayWidthOverride: width
            )
        }
        return GanttLayoutEngine.make(
            tasks: tasks,
            schedule: schedule,
            calendar: cal,
            zoom: zoom,
            viewWidth: Double(chartWidth),
            windowStart: windowStart,
            dayWidthOverride: pinnedDayWidth
        )
    }

    // MARK: - 标头

    private func headerRow(_ layout: GanttLayout) -> some View {
        HStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("任务")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                zoomMenu
            }
            .padding(.horizontal, 8)
            .frame(width: labelWidth, height: headerHeight)
            Divider()
            headerTicks(layout)
                .frame(width: layout.windowWidth, height: headerHeight, alignment: .topLeading)
                .clipped()
                .contentShape(Rectangle())
                .gesture(panGesture(layout: layout))
        }
        .background(.bar)
    }

    private func headerTicks(_ layout: GanttLayout) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.bands.indices, id: \.self) { index in
                Rectangle()
                    .fill(Color.secondary.opacity(0.10))
                    .frame(width: layout.bands[index].width, height: headerHeight)
                    .offset(x: layout.bands[index].x)
            }
            ForEach(layout.ticks.indices, id: \.self) { index in
                tickView(layout.ticks[index])
            }
        }
    }

    private func tickView(_ tick: GanttLayout.Tick) -> some View {
        ZStack(alignment: .topLeading) {
            Rectangle()
                .fill(tick.isMajor ? Color.secondary.opacity(0.55) : Color.secondary.opacity(0.2))
                .frame(width: 1, height: headerHeight)
                .offset(x: tick.x)
            Text(tick.label)
                .font(tick.isMajor ? .caption.bold() : .caption2)
                .foregroundStyle(tick.isMajor ? .primary : .secondary)
                .fixedSize()
                .offset(x: tick.x + 3, y: 7)
        }
    }

    private var zoomMenu: some View {
        Menu {
            Button("日") { setZoom(.day) }
            Button("周") { setZoom(.week) }
            Button("月") { setZoom(.month) }
            Divider()
            Button("缩放以适合项目") { fitToWidth = true }
        } label: {
            Image(systemName: "arrow.left.and.right.square")
                .font(.caption)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("缩放：日 / 周 / 月 / 适合项目")
    }

    private func setZoom(_ newZoom: GanttZoom) {
        zoom = newZoom
        fitToWidth = false
        pinnedDayWidth = nil
        windowStart = nil
    }

    /// 拖动日期标头平移时间窗（F-14-13）。
    private func panGesture(layout: GanttLayout) -> some Gesture {
        DragGesture(minimumDistance: 1)
            .onChanged { value in
                let anchor: Date
                if let existing = dragAnchor {
                    anchor = existing
                } else {
                    anchor = layout.windowStart
                    dragAnchor = anchor
                    pinnedDayWidth = layout.dayWidth
                    fitToWidth = false
                }
                let dayWidth = pinnedDayWidth ?? layout.dayWidth
                windowStart = GanttLayoutEngine.pannedWindowStart(
                    from: anchor,
                    translationX: Double(value.translation.width),
                    dayWidth: dayWidth
                )
            }
            .onEnded { _ in
                dragAnchor = nil
            }
    }

    // MARK: - 行

    private func chartRows(_ layout: GanttLayout) -> some View {
        let barsByID = Dictionary(uniqueKeysWithValues: layout.bars.map { ($0.taskID, $0) })
        let depths = depthByID
        return ZStack(alignment: .topLeading) {
            bandBackground(layout, height: CGFloat(tasks.count) * rowHeight)
            VStack(spacing: 0) {
                ForEach(tasks) { task in
                    row(task, bar: barsByID[task.id], depth: depths[task.id] ?? 0, layout: layout)
                }
            }
        }
    }

    private func bandBackground(_ layout: GanttLayout, height: CGFloat) -> some View {
        ZStack(alignment: .topLeading) {
            ForEach(layout.bands.indices, id: \.self) { index in
                Rectangle()
                    .fill(Color.secondary.opacity(0.07))
                    .frame(width: layout.bands[index].width, height: height)
                    .offset(x: labelWidth + 1 + layout.bands[index].x)
            }
        }
    }

    private func row(
        _ task: TaskItem,
        bar: GanttLayout.Bar?,
        depth: Int,
        layout: GanttLayout
    ) -> some View {
        HStack(spacing: 0) {
            label(task, depth: depth)
            Divider()
            ZStack(alignment: .leading) {
                if let bar {
                    barView(bar, task: task)
                }
            }
            .frame(width: layout.windowWidth, height: rowHeight, alignment: .leading)
            .clipped()
        }
        .frame(height: rowHeight)
        .background(selection == task.id ? Color.accentColor.opacity(0.10) : Color.clear)
    }

    private func label(_ task: TaskItem, depth: Int) -> some View {
        HStack(spacing: 4) {
            Color.clear.frame(width: CGFloat(depth) * 12, height: 1)
            Image(systemName: iconName(task))
                .font(.caption2)
                .foregroundStyle(iconColor(task))
            Text(task.title)
                .font(.callout)
                .lineLimit(1)
            if violationIDs.contains(task.id) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .frame(width: labelWidth, height: rowHeight)
        .contentShape(Rectangle())
        .onTapGesture { onSelect(task.id) }
        .help(task.title)
    }

    private func barView(_ bar: GanttLayout.Bar, task: TaskItem) -> some View {
        Group {
            if bar.isMilestone {
                Rectangle()
                    .fill(barColor(task))
                    .frame(width: 10, height: 10)
                    .rotationEffect(.degrees(45))
                    .overlay {
                        if violationIDs.contains(task.id) {
                            Rectangle()
                                .stroke(Color.orange, lineWidth: 1)
                                .frame(width: 13, height: 13)
                                .rotationEffect(.degrees(45))
                        }
                    }
                    .offset(x: bar.x - 5)
            } else {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(barColor(task).opacity(bar.isGroup ? 0.35 : 0.25))
                    if bar.progress > 0 {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(barColor(task).opacity(0.75))
                            .frame(width: max(bar.width * bar.progress, 1))
                    }
                    RoundedRectangle(cornerRadius: 3)
                        .strokeBorder(strokeColor(bar, task), lineWidth: 1)
                }
                .frame(width: max(bar.width, 2), height: bar.isGroup ? 10 : 14)
                .offset(x: bar.x)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { onSelect(task.id) }
        .help(task.title)
    }

    private func strokeColor(_ bar: GanttLayout.Bar, _ task: TaskItem) -> Color {
        if violationIDs.contains(task.id) { return .orange }
        if bar.isCritical { return .red.opacity(0.65) }
        return barColor(task).opacity(0.5)
    }

    private func barColor(_ task: TaskItem) -> Color {
        if task.status == .done { return .green }
        if task.status == .blocked { return .orange }
        if task.kind == .group { return .secondary }
        return .accentColor
    }

    private func iconName(_ task: TaskItem) -> String {
        switch task.kind {
        case .group: return "folder"
        case .milestone: return "diamond"
        case .task: return task.status == .done ? "checkmark.circle" : "circle"
        }
    }

    private func iconColor(_ task: TaskItem) -> Color {
        switch task.status {
        case .done: return .green
        case .blocked: return .orange
        case .inProgress: return .accentColor
        case .pending: return .secondary
        }
    }

    /// 任务层级缩进（按 parentID 链计算，最多回溯 32 层防环）。
    private var depthByID: [UUID: Int] {
        let parentByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0.parentID) })
        func depth(of id: UUID) -> Int {
            var level = 0
            var current = parentByID[id] ?? nil
            var hops = 0
            while let parent = current, hops < 32 {
                level += 1
                current = parentByID[parent] ?? nil
                hops += 1
            }
            return level
        }
        return Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, depth(of: $0.id)) })
    }
}

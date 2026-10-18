import SwiftUI
import KairoCore
import KairoPresentation

/// 共用的纵向滚动坐标空间名：大纲与画布在同一滚动容器内。
enum WorkspaceScrollSpace {
    static let name = "kairo-workspace-scroll"
}

/// 两级时间表头（44pt）：上层月/年，下层日/周；拖动平移时间窗。
struct TimelineHeaderView: View {
    @ObservedObject var store: WorkspaceStore
    let gantt: GanttSnapshot
    let width: CGFloat

    @State private var panBaseDate: Date?
    @State private var lastPanDays: Int?

    private var upperTicks: [GanttTick] { gantt.ticks.filter(\.isMajor) }
    private var lowerTicks: [GanttTick] { gantt.ticks.filter { !$0.isMajor } }

    var body: some View {
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .color(DesignTokens.surfaceChrome)
            )

            for tick in lowerTicks {
                var line = Path()
                line.move(to: CGPoint(x: tick.x, y: 0))
                line.addLine(to: CGPoint(x: tick.x, y: size.height))
                context.stroke(line, with: .color(DesignTokens.grid), lineWidth: 1)
            }

            for tick in lowerTicks {
                let text = Text(tick.label)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                let anchor: UnitPoint = gantt.zoom == .day ? .center : .leading
                let x = gantt.zoom == .day
                    ? tick.x + gantt.dayWidth / 2
                    : tick.x + 3
                context.draw(text, at: CGPoint(x: x, y: 33), anchor: anchor)
            }

            for tick in upperTicks {
                let text = Text(tick.label)
                    .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                context.draw(text, at: CGPoint(x: tick.x + 3, y: 11), anchor: .leading)
            }

            var separator = Path()
            separator.move(to: CGPoint(x: 0, y: 22))
            separator.addLine(to: CGPoint(x: size.width, y: 22))
            context.stroke(separator, with: .color(DesignTokens.separator), lineWidth: 1)
        }
        .frame(width: width, height: DesignTokens.headerHeight)
        .clipped()
        .contentShape(Rectangle())
        .gesture(
            DragGesture(minimumDistance: 2)
                .onChanged { value in
                    if panBaseDate == nil {
                        panBaseDate = gantt.windowStart
                        lastPanDays = nil
                    }
                    guard let base = panBaseDate else { return }
                    let dayWidth = max(gantt.dayWidth, 1)
                    let days = Int((-value.translation.width / dayWidth).rounded())
                    guard days != lastPanDays else { return }
                    lastPanDays = days
                    let target = Calendar.current.date(byAdding: .day, value: days, to: base) ?? base
                    store.dispatch(.panWindow(to: target))
                }
                .onEnded { _ in
                    panBaseDate = nil
                    lastPanDays = nil
                }
        )
        .help("拖动平移时间窗")
    }
}

/// 画布主体：随共用滚动容器移动，只绘制可见行（1000 任务虚拟化）。
///
/// 结构：内容总高由行数决定；`GeometryReader` 读取滚动偏移，
/// 固定高度的 `Canvas` 跟随偏移贴在视口处，按偏移换算行坐标。
struct TimelineBody: View {
    @ObservedObject var store: WorkspaceStore
    let rows: [PlanRow]
    let gantt: GanttSnapshot
    let width: CGFloat
    let viewportHeight: CGFloat

    @State private var hoveredTaskID: UUID?

    private var contentHeight: CGFloat {
        CGFloat(rows.count) * DesignTokens.rowHeight
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
                .frame(width: width, height: max(contentHeight, 1))
            GeometryReader { geo in
                let offset = max(
                    0,
                    -geo.frame(in: .named(WorkspaceScrollSpace.name)).minY
                )
                Canvas { context, size in
                    draw(context: &context, size: size, offset: offset)
                }
                .frame(width: width, height: viewportHeight)
                .offset(y: offset)
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        hoveredTaskID = taskID(at: point, offset: offset)
                    case .ended:
                        hoveredTaskID = nil
                    }
                }
                .gesture(SpatialTapGesture().onEnded { value in
                    guard let id = taskID(at: value.location, offset: offset) else { return }
                    store.dispatch(.select(id))
                })
            }
        }
        .frame(width: width, alignment: .topLeading)
    }

    private func taskID(at point: CGPoint, offset: CGFloat) -> UUID? {
        let row = Int((point.y + offset) / DesignTokens.rowHeight)
        guard rows.indices.contains(row) else { return nil }
        let id = rows[row].id
        return gantt.bars.first { $0.taskID == id } == nil ? nil : id
    }

    /// 画布高亮的活动任务：悬停优先，否则用当前选中；依赖线据此隔离。
    private var activeTaskID: UUID? {
        hoveredTaskID ?? store.selection
    }

    // MARK: - 绘制

    private func draw(
        context: inout GraphicsContext,
        size: CGSize,
        offset: CGFloat
    ) {
        let rowHeight = DesignTokens.rowHeight
        let firstRow = max(0, Int(offset / rowHeight) - 1)
        let lastRow = min(rows.count - 1, Int((offset + size.height) / rowHeight) + 1)

        drawBands(context: &context, size: size)
        drawRowStates(context: &context, size: size, offset: offset, firstRow: firstRow, lastRow: lastRow)

        var grid = Path()
        for tick in gantt.ticks where !tick.isMajor {
            grid.move(to: CGPoint(x: tick.x, y: 0))
            grid.addLine(to: CGPoint(x: tick.x, y: size.height))
        }
        context.stroke(grid, with: .color(DesignTokens.grid.opacity(0.7)), lineWidth: 1)

        if !rows.isEmpty {
            var rowLines = Path()
            let lineStart = max(firstRow, 0)
            let lineEnd = min(lastRow + 1, rows.count - 1)
            if lineStart <= lineEnd {
                for row in lineStart...lineEnd {
                    let y = CGFloat(row) * rowHeight - offset
                    rowLines.move(to: CGPoint(x: 0, y: y))
                    rowLines.addLine(to: CGPoint(x: size.width, y: y))
                }
                context.stroke(rowLines, with: .color(DesignTokens.grid.opacity(0.5)), lineWidth: 0.5)
            }
        }

        if let todayX = gantt.todayX, todayX >= 0, todayX <= size.width {
            var today = Path()
            today.move(to: CGPoint(x: todayX, y: 0))
            today.addLine(to: CGPoint(x: todayX, y: size.height))
            context.stroke(today, with: .color(DesignTokens.today), lineWidth: 1.5)
        }

        drawDependencies(context: &context, size: size, offset: offset)
        drawBars(context: &context, size: size, offset: offset, firstRow: firstRow, lastRow: lastRow)
    }

    private func drawBands(context: inout GraphicsContext, size: CGSize) {
        for band in gantt.bands {
            let rect = CGRect(x: band.x, y: 0, width: band.width, height: size.height)
            context.fill(Path(rect), with: .color(DesignTokens.nonWorkingBand))
        }
    }

    private func drawRowStates(
        context: inout GraphicsContext,
        size: CGSize,
        offset: CGFloat,
        firstRow: Int,
        lastRow: Int
    ) {
        guard firstRow <= lastRow, rows.indices.contains(firstRow) else { return }
        for row in firstRow...lastRow {
            let planRow = rows[row]
            let y = CGFloat(row) * DesignTokens.rowHeight - offset
            let rect = CGRect(x: 0, y: y, width: size.width, height: DesignTokens.rowHeight)
            if planRow.id == store.selection {
                context.fill(Path(rect), with: .color(DesignTokens.selection.opacity(0.6)))
            } else if planRow.isHighlighted {
                context.fill(Path(rect), with: .color(DesignTokens.selection.opacity(0.3)))
            } else if planRow.id == hoveredTaskID {
                context.fill(Path(rect), with: .color(DesignTokens.hoverOverlay))
            }
        }
    }

    private func drawDependencies(
        context: inout GraphicsContext,
        size: CGSize,
        offset: CGFloat
    ) {
        for dependency in gantt.dependencies {
            let related = activeTaskID.map {
                dependency.predecessorID == $0 || dependency.successorID == $0
            } ?? false
            let color: Color
            if dependency.isCritical && gantt.showsCriticalPath {
                color = DesignTokens.criticalGraphic
            } else {
                color = DesignTokens.dependency
            }
            let opacity: Double = activeTaskID == nil || related ? 1 : 0.2
            let baseWidth: CGFloat = dependency.isCritical && gantt.showsCriticalPath ? 1.5 : 1
            let lineWidth: CGFloat = related ? max(baseWidth, 1.5) : baseWidth

            var path = Path()
            for segment in dependency.segments {
                path.move(to: CGPoint(x: segment.startX, y: segment.startY - offset))
                path.addLine(to: CGPoint(x: segment.endX, y: segment.endY - offset))
            }
            context.stroke(
                path,
                with: .color(color.opacity(opacity)),
                style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
            )
            if let last = dependency.segments.last {
                drawArrow(
                    context: &context,
                    from: CGPoint(x: last.startX, y: last.startY - offset),
                    to: CGPoint(x: last.endX, y: last.endY - offset),
                    color: color.opacity(opacity)
                )
            }
        }
    }

    private func drawArrow(
        context: inout GraphicsContext,
        from: CGPoint,
        to: CGPoint,
        color: Color
    ) {
        let angle = atan2(to.y - from.y, to.x - from.x)
        let length: CGFloat = 4
        let spread: CGFloat = 3
        let tip = to
        let left = CGPoint(
            x: tip.x - length * cos(angle) + spread * sin(angle),
            y: tip.y - length * sin(angle) - spread * cos(angle)
        )
        let right = CGPoint(
            x: tip.x - length * cos(angle) - spread * sin(angle),
            y: tip.y - length * sin(angle) + spread * cos(angle)
        )
        var path = Path()
        path.move(to: tip)
        path.addLine(to: left)
        path.addLine(to: right)
        path.closeSubpath()
        context.fill(path, with: .color(color))
    }

    private func drawBars(
        context: inout GraphicsContext,
        size: CGSize,
        offset: CGFloat,
        firstRow: Int,
        lastRow: Int
    ) {
        guard firstRow <= lastRow else { return }
        let byRow = Dictionary(grouping: gantt.bars, by: \.rowIndex)
        for row in firstRow...lastRow {
            guard let bars = byRow[row] else { continue }
            let top = CGFloat(row) * DesignTokens.rowHeight - offset
            for bar in bars {
                drawBar(context: &context, size: size, bar: bar, rowTop: top)
            }
        }
    }

    private func drawBar(
        context: inout GraphicsContext,
        size: CGSize,
        bar: GanttBar,
        rowTop: CGFloat
    ) {
        let title = rows.indices.contains(bar.rowIndex) ? rows[bar.rowIndex].title : ""

        if bar.kind == .milestone {
            let center = CGPoint(x: bar.x + max(bar.width, 0) / 2, y: rowTop + 14)
            var diamond = Path()
            diamond.move(to: CGPoint(x: center.x, y: center.y - 5))
            diamond.addLine(to: CGPoint(x: center.x + 5, y: center.y))
            diamond.addLine(to: CGPoint(x: center.x, y: center.y + 5))
            diamond.addLine(to: CGPoint(x: center.x - 5, y: center.y))
            diamond.closeSubpath()
            context.fill(
                diamond,
                with: .color(bar.isOverdue ? DesignTokens.overdue : DesignTokens.criticalGraphic)
            )
            if bar.taskID == store.selection {
                context.stroke(diamond, with: .color(DesignTokens.accentStrong), lineWidth: 2)
            }
            drawLabel(context: &context, size: size, text: title, x: center.x + 9, y: center.y)
            drawViolationBadge(context: &context, bar: bar, x: center.x + 7, y: rowTop + 4)
            return
        }

        let height: CGFloat = bar.kind == .group ? 10 : 14
        let y = rowTop + (DesignTokens.rowHeight - height) / 2
        let rect = CGRect(x: bar.x, y: y, width: max(bar.width, 1), height: height)
        guard rect.minY < size.height, rect.maxY > 0 else { return }

        let radius: CGFloat = bar.kind == .group ? 2 : 3
        let shape = Path(roundedRect: rect, cornerRadius: radius)
        context.fill(
            shape,
            with: .color(bar.kind == .group
                ? DesignTokens.textSecondary.opacity(0.28)
                : DesignTokens.progressTrack)
        )
        if bar.progress > 0 {
            let fillWidth = rect.width * min(max(bar.progress, 0), 1)
            let fillRect = CGRect(x: rect.minX, y: rect.minY, width: fillWidth, height: rect.height)
            context.fill(
                Path(roundedRect: fillRect, cornerRadius: radius),
                with: .color(DesignTokens.progressFill)
            )
        }

        if bar.isOverdue {
            context.stroke(shape, with: .color(DesignTokens.overdue), lineWidth: 1.5)
        } else if bar.isCritical && gantt.showsCriticalPath {
            context.stroke(shape, with: .color(DesignTokens.criticalGraphic), lineWidth: 1.5)
        }
        // 选中任务条：accent 外描边盖在逾期/关键描边之上，点击后在画布上立即可辨。
        if bar.taskID == store.selection {
            let outline = Path(roundedRect: rect.insetBy(dx: -1.5, dy: -1.5), cornerRadius: radius + 1.5)
            context.stroke(outline, with: .color(DesignTokens.accentStrong), lineWidth: 2)
        }

        drawViolationBadge(context: &context, bar: bar, x: rect.maxX + 2, y: rowTop + 4)

        let labelY = rowTop + DesignTokens.rowHeight / 2
        let labelX = rect.maxX + 6
        if labelX + 60 < size.width {
            drawLabel(context: &context, size: size, text: labelText(bar: bar, title: title), x: labelX, y: labelY)
        } else if rect.minX - 66 > 0 {
            let text = Text(labelText(bar: bar, title: title))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
            context.draw(text, at: CGPoint(x: rect.minX - 6, y: labelY), anchor: .trailing)
        }
    }

    private func labelText(bar: GanttBar, title: String) -> String {
        if bar.isCollapsedGroup {
            return "\(title)（\(bar.childCount) 项）"
        }
        return title
    }

    private func drawLabel(
        context: inout GraphicsContext,
        size: CGSize,
        text: String,
        x: CGFloat,
        y: CGFloat
    ) {
        guard gantt.showsBarLabels, gantt.zoom != .month else { return }
        guard x < size.width else { return }
        context.draw(
            Text(text)
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textPrimary),
            at: CGPoint(x: x, y: y),
            anchor: .leading
        )
    }

    private func drawViolationBadge(
        context: inout GraphicsContext,
        bar: GanttBar,
        x: CGFloat,
        y: CGFloat
    ) {
        guard bar.violationCount > 0 else { return }
        var triangle = Path()
        triangle.move(to: CGPoint(x: x, y: y))
        triangle.addLine(to: CGPoint(x: x + 6, y: y))
        triangle.addLine(to: CGPoint(x: x + 3, y: y + 7))
        triangle.closeSubpath()
        context.fill(triangle, with: .color(DesignTokens.violationWarning))
    }
}

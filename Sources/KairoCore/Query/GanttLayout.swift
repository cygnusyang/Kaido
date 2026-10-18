import Foundation

/// 甘特缩放档位（F-14-13）：每日占用的像素宽度。
public enum GanttZoom: String, CaseIterable, Codable, Sendable {
    case day, week, month

    public var dayWidth: Double {
        switch self {
        case .day: return 32
        case .week: return 12
        case .month: return 5
        }
    }
}

/// 甘特视图的几何布局（ADR-004 纯逻辑，无 UI 依赖）。
///
/// 时间窗为半开区间 `[windowStart, windowEnd)`；任务条按
/// `(计划开始 − 窗口起点)` 折算横坐标，超出窗口的条保留（由视图裁剪），
/// 以便拖动窗口时条不会在边缘跳变。
public struct GanttLayout: Equatable, Sendable {
    public struct Bar: Equatable, Sendable {
        public var taskID: UUID
        public var x: Double
        public var width: Double
        public var isMilestone: Bool
        public var isGroup: Bool
        /// 0...1 完成度，用于条内进度填充。
        public var progress: Double
        /// 重要路径任务（总宽延 ≤ 0）。
        public var isCritical: Bool
    }

    public struct Tick: Equatable, Sendable {
        public var date: Date
        public var x: Double
        public var label: String
        /// 主要刻度（日档位的每月首日、月档位的每年首月）。
        public var isMajor: Bool
    }

    /// 非工作时段背景带（F-14-14）。
    public struct Band: Equatable, Sendable {
        public var x: Double
        public var width: Double
    }

    public var windowStart: Date
    /// 窗口结束（不含）。
    public var windowEnd: Date
    public var dayWidth: Double
    /// 视图可用宽度（点）。
    public var windowWidth: Double
    /// 内容范围（项目与任务排期边界的并集）；无排期数据时为 nil。
    public var contentStart: Date?
    public var contentEnd: Date?
    public var bars: [Bar]
    public var ticks: [Tick]
    public var bands: [Band]
}

public enum GanttLayoutEngine {
    /// 内容范围：项目边界与全部任务排期边界的并集（F-14-01「缩放以适合项目」）。
    public static func contentRange(
        tasks: [TaskItem],
        schedule: ScheduleResult?,
        calendar: Calendar
    ) -> DateInterval? {
        guard let schedule else { return nil }
        var starts: [Date] = []
        var ends: [Date] = []
        if let projectStart = schedule.projectStart { starts.append(projectStart) }
        if let projectEnd = schedule.projectEnd { ends.append(projectEnd) }
        for scheduled in schedule.tasks {
            starts.append(scheduled.scheduledStart)
            ends.append(scheduled.scheduledFinish)
        }
        guard let firstStart = starts.min(), let lastEnd = ends.max() else { return nil }
        let start = calendar.startOfDay(for: firstStart)
        var end = calendar.startOfDay(for: lastEnd)
        if end <= start {
            end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        }
        return DateInterval(start: start, end: end)
    }

    /// 生成可见区布局。
    ///
    /// - Parameters:
    ///   - windowStart: 可见起点；nil 时取内容范围起点（无内容时取今天）。
    ///   - nonWorkingWeekdays: 非工作星期（`Calendar` 星期序号，1=周日）；默认周六、周日。
    ///     工作日历模型（F-22-06）落地前以此为视图默认。
    ///   - dayWidthOverride: 覆盖档位默认宽度（「缩放以适合项目」传 `fitDayWidth` 结果）。
    public static func make(
        tasks: [TaskItem],
        schedule: ScheduleResult?,
        calendar: Calendar,
        zoom: GanttZoom,
        viewWidth: Double,
        windowStart requestedStart: Date? = nil,
        nonWorkingWeekdays: Set<Int> = [1, 7],
        dayWidthOverride: Double? = nil
    ) -> GanttLayout {
        let content = contentRange(tasks: tasks, schedule: schedule, calendar: calendar)
        let width = max(viewWidth, 1)
        let dayWidth = max(dayWidthOverride ?? zoom.dayWidth, 0.5)
        let windowStart = calendar.startOfDay(
            for: requestedStart ?? content?.start ?? Date()
        )
        let windowSeconds = width / dayWidth * 86_400
        let windowEnd = windowStart.addingTimeInterval(windowSeconds)

        let tasksByID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        let criticalIDs = Set(
            schedule.map { CriticalPathEngine.compute(result: $0) }
                .map { $0.filter(\.isCritical).map(\.taskID) } ?? []
        )
        var bars: [GanttLayout.Bar] = []
        for scheduled in schedule?.tasks ?? [] {
            let start = scheduled.scheduledStart
            let finish = scheduled.scheduledFinish
            guard finish > windowStart, start < windowEnd else { continue }
            let task = tasksByID[scheduled.taskID]
            let x = start.timeIntervalSince(windowStart) / 86_400 * dayWidth
            let barWidth = max(0, finish.timeIntervalSince(start) / 86_400 * dayWidth)
            bars.append(
                GanttLayout.Bar(
                    taskID: scheduled.taskID,
                    x: x,
                    width: barWidth,
                    isMilestone: task?.kind == .milestone || scheduled.durationDays == 0,
                    isGroup: task?.kind == .group,
                    progress: min(max(task?.progress ?? 0, 0), 1),
                    isCritical: criticalIDs.contains(scheduled.taskID)
                )
            )
        }

        var ticks: [GanttLayout.Tick] = []
        var bands: [GanttLayout.Band] = []
        var cursor = windowStart
        while cursor < windowEnd {
            let weekday = calendar.component(.weekday, from: cursor)
            let day = calendar.component(.day, from: cursor)
            let month = calendar.component(.month, from: cursor)
            let year = calendar.component(.year, from: cursor)
            let offset = cursor.timeIntervalSince(windowStart) / 86_400
            let x = offset * dayWidth

            if nonWorkingWeekdays.contains(weekday) {
                bands.append(GanttLayout.Band(x: x, width: dayWidth))
            }

            switch zoom {
            case .day:
                ticks.append(
                    GanttLayout.Tick(
                        date: cursor,
                        x: x,
                        label: day == 1 ? "\(month)月" : "\(day)",
                        isMajor: day == 1
                    )
                )
            case .week:
                if weekday == calendar.firstWeekday {
                    ticks.append(
                        GanttLayout.Tick(
                            date: cursor,
                            x: x,
                            label: "\(month)/\(day)",
                            isMajor: day == 1
                        )
                    )
                }
            case .month:
                if day == 1 {
                    ticks.append(
                        GanttLayout.Tick(
                            date: cursor,
                            x: x,
                            label: month == 1 ? "\(year)" : "\(month)月",
                            isMajor: month == 1
                        )
                    )
                }
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }

        return GanttLayout(
            windowStart: windowStart,
            windowEnd: windowEnd,
            dayWidth: dayWidth,
            windowWidth: width,
            contentStart: content?.start,
            contentEnd: content?.end,
            bars: bars,
            ticks: ticks,
            bands: bands
        )
    }

    /// 「缩放以适合项目」：让内容范围恰好铺满可用宽度（F-14-13）。
    public static func fitDayWidth(
        contentRange: DateInterval,
        viewWidth: Double,
        calendar: Calendar
    ) -> Double {
        let days = contentRange.duration / 86_400
        guard days > 0 else { return GanttZoom.day.dayWidth }
        return max(viewWidth, 1) / days
    }

    /// 拖动日期标头后的窗口起点（F-14-13）：向右拖动使时间窗左移，
    /// 向左拖动使时间窗右移。
    public static func pannedWindowStart(
        from anchor: Date,
        translationX: Double,
        dayWidth: Double
    ) -> Date {
        let days = -translationX / max(dayWidth, 0.5)
        return anchor.addingTimeInterval(days * 86_400)
    }
}

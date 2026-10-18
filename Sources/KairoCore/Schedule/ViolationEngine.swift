import Foundation

/// 违例引擎（ADR-007：违例规则集独立于调度，在调度纯函数输出上检测）。
/// 基础集 8 条（F-30-03/04/05/06/08/13/14），规则语义见 docs/features/02-inspectors-scheduling.md。
///
/// 单时限模型下的违例判定映射（每任务至多一个时限）：
///   startNoEarlierThan(x)：F-30-05，最晚开始 < x（相关性链把窗口压得过早）。
///   startNoLaterThan(x)  ：F-30-04，最早开始 > x（先决条件把开始推到时限之后）；
///                          F-30-05，x + 持续 > 最晚结束（时限与相关性链窗口冲突）。
///   endNoEarlierThan(x)  ：F-30-05，最晚结束 < x；x − 持续 < 最早开始（同上）。
///   endNoLaterThan(x)    ：F-30-04，最早结束 > x。
/// 双时限模型：任务同时带开始侧与结束侧时限且窗口 < 持续时间 → F-30-03（时限靠得太近）。
public enum ViolationEngine {
    /// 规则目录（F-30）：违例页空态与检查器从同一来源读取，界面不复制规则清单。
    public struct RuleCategory: Codable, Hashable, Sendable {
        public var code: String
        public var name: String
        public var severity: Violation.Severity

        public init(code: String, name: String, severity: Violation.Severity) {
            self.code = code
            self.name = name
            self.severity = severity
        }
    }

    public static let ruleCategories: [RuleCategory] = [
        .init(code: "cycle", name: "相关性环", severity: .error),
        .init(code: "task_ends_after_project_end", name: "任务结束晚于项目结束", severity: .error),
        .init(code: "task_starts_before_project_start", name: "任务开始早于项目开始", severity: .error),
        .init(code: "constraint_window_too_narrow", name: "时限窗口过窄", severity: .error),
        .init(code: "cannot_schedule_asap_alap", name: "无法安排（负宽延）", severity: .error),
        .init(code: "constraint_is_dependency", name: "时限与相关性链冲突", severity: .error),
        .init(code: "constraint_is_prerequisite", name: "先决条件无法满足时限", severity: .error)
    ]

    public static func check(
        result: ScheduleResult,
        tasks: [TaskItem],
        calendar: Calendar = Calendar(identifier: .gregorian)
    ) -> [Violation] {
        let byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var violations: [Violation] = []
        violations += cycleViolations(result: result, byID: byID)
        violations += projectBoundaryViolations(result: result, byID: byID)
        violations += negativeSlackViolations(result: result, byID: byID)
        violations += constraintViolations(result: result, byID: byID, calendar: calendar)
        violations += constraintWindowViolations(result: result, byID: byID, calendar: calendar)
        return violations
    }

    private static func title(_ id: UUID?, _ byID: [UUID: TaskItem]) -> String {
        guard let id else { return "未知任务" }
        return byID[id]?.title ?? "未知任务"
    }

    // MARK: - F-30-08 环

    private static func cycleViolations(result: ScheduleResult, byID: [UUID: TaskItem]) -> [Violation] {
        result.cycleTaskIDs.map { id in
            Violation(
                code: "cycle",
                message: "任务「\(title(id, byID))」处于相关性环中，无法确定先后顺序",
                taskID: id
            )
        }
    }

    // MARK: - F-30-13 / F-30-14 项目边界

    private static func projectBoundaryViolations(result: ScheduleResult, byID: [UUID: TaskItem]) -> [Violation] {
        var violations: [Violation] = []
        if let end = result.projectEnd {
            for s in result.tasks where s.scheduledFinish > end {
                violations.append(Violation(
                    code: "task_ends_after_project_end",
                    message: "任务「\(title(s.taskID, byID))」的结束日期晚于项目结束日期",
                    taskID: s.taskID
                ))
            }
        }
        if let start = result.projectStart {
            for s in result.tasks where s.scheduledStart < start {
                violations.append(Violation(
                    code: "task_starts_before_project_start",
                    message: "任务「\(title(s.taskID, byID))」的开始日期早于项目开始日期",
                    taskID: s.taskID
                ))
            }
        }
        return violations
    }

    // MARK: - F-30-03 时限靠得太近（开始侧与结束侧时限窗口容不下持续时间）

    private static func constraintWindowViolations(
        result: ScheduleResult,
        byID: [UUID: TaskItem],
        calendar: Calendar
    ) -> [Violation] {
        result.tasks.compactMap { s in
            guard let task = byID[s.taskID], task.constraint != nil else { return nil }
            guard let window = Self.constraintWindow(for: task, calendar: calendar) else { return nil }
            let needed = s.durationDays * 86400
            guard window < needed else { return nil }
            return Violation(
                code: "constraint_window_too_narrow",
                message: "任务「\(task.title)」的开始时限与结束时限相距过近（\(Int(window / 86400)) 天），无法容纳持续时间（\(Int(needed / 86400)) 天）",
                taskID: s.taskID
            )
        }
    }

    /// 同时存在开始侧与结束侧时限时，返回两者间隔（秒）；否则 nil。
    private static func constraintWindow(for task: TaskItem, calendar: Calendar) -> TimeInterval? {
        guard let c = task.constraint else { return nil }
        let startSide: Date?
        let endSide: Date?
        switch c {
        case .startNoEarlierThan(let d), .startNoLaterThan(let d):
            startSide = d
            endSide = nil
        case .endNoEarlierThan(let d), .endNoLaterThan(let d):
            startSide = nil
            endSide = d
        }
        // 单侧时限无窗口概念（另一侧来自相关性传播），交由 F-30-04/05 处理。
        guard let start = startSide ?? task.startDate, let end = endSide ?? task.dueDate else {
            return nil
        }
        return end.timeIntervalSince(start)
    }

    // MARK: - F-30-06 负宽延（无法安排 ASAP/ALAP）

    private static func negativeSlackViolations(result: ScheduleResult, byID: [UUID: TaskItem]) -> [Violation] {
        result.tasks.compactMap { s in
            guard s.totalSlackDays < 0 else { return nil }
            return Violation(
                code: "cannot_schedule_asap_alap",
                message: "任务「\(title(s.taskID, byID))」无法安排：最晚开始早于最早开始（负宽延）",
                taskID: s.taskID
            )
        }
    }

    // MARK: - F-30-03 / 04 / 05 时限

    private static func constraintViolations(
        result: ScheduleResult,
        byID: [UUID: TaskItem],
        calendar: Calendar
    ) -> [Violation] {
        var violations: [Violation] = []
        for s in result.tasks {
            guard let task = byID[s.taskID], let c = task.constraint else { continue }
            let x = calendar.startOfDay(for: c.date)
            switch c {
            case .startNoEarlierThan:
                if s.latestStart < x {
                    violations.append(Violation(
                        code: "constraint_is_dependency",
                        message: "任务「\(task.title)」的「开始不早于」时限与相关性链冲突：最晚开始早于时限",
                        taskID: s.taskID
                    ))
                }
            case .startNoLaterThan:
                if s.earliestStart > x {
                    violations.append(Violation(
                        code: "constraint_is_prerequisite",
                        message: "任务「\(task.title)」因先决条件无法满足「开始不晚于」时限",
                        taskID: s.taskID
                    ))
                }
                if x.addingTimeInterval(s.durationDays * 86400) > s.latestFinish {
                    violations.append(Violation(
                        code: "constraint_is_dependency",
                        message: "任务「\(task.title)」的「开始不晚于」时限与相关性链冲突：窗口无法容纳任务持续时间",
                        taskID: s.taskID
                    ))
                }
            case .endNoEarlierThan:
                if s.latestFinish < x {
                    violations.append(Violation(
                        code: "constraint_is_dependency",
                        message: "任务「\(task.title)」的「结束不早于」时限与相关性链冲突：最晚结束早于时限",
                        taskID: s.taskID
                    ))
                }
                if x.addingTimeInterval(-s.durationDays * 86400) < s.earliestStart {
                    violations.append(Violation(
                        code: "constraint_is_dependency",
                        message: "任务「\(task.title)」的「结束不早于」时限与相关性链冲突：窗口无法容纳任务持续时间",
                        taskID: s.taskID
                    ))
                }
            case .endNoLaterThan:
                if s.earliestFinish > x {
                    violations.append(Violation(
                        code: "constraint_is_prerequisite",
                        message: "任务「\(task.title)」因先决条件无法满足「结束不晚于」时限",
                        taskID: s.taskID
                    ))
                }
            }
        }
        return violations
    }
}

import Foundation
import KairoCore
import KairoPresentation

/// 视图层文案与格式化：术语与核心层一致，同一事物全篇同一名称。
enum Display {
    static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy/M/d"
        return formatter
    }()

    static let shortDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M/d"
        return formatter
    }()

    static func date(_ value: Date?) -> String {
        guard let value else { return "—" }
        return dateFormatter.string(from: value)
    }

    static func shortDate(_ value: Date?) -> String {
        guard let value else { return "—" }
        return shortDateFormatter.string(from: value)
    }

    static func duration(_ days: Double?) -> String {
        guard let days else { return "—" }
        if abs(days.rounded() - days) < 0.0001 {
            return "\(Int(days)) 天"
        }
        return String(format: "%.1f 天", days)
    }

    static func percent(_ value: Double) -> String {
        "\(Int((min(max(value, 0), 1) * 100).rounded()))%"
    }

    static func statusTitle(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return "待办"
        case .inProgress: return "进行中"
        case .blocked: return "阻塞"
        case .done: return "完成"
        }
    }

    static func statusSymbol(_ status: TaskStatus) -> String {
        switch status {
        case .pending: return "circle"
        case .inProgress: return "circle.lefthalf.filled"
        case .blocked: return "pause.circle"
        case .done: return "checkmark.circle.fill"
        }
    }

    static func priorityTitle(_ priority: TaskPriority) -> String {
        switch priority {
        case .low: return "低"
        case .normal: return "普通"
        case .high: return "高"
        case .critical: return "紧急"
        }
    }

    static func kindTitle(_ kind: TaskKind) -> String {
        switch kind {
        case .task: return "任务"
        case .group: return "群组"
        case .milestone: return "里程碑"
        }
    }

    static func dependencyTitle(_ type: TaskDependency.DependencyType) -> String {
        switch type {
        case .fs: return "完成 → 开始"
        case .ff: return "完成 → 完成"
        case .ss: return "开始 → 开始"
        case .sf: return "开始 → 完成"
        }
    }

    static func unscheduledReason(_ reason: UnscheduledReason?) -> String {
        switch reason {
        case .cycle: return "依赖环"
        case .emptyGroup: return "空群组"
        case .unavailable: return "不可排期"
        case nil: return "未排期"
        }
    }

    static func directionTitle(_ direction: ScheduleDirection) -> String {
        switch direction {
        case .forward: return "尽快开始（ASAP）"
        case .backward: return "尽快结束（ALAP）"
        }
    }

    static func scheduleTitle(_ policy: SchedulingPolicy) -> String {
        policy == .asap ? "ASAP（尽早）" : "ALAP（尽晚）"
    }

    static func healthTitle(_ health: ProjectSummary.Health) -> String {
        switch health {
        case .green: return "健康"
        case .orange: return "注意"
        case .red: return "风险"
        }
    }

    static func saveStateTitle(_ state: SaveState) -> String {
        switch state {
        case .saved: return "已保存"
        case .unsaved: return "未保存"
        case .failed: return "保存失败"
        }
    }
}

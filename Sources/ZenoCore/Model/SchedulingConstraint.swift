import Foundation

/// 任务时限（F-22-04 时限 / F-30 违例基础集）。
/// 每任务至多一个单向时限：对开始/结束日期施加不早于/不晚于约束。
/// 关联值 Date 使枚举带关联值的 Codable 合成（Swift 5.5+）；日期按 .zeno 的 ISO8601 编码。
public enum SchedulingConstraint: Codable, Hashable, Sendable {
    case startNoEarlierThan(Date)
    case startNoLaterThan(Date)
    case endNoEarlierThan(Date)
    case endNoLaterThan(Date)

    /// 约束面向的端点（start/end），供消息与接口呈现。
    public var endpoint: String {
        switch self {
        case .startNoEarlierThan, .startNoLaterThan: return "start"
        case .endNoEarlierThan, .endNoLaterThan: return "end"
        }
    }

    /// 约束方向（no_earlier_than / no_later_than）。
    public var direction: String {
        switch self {
        case .startNoEarlierThan, .endNoEarlierThan: return "no_earlier_than"
        case .startNoLaterThan, .endNoLaterThan: return "no_later_than"
        }
    }

    /// 时限日期值。
    public var date: Date {
        switch self {
        case .startNoEarlierThan(let d), .startNoLaterThan(let d),
             .endNoEarlierThan(let d), .endNoLaterThan(let d):
            return d
        }
    }
}

/// 排期方式：自动（依赖驱动）/ 手动（日期钉死）。
///
/// 手动任务：`startDate` 是权威，前驱延后**不改写**它的日期；冲突以
/// `Violation.Kind.manualStartConflict` 呈现，而不是静默顺延。
/// 后继仍按手动任务的结束日继续链下去（与 MS Project 的手动排期一致）。
public enum TaskSchedulingMode: String, Codable, CaseIterable, Sendable {
    /// 由依赖与约束推导（默认）。
    case auto
    /// 日期固定；拖动任务条会直接改写日期，不产生约束。
    case manual
}

/// 任务调度策略（F-22-04 ASAP/ALAP）：尽可能早 / 尽可能晚。
/// 默认 asap；调度引擎按策略在最早/最晚可行窗口间选定安排。
public enum SchedulingPolicy: String, Codable, CaseIterable, Sendable {
    case asap
    case alap
}

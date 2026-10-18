import Foundation
import KairoCore
import KairoCommands

/// CLI 选项到核心枚举的解析。值集与 KairoCore 枚举 rawValue 对齐。
enum CLIEnums {
    static func kind(_ raw: String?) throws -> TaskKind? {
        guard let raw else { return nil }
        guard let v = TaskKind(rawValue: raw) else {
            throw UsageError(message: "无效类型：\(raw)（可选 task/group/milestone）")
        }
        return v
    }

    static func priority(_ raw: String?) throws -> TaskPriority? {
        guard let raw else { return nil }
        guard let v = TaskPriority(rawValue: raw) else {
            throw CLIError.invalidPriority(raw)
        }
        return v
    }

    static func status(_ raw: String?) throws -> TaskStatus? {
        guard let raw else { return nil }
        guard let v = TaskStatus(rawValue: raw) else {
            throw CLIError.invalidStatus(raw)
        }
        return v
    }

    /// 调度策略解析（F-22-04：asap/alap）。
    static func schedulingPolicy(_ raw: String?) throws -> SchedulingPolicy? {
        guard let raw else { return nil }
        guard let v = SchedulingPolicy(rawValue: raw) else {
            throw UsageError(message: "无效调度策略：\(raw)（可选 asap/alap）")
        }
        return v
    }

    /// 时限规格：type:ISO8601（如 startNoLaterThan:2026-11-05T00:00:00Z）。
    static func constraint(_ raw: String?) throws -> SchedulingConstraint? {
        guard let raw else { return nil }
        let parts = raw.split(separator: ":", maxSplits: 1)
        guard parts.count == 2, let date = CLIEnums.parseDate(String(parts[1])) else {
            throw UsageError(message: "无效时限：\(raw)（格式 type:日期，如 startNoLaterThan:2026-11-05 或 ISO8601 完整形式）")
        }
        switch String(parts[0]) {
        case "startNoEarlierThan": return .startNoEarlierThan(date)
        case "startNoLaterThan": return .startNoLaterThan(date)
        case "endNoEarlierThan": return .endNoEarlierThan(date)
        case "endNoLaterThan": return .endNoLaterThan(date)
        default:
            throw UsageError(message: "无效时限类型：\(parts[0])（可选 startNoEarlierThan/startNoLaterThan/endNoEarlierThan/endNoLaterThan）")
        }
    }

    /// 日期解析：ISO8601 完整形式或 YYYY-MM-DD（UTC 零点）。
    static func parseDate(_ raw: String) -> Date? {
        if let date = ISO8601DateFormatter().date(from: raw) { return date }
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"
        day.timeZone = TimeZone(identifier: "UTC")
        day.locale = Locale(identifier: "en_US_POSIX")
        return day.date(from: raw)
    }

    /// 资源种类解析（F-23-01：person/equipment/material/group）。
    static func resourceKind(_ raw: String?) throws -> ResourceKind? {
        guard let raw else { return nil }
        guard let v = ResourceKind(rawValue: raw) else {
            throw UsageError(message: "无效资源类型：\(raw)（可选 person/equipment/material/group）")
        }
        return v
    }

    /// 相关性规格：predecessor[:type[:lag]]，predecessor 为完整 UUID 或唯一前缀，
    /// type ∈ fs/ff/ss/sf。前缀在会话打开后经 `resolve(in:)` 解析。
    static func dependency(_ spec: String) throws -> DependencySpec {
        // 保留空段：":fs" 的前驱为空，属用法错误而非前缀 "fs"。
        let parts = spec.split(separator: ":", omittingEmptySubsequences: false)
        guard let raw = parts.first, !raw.isEmpty else {
            throw CLIError.invalidDependency(spec)
        }
        let type = parts.count > 1 ? parts[1].lowercased() : "fs"
        guard let depType = TaskDependency.DependencyType(rawValue: String(type)) else {
            throw CLIError.invalidDependencyType(String(type))
        }
        let lag = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
        return DependencySpec(predecessor: String(raw), type: depType, lagDays: lag)
    }
}

/// 待解析的相关性规格（前驱可为完整 UUID 或唯一前缀）。
struct DependencySpec {
    let predecessor: String
    let type: TaskDependency.DependencyType
    let lagDays: Double

    /// 用已打开的项目会话解析前驱标识。
    func resolve(in session: KairoSession) throws -> TaskDependency {
        let id = try CLIRouter.resolveTaskID(predecessor, in: session)
        return TaskDependency(predecessorID: id, type: type, lagDays: lagDays)
    }
}

/// CLI 专属错误：枚举值不合法。
enum CLIError: Error, CustomStringConvertible {
    case invalidPriority(String)
    case invalidStatus(String)
    case invalidDependency(String)
    case invalidDependencyType(String)

    var description: String {
        switch self {
        case .invalidPriority(let raw):
            return "无效优先级：\(raw)（可选 low/normal/high/critical）"
        case .invalidStatus(let raw):
            return "无效状态：\(raw)（可选 pending/in_progress/done/blocked）"
        case .invalidDependency(let spec):
            return "无效相关性规格：\(spec)（格式 predecessorID[:type[:lag]]）"
        case .invalidDependencyType(let raw):
            return "无效相关性类型：\(raw)（可选 fs/ff/ss/sf）"
        }
    }
}

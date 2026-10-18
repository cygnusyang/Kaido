import Foundation
import KairoCore

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
        guard parts.count == 2, let date = ISO8601DateFormatter().date(from: String(parts[1])) else {
            throw UsageError(message: "无效时限：\(raw)（格式 type:ISO8601，如 startNoLaterThan:2026-11-05T00:00:00Z）")
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

    /// 资源种类解析（F-23-01：person/equipment/material/group）。
    static func resourceKind(_ raw: String?) throws -> ResourceKind? {
        guard let raw else { return nil }
        guard let v = ResourceKind(rawValue: raw) else {
            throw UsageError(message: "无效资源类型：\(raw)（可选 person/equipment/material/group）")
        }
        return v
    }

    /// 相关性规格：predecessorID[:type[:lag]]，type ∈ fs/ff/ss/sf。
    static func dependency(_ spec: String) throws -> TaskDependency {
        let parts = spec.split(separator: ":")
        guard let idRaw = parts.first, let id = UUID(uuidString: String(idRaw)) else {
            throw CLIError.invalidDependency(spec)
        }
        let type = parts.count > 1 ? parts[1].lowercased() : "fs"
        guard let depType = TaskDependency.DependencyType(rawValue: String(type)) else {
            throw CLIError.invalidDependencyType(String(type))
        }
        let lag = parts.count > 2 ? (Double(parts[2]) ?? 0) : 0
        return TaskDependency(predecessorID: id, type: depType, lagDays: lag)
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

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

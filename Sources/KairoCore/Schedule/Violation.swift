import Foundation

/// 违例（F-30-01）：排期/约束逻辑问题的一条记录。
/// `code` 用 F-30 编号风格字符串（如 "cycle"、"constraint_is_prerequisite"），
/// `message` 为中文原因说明（含任务标题），供 MCP/CLI 直接呈现。
public struct Violation: Codable, Hashable, Sendable {
    public enum Severity: String, Codable, Sendable {
        case error
        case warning
    }

    /// 违例代码（F-30 风格）。
    public var code: String
    /// 中文原因说明。
    public var message: String
    /// 涉及任务（可能为空，如仅项目级违例）。
    public var taskID: UUID?
    /// 严重级别：error = 阻断安排的问题；warning = 提示。
    public var severity: Severity

    public init(code: String, message: String, taskID: UUID? = nil, severity: Severity = .error) {
        self.code = code
        self.message = message
        self.taskID = taskID
        self.severity = severity
    }
}

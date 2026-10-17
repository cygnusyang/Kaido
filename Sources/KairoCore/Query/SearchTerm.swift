import Foundation

public enum SearchKey: String, Codable, CaseIterable, Sendable {
    case title
    case notes
    case tags
    case assignee
    case priority
    case status
}

public struct SearchTerm: Sendable {
    public enum Matcher: Sendable {
        case contains(String)
        case equals(String)
        case isValue(String)
        case hasTag(String)
    }

    public let key: SearchKey
    public let matcher: Matcher

    public init(key: SearchKey, matcher: Matcher) {
        self.key = key
        self.matcher = matcher
    }

    public func value(for task: TaskItem) -> String {
        switch key {
        case .title: return task.title
        case .notes: return task.notes
        case .tags: return task.tags.joined(separator: " ")
        case .assignee: return task.assignee ?? ""
        case .priority: return task.priority.rawValue
        case .status: return task.status.rawValue
        }
    }

    public func matches(_ task: TaskItem) -> Bool {
        let value = self.value(for: task)
        switch matcher {
        case .contains(let needle):
            return value.localizedCaseInsensitiveContains(needle)
        case .equals(let expected):
            return value.caseInsensitiveCompare(expected) == .orderedSame
        case .isValue(let raw):
            return value.caseInsensitiveCompare(raw) == .orderedSame
        case .hasTag(let tag):
            return task.tags.contains { $0.caseInsensitiveCompare(tag) == .orderedSame }
        }
    }

    public var displayText: String {
        switch matcher {
        case .contains(let s): return "\(key.rawValue):~\"\(s)\""
        case .equals(let s): return "\(key.rawValue)=\(s)"
        case .isValue(let s): return "\(key.rawValue)=\(s)"
        case .hasTag(let s): return "tag:\(s)"
        }
    }
}

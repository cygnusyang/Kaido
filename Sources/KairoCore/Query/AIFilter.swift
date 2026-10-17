import Foundation

/// A single clause produced by `AIFilterTranslator`.
/// Term clauses delegate to `SearchTerm`; date clauses derive from the task's
/// calendar state. Clauses AND-combine.
public enum FilterClause: Sendable {
    case term(SearchTerm)
    case overdue
    case dueToday
}

/// Deterministic, rule-based translator that turns a natural-language phrase
/// into AND-combined filter clauses. This is the "AI-era" search entry point:
/// no model, just a compact token table.
public struct AIFilterTranslator {
    /// Split a phrase into meaningful tokens: lowercased, whitespace-split,
    /// with punctuation-only tokens dropped.
    public static func tokenize(_ phrase: String) -> [String] {
        phrase
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { token in
                !token.isEmpty && token.contains { $0.isLetter || $0.isNumber }
            }
    }

    /// Map a phrase to filter clauses. Unknown tokens fall back to a
    /// case-insensitive title match; `tag:` prefixes become tag matches.
    public static func translate(_ phrase: String) -> [FilterClause] {
        var clauses: [FilterClause] = []
        for token in tokenize(phrase) {
            switch token {
            case "overdue", "逾期":
                clauses.append(.overdue)
            case "done", "完成":
                clauses.append(statusTerm("done"))
            case "todo", "pending", "待办":
                clauses.append(statusTerm("pending"))
            case "doing", "in_progress", "进行中":
                clauses.append(statusTerm("in_progress"))
            case "high", "urgent", "紧急":
                clauses.append(priorityTerm("high"))
            case "critical", "p0":
                clauses.append(priorityTerm("critical"))
            case "today", "今天":
                clauses.append(.dueToday)
            default:
                if token.hasPrefix("tag:") {
                    let tag = String(token.dropFirst(4))
                    guard !tag.isEmpty else { continue }
                    clauses.append(.term(SearchTerm(key: .tags, matcher: .hasTag(tag))))
                } else {
                    clauses.append(.term(SearchTerm(key: .title, matcher: .contains(token))))
                }
            }
        }
        return clauses
    }

    /// Human-readable summary of the active clauses, e.g. "筛选：逾期 + 状态=done".
    public static func explanation(for clauses: [FilterClause]) -> String {
        guard !clauses.isEmpty else { return "全部任务" }
        let parts = clauses.map(describe)
        return "筛选：" + parts.joined(separator: " + ")
    }

    /// Keep tasks satisfying every clause; an empty clause list returns all tasks.
    public static func apply(clauses: [FilterClause], to tasks: [TaskItem]) -> [TaskItem] {
        tasks.filter { task in
            clauses.allSatisfy { clause in
                switch clause {
                case .term(let term):
                    return term.matches(task)
                case .overdue:
                    return task.isOverdue
                case .dueToday:
                    guard let due = task.dueDate else { return false }
                    return Calendar.current.isDateInToday(due)
                }
            }
        }
    }

    private static func statusTerm(_ rawValue: String) -> FilterClause {
        .term(SearchTerm(key: .status, matcher: .isValue(rawValue)))
    }

    private static func priorityTerm(_ rawValue: String) -> FilterClause {
        .term(SearchTerm(key: .priority, matcher: .isValue(rawValue)))
    }

    private static func describe(_ clause: FilterClause) -> String {
        switch clause {
        case .term(let term): return term.displayText
        case .overdue: return "逾期"
        case .dueToday: return "今天到期"
        }
    }
}

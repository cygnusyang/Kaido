import Foundation

/// A pluggable matcher used by `FindController` to locate text occurrences.
///
/// Mirrors OmniPlan's `OAFindPattern` protocol (found via REA static analysis):
/// the find controller owns iteration/selection; the pattern object owns matching.
/// Two conformers ship: literal and regular expression.
public protocol FindPattern {
    /// Find the first match at or after `location`. Returns the matched range or nil.
    func find(in string: String, from location: String.Index) -> Range<String.Index>?
    /// Human-facing label shown in the find bar (e.g. 文本 / 正则).
    var kindLabel: String { get }
}

/// Literal (case-insensitive by default) substring matching.
public struct LiteralFindPattern: FindPattern {
    public let needle: String
    public var caseSensitive = false

    public init(needle: String, caseSensitive: Bool = false) {
        self.needle = needle
        self.caseSensitive = caseSensitive
    }

    public func find(in string: String, from location: String.Index) -> Range<String.Index>? {
        let options: String.CompareOptions = caseSensitive
            ? [.literal]
            : [.literal, .caseInsensitive]
        guard location <= string.endIndex else { return nil }
        return string.range(of: needle, options: options, range: location..<string.endIndex)
    }

    public var kindLabel: String { "文本" }
}

/// Regular expression matching backed by NSRegularExpression.
public struct RegexFindPattern: FindPattern {
    public let pattern: String
    private let regex: NSRegularExpression

    public init?(pattern: String) {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        self.pattern = pattern
        self.regex = regex
    }

    public func find(in string: String, from location: String.Index) -> Range<String.Index>? {
        guard location <= string.endIndex else { return nil }
        let ns = string as NSString
        let start = string.utf16.distance(from: string.startIndex, to: location)
        guard let match = regex.firstMatch(
            in: string,
            range: NSRange(location: start, length: ns.length - start))
        else { return nil }
        return Range(match.range, in: string)
    }

    public var kindLabel: String { "正则" }
}

import Foundation

/// Protocol for views/models that can be searched by `FindController`.
/// Mirrors OmniPlan's `OAFindControllerTarget` (REA: OmniAppKit framework).
public protocol FindTarget: AnyObject {
    /// All searchable text for the current visible content, in display order.
    var findableText: [String] { get }
    /// Called when the find controller selects a match at `index` into `findableText`.
    func revealMatch(at index: Int)
}

/// Central find engine. Owns pattern, last query, wrap-around iteration and
/// result bookkeeping. UI binds to it; targets provide searchable content.
/// Mirrors OmniPlan's `OAFindController` (NSWindowController, 62 ObjC methods,
/// REA: OmniAppKit framework).
///
/// 纯逻辑控制器（ADR-004）：不依赖 Combine；SwiftUI 侧用应用层
/// `FindModel` 门面做变更通知。
@MainActor
public final class FindController {
    /// OmniPlan persists `lastFindString` across sessions; same behavior here.
    public var lastFindString: String = ""
    public var regexMode = false
    public var matchCount = 0
    public var currentIndex: Int?
    public var invalidRegex = false

    public init() {}

    private var matches: [Int] = []
    private weak var target: (any FindTarget)?

    /// OmniPlan exposes a pluggable matcher protocol (OAFindPattern);
    /// `regexMode` selects between the literal and regex conformers here.
    private func makePattern() -> (any FindPattern)? {
        let needle = lastFindString
        guard !needle.isEmpty else { return nil }
        if regexMode {
            guard let p = RegexFindPattern(pattern: needle) else {
                invalidRegex = true
                return nil
            }
            return p
        }
        invalidRegex = false
        return LiteralFindPattern(needle: needle)
    }

    public func attach(target: (any FindTarget)?) {
        self.target = target
        rescan()
    }

    /// Re-run the search over the target's content. Live as-you-type.
    public func rescan() {
        invalidRegex = false
        matches = []
        currentIndex = nil
        guard let pattern = makePattern(), let target else { matchCount = 0; return }
        let texts = target.findableText
        for (i, text) in texts.enumerated() {
            if pattern.find(in: text, from: text.startIndex) != nil {
                matches.append(i)
            }
        }
        matchCount = matches.count
        if let first = matches.first {
            currentIndex = first
            target.revealMatch(at: first)
            revealTargetMatch()
        }
    }

    private func revealTargetMatch() {
        guard let target, let idx = currentIndex else { return }
        target.revealMatch(at: idx)
    }

    public func findNext() {
        guard !matches.isEmpty else { return }
        // OmniPlan: wrap-around iteration (findPattern:backwards:wrap:)
        let next = matches.first { $0 > (currentIndex ?? -1) } ?? matches.first!
        currentIndex = next
        revealTargetMatch()
    }

    public func findPrevious() {
        guard !matches.isEmpty else { return }
        let prev = matches.last { $0 < (currentIndex ?? Int.max) } ?? matches.last!
        currentIndex = prev
        revealTargetMatch()
    }
}

import Foundation

/// `kairo://` 深链（US-E5-04 / F-41-03）：解析与项目内定位。
///
/// 支持三种形式：
///   kairo://task/<UUID 或 ≥4 位前缀>
///   kairo://task?title=<标题>
///   kairo://project/<UUID>
///
/// 纯逻辑（ADR-004）：只依赖 Foundation，应用层负责窗口激活与选中。
public struct KairoDeepLink: Equatable, Sendable {
    public enum Target: Equatable, Sendable {
        case taskID(String)
        case taskTitle(String)
        case projectID(UUID)
    }

    public var target: Target

    public init(target: Target) {
        self.target = target
    }

    /// 解析 URL；scheme、host 或参数不合法时返回 nil。
    public static func parse(_ url: URL) -> KairoDeepLink? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "kairo",
              let host = components.host?.lowercased() else {
            return nil
        }
        let segments = components.path.split(separator: "/").map(String.init)
        switch host {
        case "task":
            if segments.count == 1, !segments[0].isEmpty {
                return KairoDeepLink(target: .taskID(segments[0]))
            }
            if segments.isEmpty,
               let title = components.queryItems?.first(where: { $0.name == "title" })?.value?
                   .trimmingCharacters(in: .whitespacesAndNewlines),
               !title.isEmpty {
                return KairoDeepLink(target: .taskTitle(title))
            }
            return nil
        case "project":
            guard segments.count == 1, let id = UUID(uuidString: segments[0]) else { return nil }
            return KairoDeepLink(target: .projectID(id))
        default:
            return nil
        }
    }
}

/// 深链定位结果：命中的任务、候选数量与项目匹配状态。
public struct DeepLinkMatch: Equatable, Sendable {
    public var taskID: UUID?
    /// 符合标识/标题的候选数（用于「存在多选时提示」）；按 ID 命中恒为 1。
    public var matchCount: Int
    /// 仅 `kairo://project/<id>` 有意义：项目 ID 是否与当前项目一致。
    public var projectMatched: Bool

    public init(taskID: UUID? = nil, matchCount: Int = 0, projectMatched: Bool = false) {
        self.taskID = taskID
        self.matchCount = matchCount
        self.projectMatched = projectMatched
    }
}

public enum KairoDeepLinkResolver {
    /// 在当前项目中定位深链目标。
    /// - 任务 ID：接受完整 UUID 或 ≥4 位唯一前缀；前缀不足或歧义时不返回任务。
    /// - 任务标题：优先精确匹配；无精确匹配时忽略大小写与变音符；取大纲顺序首个。
    /// - 项目 ID：只报告匹配状态。
    public static func resolve(_ link: KairoDeepLink, in project: Project) -> DeepLinkMatch {
        switch link.target {
        case .projectID(let id):
            return DeepLinkMatch(projectMatched: project.metadata.id == id)
        case .taskID(let raw):
            let candidates = tasksMatching(identifier: raw, in: project)
            return DeepLinkMatch(
                taskID: candidates.first?.id,
                matchCount: candidates.count
            )
        case .taskTitle(let title):
            let exact = project.tasks.filter { $0.title == title }
            let candidates = exact.isEmpty ? tasksMatching(title: title, in: project) : exact
            return DeepLinkMatch(
                taskID: candidates.first?.id,
                matchCount: candidates.count
            )
        }
    }

    private static func tasksMatching(identifier raw: String, in project: Project) -> [TaskItem] {
        if let id = UUID(uuidString: raw) {
            return project.tasks.filter { $0.id == id }
        }
        let prefix = raw.lowercased()
        guard prefix.count >= 4 else { return [] }
        return project.tasks.filter { $0.id.uuidString.lowercased().hasPrefix(prefix) }
    }

    private static func tasksMatching(title: String, in project: Project) -> [TaskItem] {
        project.tasks.filter {
            $0.title.compare(title, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }
    }
}

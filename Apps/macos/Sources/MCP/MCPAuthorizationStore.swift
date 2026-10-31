import Foundation
import KaidoMCPCore

/// MCP 可访问的目录白名单（App Store 沙盒版）。
///
/// 沙盒里没有「全盘读写」，第三方客户端也不能替用户授权。用户在应用内选目录，
/// 这里把目录换成 app-scope 书签存下来，之后 MCP 工具只能碰白名单内的文件。
///
/// 官网直装版不注入本策略（`AllowAllPaths`），行为与过去一致。
final class MCPAuthorizationStore: ObservableObject, MCPPathPolicy, @unchecked Sendable {
    /// 一条已授权目录。`scope` 持有期间该目录可读写；释放即归还。
    struct Root: Identifiable, Equatable {
        let id: UUID
        let url: URL

        static func == (lhs: Root, rhs: Root) -> Bool { lhs.id == rhs.id && lhs.url == rhs.url }
    }

    /// `UserDefaults` 键；改结构时递增版本后缀。
    static let defaultsKey = "kaido.mcp.authorized-roots.v1"

    @Published private(set) var roots: [Root] = []

    private let defaults: UserDefaults
    /// 持有的安全作用域授权，键与 `roots[].id` 对应。
    private var scopes: [UUID: ProjectScope] = [:]
    /// 给 `allows(_:)` 用的路径快照：HTTP 处理线程不碰主线程状态。
    private let lock = NSLock()
    private var allowedPaths: [String] = []

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        restore()
    }

    /// 授权一个目录（重复选择同一目录只保留一条）。
    @discardableResult
    func authorize(_ url: URL) -> Bool {
        let scope = ProjectScope(url: url)
        let canonical = Self.canonical(scope.url.path)
        if let existing = roots.first(where: { Self.canonical($0.url.path) == canonical }) {
            scopes[existing.id] = scope
            publish()
            return true
        }
        let root = Root(id: UUID(), url: scope.url)
        roots.append(root)
        scopes[root.id] = scope
        persist()
        publish()
        return true
    }

    /// 撤销授权：立刻停止访问并把书签从存储里删掉。
    func revoke(_ id: UUID) {
        roots.removeAll { $0.id == id }
        scopes[id] = nil
        persist()
        publish()
    }

    // MARK: - MCPPathPolicy

    /// 路径是否落在某个已授权目录内（含目录本身）。
    ///
    /// 按路径分量比较，`/work/beta` 不会因为前缀相同而放行 `/work/beta2`。
    nonisolated func allows(_ url: URL) -> Bool {
        let candidate = Self.canonical(url.path)
        lock.lock()
        let roots = allowedPaths
        lock.unlock()
        return roots.contains { candidate == $0 || candidate.hasPrefix($0 + "/") }
    }

    // MARK: - 持久化

    private func restore() {
        guard let stored = defaults.array(forKey: Self.defaultsKey) as? [Data] else { return }
        for data in stored {
            var stale = false
            guard let url = try? URL(
                resolvingBookmarkData: data,
                options: .withSecurityScope,
                relativeTo: nil,
                bookmarkDataIsStale: &stale
            ) else { continue }
            let scope = ProjectScope(url: url)
            let root = Root(id: UUID(), url: scope.url)
            roots.append(root)
            scopes[root.id] = scope
        }
        publish()
    }

    private func persist() {
        let data = roots.compactMap { root -> Data? in
            try? root.url.bookmarkData(
                options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
            )
        }
        defaults.set(data, forKey: Self.defaultsKey)
    }

    /// 同步白名单快照（`allows` 不触碰主线程状态）。
    private func publish() {
        let paths = roots.map { Self.canonical($0.url.path) }
        lock.lock()
        allowedPaths = paths
        lock.unlock()
    }

    /// 比较口径：标准路径 + 去尾斜杠（根目录 `/` 例外）。
    static func canonical(_ path: String) -> String {
        var value = URL(fileURLWithPath: path).standardizedFileURL.path
        while value.count > 1, value.hasSuffix("/") {
            value.removeLast()
        }
        return value
    }
}

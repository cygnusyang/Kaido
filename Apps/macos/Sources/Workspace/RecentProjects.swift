import Foundation

/// 最近打开的项目文件（最多 5 条，最新在前）。
///
/// 每条记录存「路径 + 安全作用域书签」：
/// - 路径决定菜单显示顺序与去重口径（同一文件多种写法只占一条）；
/// - 书签是 App Store 沙盒版跨启动访问用户文件的唯一凭据（`com.apple.security.files.bookmarks.app-scope`）。
///   非沙盒构建里书签照建照解，只是 `startAccessingSecurityScopedResource()` 变成空操作。
///
/// 存储位置是 `UserDefaults`，与视图偏好同一域（`WorkspaceStore.defaults`），
/// 测试注入独立 suite 即可隔离。
struct RecentProjects {
    /// 上限（产品要求：最多存 5 个）。
    static let limit = 5
    /// `UserDefaults` 键。改结构时递增版本后缀。
    static let defaultsKey = "kaido.recent.projects.v2"
    /// 旧版只存路径的键；读到就迁移到 v2 后删除。
    static let legacyDefaultsKey = "kaido.recent.projects.v1"

    /// 一条记录。书签可为空（旧数据、或创建失败——例如文件在只读卷上）。
    private struct Entry: Equatable {
        var path: String
        var bookmark: Data?
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 当前列表，最新在前。非法持久化值（类型不符）按空列表处理，不阻塞启动。
    var urls: [URL] {
        entries().map { URL(fileURLWithPath: $0.path) }
    }

    /// 记录一次成功打开或保存：同一文件去重后置顶，超限截断，同时刷新书签。
    ///
    /// 去重口径是标准化路径，避免同一文件以 `~`、相对路径、`/private` 前缀等
    /// 多种写法各占一条。
    func note(_ url: URL) {
        let normalized = URL(fileURLWithPath: Self.path(of: url))
        let entry = Entry(path: normalized.path, bookmark: Self.makeBookmark(for: normalized))
        var rest = entries().filter { $0.path != entry.path }
        rest.insert(entry, at: 0)
        write(Array(rest.prefix(Self.limit)))
    }

    /// 移除一条（打开失败或文件已被删除）。
    func remove(_ url: URL) {
        let path = Self.path(of: url)
        write(entries().filter { $0.path != path })
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
    }

    /// 剔除磁盘上已不存在的条目，返回保留下来的列表。
    ///
    /// 沙盒下「存在与否」必须在拿到访问权之后问：`fileExists` 对容器外、
    /// 未授权的路径一律返回 false，先判存在会把整张列表误清空。因此这里
    /// 逐条开启作用域再判断，判完立即释放。
    @discardableResult
    func pruneMissing(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        let all = entries()
        let kept = all.filter { fileExists(beginScope(forPath: $0.path).url.path) }
        if kept.count != all.count {
            write(kept)
        }
        return kept.map { URL(fileURLWithPath: $0.path) }
    }

    /// 启动默认打开的目标：最新一条且磁盘上仍存在。返回的 `scope` 由调用方持有
    /// （丢掉即释放访问权）。顺手剔除失效条目，避免菜单里挂着打不开的死链。
    func mostRecentAccessible(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> (url: URL, scope: ProjectScope)? {
        let all = entries()
        var kept: [Entry] = []
        var hit: (url: URL, scope: ProjectScope)?
        for entry in all {
            let scope = beginScope(forPath: entry.path)
            guard fileExists(scope.url.path) else { continue }
            kept.append(entry)
            if hit == nil { hit = (scope.url, scope) }
        }
        if kept.count != all.count {
            write(kept)
        }
        return hit
    }

    /// 取得某条记录的访问权：优先按书签解析成真实 URL，书签缺失/损坏时退回原路径
    /// （该路径若来自文件选择面板，本会话仍可用）。返回的 `scope` 由调用方持有。
    func beginScope(for url: URL) -> ProjectScope {
        beginScope(forPath: Self.path(of: url))
    }

    /// 菜单显示名：同名文件用父目录消歧，避免两条一模一样的菜单项。
    static func displayNames(for urls: [URL]) -> [String] {
        let names = urls.map(\.lastPathComponent)
        var counts: [String: Int] = [:]
        for name in names {
            counts[name, default: 0] += 1
        }
        return zip(urls, names).map { url, name in
            guard counts[name, default: 0] > 1 else { return name }
            let parent = url.deletingLastPathComponent().lastPathComponent
            return parent.isEmpty ? name : "\(parent)/\(name)"
        }
    }

    /// 持久化与实际比较统一使用的路径口径。
    static func path(of url: URL) -> String {
        url.standardizedFileURL.resolvingSymlinksInPath().path
    }

    // MARK: - 书签

    private func beginScope(forPath path: String) -> ProjectScope {
        guard let entry = entries().first(where: { $0.path == path }),
              let data = entry.bookmark,
              let resolved = Self.resolveBookmark(data) else {
            return ProjectScope(url: URL(fileURLWithPath: path))
        }
        let scope = ProjectScope(url: resolved.url)
        if resolved.isStale {
            // 文件被移动/重命名后旧书签失效：就地换新，列表顺序不动。
            replaceBookmark(forPath: path, with: Self.makeBookmark(for: scope.url))
        }
        return scope
    }

    private static func makeBookmark(for url: URL) -> Data? {
        try? url.bookmarkData(
            options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil
        )
    }

    private static func resolveBookmark(_ data: Data) -> (url: URL, isStale: Bool)? {
        var isStale = false
        guard let url = try? URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        ) else {
            return nil
        }
        return (url, isStale)
    }

    private func replaceBookmark(forPath path: String, with bookmark: Data?) {
        var all = entries()
        guard let index = all.firstIndex(where: { $0.path == path }) else { return }
        all[index].bookmark = bookmark
        write(all)
    }

    // MARK: - 持久化

    private func entries() -> [Entry] {
        if let raw = defaults.array(forKey: Self.defaultsKey) as? [[String: Any]] {
            return Array(raw.compactMap { dict -> Entry? in
                guard let path = dict["path"] as? String else { return nil }
                return Entry(path: path, bookmark: dict["bookmark"] as? Data)
            }.prefix(Self.limit))
        }
        // v1 → v2：旧数据只有路径，先搬过来，书签等下次打开/保存时补。
        let legacy = defaults.stringArray(forKey: Self.legacyDefaultsKey) ?? []
        guard !legacy.isEmpty else { return [] }
        let migrated = legacy.map { Entry(path: $0, bookmark: nil) }
        write(migrated)
        defaults.removeObject(forKey: Self.legacyDefaultsKey)
        return Array(migrated.prefix(Self.limit))
    }

    private func write(_ list: [Entry]) {
        if list.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
            return
        }
        defaults.set(list.map { entry -> [String: Any] in
            var dict: [String: Any] = ["path": entry.path]
            if let bookmark = entry.bookmark {
                dict["bookmark"] = bookmark
            }
            return dict
        }, forKey: Self.defaultsKey)
    }
}

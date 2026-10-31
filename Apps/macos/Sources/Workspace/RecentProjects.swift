import Foundation

/// 最近打开的项目文件（最多 5 条，最新在前）。
///
/// 只存绝对路径，不存安全作用域书签：Zeno 的项目文件通常就在工作目录里，
/// 移动/删除后路径失效直接剔除，比维护书签与沙盒授权简单。
/// 存储位置是 `UserDefaults`，与视图偏好同一域（`WorkspaceStore.defaults`），
/// 测试注入独立 suite 即可隔离。
struct RecentProjects {
    /// 上限（产品要求：最多存 5 个）。
    static let limit = 5
    /// `UserDefaults` 键。改结构时递增版本后缀。
    static let defaultsKey = "zeno.recent.projects.v1"

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    /// 当前列表，最新在前。非法持久化值（类型不符）按空列表处理，不阻塞启动。
    var urls: [URL] {
        storedPaths().map { URL(fileURLWithPath: $0) }
    }

    /// 记录一次成功打开或保存：同一文件去重后置顶，超限截断。
    ///
    /// 去重口径是标准化路径，避免同一文件以 `~`、相对路径、`/private` 前缀等
    /// 多种写法各占一条。
    func note(_ url: URL) {
        let path = Self.path(of: url)
        var paths = storedPaths().filter { $0 != path }
        paths.insert(path, at: 0)
        write(Array(paths.prefix(Self.limit)))
    }

    /// 移除一条（打开失败或文件已被删除）。
    func remove(_ url: URL) {
        let path = Self.path(of: url)
        write(storedPaths().filter { $0 != path })
    }

    func clear() {
        defaults.removeObject(forKey: Self.defaultsKey)
    }

    /// 剔除磁盘上已不存在的条目，返回保留下来的列表。
    @discardableResult
    func pruneMissing(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> [URL] {
        let stored = storedPaths()
        let kept = stored.filter(fileExists)
        if kept.count != stored.count {
            write(kept)
        }
        return kept.map { URL(fileURLWithPath: $0) }
    }

    /// 启动默认打开的目标：最新一条且磁盘上仍存在。
    ///
    /// 顺手剔除失效条目，避免「最近打开」菜单里挂着打不开的死链。
    func mostRecentExisting(
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) -> URL? {
        pruneMissing(fileExists: fileExists).first
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

    private func storedPaths() -> [String] {
        guard let paths = defaults.stringArray(forKey: Self.defaultsKey) else { return [] }
        // 旧数据或外部写入可能超过上限：读取时就截断，菜单不会多出条目。
        return Array(paths.prefix(Self.limit))
    }

    private func write(_ paths: [String]) {
        if paths.isEmpty {
            defaults.removeObject(forKey: Self.defaultsKey)
        } else {
            defaults.set(paths, forKey: Self.defaultsKey)
        }
    }
}

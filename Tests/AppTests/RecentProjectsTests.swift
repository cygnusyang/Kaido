import Foundation
import Testing
import ZenoCore
@testable import ZenoMacApp

/// 最近打开的项目：存储口径（去重、上限、失效剔除）、启动默认打开、菜单与面板入口。
@MainActor
@Suite("最近打开的项目")
struct RecentProjectsTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "zeno.apptests.recent.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 造一个真实 `.zeno` 文件；写盘用的 store 顺手把路径记进同一个 defaults 域。
    @discardableResult
    private func makeProjectFile(
        named name: String,
        in directory: URL,
        defaults: UserDefaults
    ) throws -> URL {
        let url = directory.appendingPathComponent(name)
        let writer = WorkspaceStore(defaults: defaults)
        writer.dispatch(.setProjectTitle(name))
        writer.save(to: url)
        #expect(writer.alertMessage == nil)
        #expect(FileManager.default.fileExists(atPath: url.path))
        return url
    }

    // MARK: - 存储口径

    /// 最多 5 条，最新在前，超出的旧条目被挤掉。
    @Test func keepsAtMostFiveNewestFirst() {
        let store = RecentProjects(defaults: makeDefaults())
        let urls = (0..<7).map { URL(fileURLWithPath: "/tmp/zeno-recent-\($0).zeno") }
        for url in urls {
            store.note(url)
        }
        #expect(store.urls.map(\.lastPathComponent) == urls.reversed().prefix(5).map(\.lastPathComponent))
        #expect(RecentProjects.limit == 5)
    }

    /// 同一文件重复打开只留一条，并提到最前。
    @Test func notingSameFileAgainMovesItToFront() {
        let store = RecentProjects(defaults: makeDefaults())
        let first = URL(fileURLWithPath: "/tmp/a.zeno")
        let second = URL(fileURLWithPath: "/tmp/b.zeno")
        store.note(first)
        store.note(second)
        store.note(first)
        // 存储用解析后的绝对路径（macOS 上 /tmp 实为 /private/tmp），断言走同一口径。
        #expect(store.urls.map { RecentProjects.path(of: $0) }
            == [first, second].map { RecentProjects.path(of: $0) })
    }

    /// 路径写法不同（相对路径 / 多余分隔符）算同一个文件。
    @Test func deduplicatesByStandardizedPath() {
        let store = RecentProjects(defaults: makeDefaults())
        store.note(URL(fileURLWithPath: "/tmp/zeno/./a.zeno"))
        store.note(URL(fileURLWithPath: "/tmp/zeno/a.zeno"))
        #expect(store.urls.count == 1)
    }

    /// 持久化值类型不符（外部写入/旧版本残留）按空列表处理，不阻塞启动。
    @Test func corruptStoredValueReadsAsEmpty() {
        let defaults = makeDefaults()
        defaults.set(42, forKey: RecentProjects.defaultsKey)
        #expect(RecentProjects(defaults: defaults).urls.isEmpty)
    }

    /// 已删除的文件从列表剔除，最近可打开的目标顺延到下一条。
    @Test func missingFilesArePrunedBeforeUse() {
        let existing = URL(fileURLWithPath: "/tmp/zeno-recent/existing.zeno")
        let gone = URL(fileURLWithPath: "/tmp/zeno-recent/gone.zeno")
        let defaults = makeDefaults()
        let store = RecentProjects(defaults: defaults)
        store.note(existing)
        store.note(gone)

        let exists: (String) -> Bool = { $0 == RecentProjects.path(of: existing) }
        #expect(store.mostRecentExisting(fileExists: exists)?.path == RecentProjects.path(of: existing))
        // 失效条目已被剔除，列表只剩存在的那条。
        #expect(store.urls.map { RecentProjects.path(of: $0) } == [RecentProjects.path(of: existing)])
    }

    /// 重名文件用父目录消歧，菜单里不会出现两条一模一样的标题。
    @Test func displayNamesDisambiguateDuplicateFilenames() {
        let urls = [
            URL(fileURLWithPath: "/work/alpha/demo.zeno"),
            URL(fileURLWithPath: "/work/beta/demo.zeno"),
            URL(fileURLWithPath: "/work/gamma/other.zeno"),
        ]
        #expect(RecentProjects.displayNames(for: urls) == [
            "alpha/demo.zeno",
            "beta/demo.zeno",
            "other.zeno",
        ])
    }

    // MARK: - Store 集成

    /// 打开成功即进列表；打开失败（文件不存在）不进列表。
    @Test func openingRecordsProjectAndFailureDoesNot() throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        let url = try makeProjectFile(named: "opened.zeno", in: directory, defaults: defaults)

        let store = WorkspaceStore(defaults: defaults)
        store.clearRecentProjects()
        #expect(store.recentProjects.isEmpty)

        #expect(store.open(url: url))
        #expect(store.recentProjects.map { RecentProjects.path(of: $0) } == [RecentProjects.path(of: url)])

        let missing = directory.appendingPathComponent("missing.zeno")
        store.clearRecentProjects()
        #expect(store.open(url: missing) == false)
        #expect(store.recentProjects.isEmpty)
    }

    /// 启动默认打开最新一条（用户要求：默认打开最后一个）。
    ///
    /// D-030：等待方式从「墙钟 sleep + 轮询」改为完成回执（`awaitPendingOpenForTesting`），
    /// 并行全量下不再有轮询窗口可超时——失败只可能来自真实断言。
    @Test func launchOpensTheMostRecentProject() async throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        try makeProjectFile(named: "older.zeno", in: directory, defaults: defaults)
        let newest = try makeProjectFile(named: "newest.zeno", in: directory, defaults: defaults)

        let store = WorkspaceStore(defaults: defaults)
        #expect(store.openMostRecentProjectOnLaunch())
        await store.awaitPendingOpenForTesting()
        let opened = try #require(store.projectURL)
        #expect(RecentProjects.path(of: opened) == RecentProjects.path(of: newest))
        #expect(store.recentProjects.first.map { RecentProjects.path(of: $0) }
            == RecentProjects.path(of: newest))
    }

    /// 本次启动已有显式打开请求（双击文件 / 深链）时让位，不抢用户要打开的文件。
    @Test func explicitOpenRequestSuppressesLaunchOpen() throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        try makeProjectFile(named: "recent.zeno", in: directory, defaults: defaults)

        let store = WorkspaceStore(defaults: defaults)
        store.noteExplicitOpenRequest()
        #expect(store.openMostRecentProjectOnLaunch() == false)
        #expect(store.projectURL == nil)
    }

    /// 没有最近文件时不打开任何东西，且只尝试一次（之后出现最近文件也不再自动打开）。
    @Test func launchOpenTriesOnlyOnce() throws {
        let defaults = makeDefaults()
        let store = WorkspaceStore(defaults: defaults)
        #expect(store.openMostRecentProjectOnLaunch() == false)

        let directory = try makeTemporaryDirectory()
        try makeProjectFile(named: "late.zeno", in: directory, defaults: defaults)
        #expect(store.openMostRecentProjectOnLaunch() == false)
        #expect(store.projectURL == nil)
    }

    /// 「清除菜单」清空列表，不影响已打开的项目。
    @Test func clearingRecentProjectsKeepsCurrentProject() throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        let url = try makeProjectFile(named: "keep.zeno", in: directory, defaults: defaults)

        let store = WorkspaceStore(defaults: defaults)
        #expect(store.open(url: url))
        store.clearRecentProjects()
        #expect(store.recentProjects.isEmpty)
        #expect(store.projectURL.map { RecentProjects.path(of: $0) } == RecentProjects.path(of: url))
        #expect(RecentProjects(defaults: defaults).urls.isEmpty)
    }

    // MARK: - 菜单与命令面板

    /// 最近文件在注册表里各占一条命令（菜单子项与 ⌘K 面板同源），另有清除命令。
    @Test func catalogExposesRecentCommands() throws {
        let defaults = makeDefaults()
        let directory = try makeTemporaryDirectory()
        let url = try makeProjectFile(named: "alpha.zeno", in: directory, defaults: defaults)

        let store = WorkspaceStore(defaults: defaults)
        #expect(store.open(url: url))
        let commands = ZenoCommandCatalog.make(
            store: store,
            requestOpen: {},
            requestSave: {},
            requestSaveAs: {}
        )

        let item = try #require(commands.first { $0.id == "file.openRecent.item.0" })
        #expect(item.group == .file)
        #expect(item.title == "alpha.zeno")
        #expect(item.aliases.contains(RecentProjects.path(of: url)))
        #expect(CommandPalette.matching("alpha", in: commands).contains { $0.id == item.id })

        let clear = try #require(commands.first { $0.id == "file.openRecent.clear" })
        #expect(clear.title == I18n.t("menu.file.open_recent.clear", "Clear Menu"))
    }

    /// 列表为空时只有菜单占位文案，不产生「清除菜单」这类无处可点的命令。
    @Test func catalogOmitsRecentCommandsWhenEmpty() {
        let store = WorkspaceStore(defaults: makeDefaults())
        store.clearRecentProjects()
        let commands = ZenoCommandCatalog.make(
            store: store,
            requestOpen: {},
            requestSave: {},
            requestSaveAs: {}
        )
        #expect(!commands.contains { $0.id.hasPrefix("file.openRecent.") })
    }
}

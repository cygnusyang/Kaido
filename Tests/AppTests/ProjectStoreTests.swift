import Foundation
import Testing
import KairoCore
@testable import KairoMacApp

/// 应用门面交互测试：大纲键盘语义、视图切换、命令注册表与违例重算。
/// `ContentView` 的 `.onKeyPress` 与工具栏把事件转发到这些方法；方法行为由本套件
/// 覆盖，视图画面由 `GUIRenderTests` 离屏渲染覆盖。
@MainActor
@Suite("ProjectStore 交互")
struct ProjectStoreTests {
    private func makeCatalog(store: ProjectStore) -> [KairoCommand] {
        KairoCommandCatalog.make(
            store: store,
            find: FindModel(),
            requestOpen: {},
            requestSave: {}
        )
    }

    private func command(_ commands: [KairoCommand], _ id: String) throws -> KairoCommand {
        try #require(commands.first { $0.id == id })
    }

    private func task(_ store: ProjectStore, _ title: String) throws -> TaskItem {
        try #require(store.project.tasks.first { $0.title == title })
    }

    private func indexOf(_ store: ProjectStore, _ id: UUID) throws -> Int {
        try #require(store.project.tasks.firstIndex { $0.id == id })
    }

    // MARK: - 初始状态

    @Test func storeSeedsDemoProjectAndSchedule() throws {
        let store = ProjectStore()
        #expect(store.project.tasks.count == 10)
        #expect(store.viewMode == .outline)
        #expect(store.selection == nil)
        #expect(store.violations.isEmpty)

        let schedule = try #require(store.schedule)
        #expect(!schedule.tasks.isEmpty)
    }

    @Test func schedulePlacesDependentTaskAfterPredecessor() throws {
        let store = ProjectStore()
        let backend = try task(store, "实现搜索后端")
        let review = try task(store, "Code Review 搜索模块")
        let schedule = try #require(store.schedule)
        let backendSlot = try #require(schedule.scheduled(backend.id))
        let reviewSlot = try #require(schedule.scheduled(review.id))
        #expect(reviewSlot.scheduledStart >= backendSlot.scheduledFinish)
    }

    // MARK: - 命令注册表（菜单与 ⌘K 同源）

    @Test func catalogIsSingleSourceForMenuAndPalette() {
        let commands = makeCatalog(store: ProjectStore())
        #expect(commands.count == 16)
        #expect(Set(commands.map(\.id)).count == commands.count)
        #expect(Set(commands.map(\.group)) == Set(["文件", "大纲", "任务", "视图", "查找"]))
        #expect(commands.allSatisfy { !$0.title.isEmpty })
        #expect(commands.contains { $0.id == "palette.show" })
    }

    @Test func shortcutLabelsMatchMenuBindings() throws {
        let commands = makeCatalog(store: ProjectStore())
        #expect(try command(commands, "palette.show").shortcut?.label == "⌘K")
        #expect(try command(commands, "find.previous").shortcut?.label == "⇧⌘G")
        #expect(try command(commands, "outline.newSibling").shortcut?.label == "⌘↩")
        #expect(try command(commands, "view.gantt").shortcut == nil)
    }

    @Test func viewCatalogCommandsSwitchViewMode() throws {
        let store = ProjectStore()
        let commands = makeCatalog(store: store)

        try command(commands, "view.gantt").action()
        #expect(store.viewMode == .gantt)
        #expect(store.viewMode.title == "甘特")

        try command(commands, "view.outline").action()
        #expect(store.viewMode == .outline)
        #expect(store.viewMode.title == "任务")
    }

    @Test func paletteCommandOpensPalette() throws {
        let store = ProjectStore()
        try command(makeCatalog(store: store), "palette.show").action()
        #expect(store.showCommandPalette)
    }

    @Test func findCommandReopensAndRefocusesEveryPress() throws {
        let store = ProjectStore()
        let show = try command(makeCatalog(store: store), "find.show")

        show.action()
        #expect(store.showFindBar)
        let firstToken = store.findFocusToken

        show.action()
        #expect(store.findFocusToken == firstToken + 1)
    }

    @Test func paletteFiltersCommandsByTitle() {
        let commands = makeCatalog(store: ProjectStore())
        #expect(CommandPalette.matching("甘特", in: commands).map(\.id) == ["view.gantt"])
        #expect(CommandPalette.matching("  ", in: commands).count == commands.count)
        #expect(CommandPalette.matching("不存在的命令", in: commands).isEmpty)
    }

    // MARK: - 大纲键盘语义（Tab / Shift-Tab / Return）

    @Test func tabIndentsSelectedTaskUnderPreviousSibling() throws {
        let store = ProjectStore()
        let review = try task(store, "Code Review 搜索模块")
        let release = try task(store, "发布 v1.0")

        store.selection = release.id
        store.indentSelected()

        #expect(try task(store, "发布 v1.0").parentID == review.id)
    }

    @Test func shiftTabOutdentsSubtreeAfterParent() throws {
        let store = ProjectStore()
        let review = try task(store, "Code Review 搜索模块")
        let release = try task(store, "发布 v1.0")

        store.selection = release.id
        store.indentSelected()
        store.outdentSelected()

        let moved = try task(store, "发布 v1.0")
        #expect(moved.parentID == nil)
        #expect(try indexOf(store, moved.id) > indexOf(store, review.id))
    }

    @Test func returnInsertsSiblingAfterSelectionAndSelectsIt() throws {
        let store = ProjectStore()
        let backend = try task(store, "实现搜索后端")

        store.selection = backend.id
        store.insertSiblingAfterSelection()

        let newID = try #require(store.selection)
        let created = try #require(store.project.tasks.first { $0.id == newID })
        #expect(created.title == "新任务")
        #expect(created.parentID == nil)
        #expect(try indexOf(store, newID) == indexOf(store, backend.id) + 1)
    }

    @Test func returnOnGroupCreatesChildTask() throws {
        let store = ProjectStore()
        store.selection = nil
        let groupID = store.addTask(kind: .group, parentID: nil)

        store.selection = groupID
        store.insertSiblingAfterSelection()

        let newID = try #require(store.selection)
        let created = try #require(store.project.tasks.first { $0.id == newID })
        #expect(created.parentID == groupID)
    }

    @Test func newTaskBecomesChildOfSelection() throws {
        let store = ProjectStore()
        let backend = try task(store, "实现搜索后端")

        store.selection = backend.id
        let id = store.addTask(kind: .task)

        let created = try #require(store.project.tasks.first { $0.id == id })
        #expect(created.parentID == backend.id)
        #expect(created.title == "新任务")
        #expect(store.selection == id)
    }

    @Test func outlineCommandsDoNothingWithoutSelection() {
        let store = ProjectStore()
        store.selection = nil
        let before = store.project.tasks

        store.indentSelected()
        store.outdentSelected()
        store.insertSiblingAfterSelection()

        #expect(store.project.tasks == before)
    }

    // MARK: - 违例重算（US-E4-07）

    @Test func constraintConflictRecomputesAndClearsViolations() throws {
        let store = ProjectStore()
        var release = try task(store, "发布 v1.0")
        release.constraint = .endNoLaterThan(Date().addingTimeInterval(-86_400))
        store.update(release)

        // 收紧最晚结束会同时产生负宽延与时限冲突两条记录；面板与行内图标都由此驱动。
        let related = store.violations.filter { $0.taskID == release.id }
        let codes = Set(related.map(\.code))
        #expect(codes.contains("constraint_is_prerequisite"))
        #expect(related.allSatisfy { $0.severity == .error })
        #expect(related.contains { $0.message.contains("发布 v1.0") })

        var fixed = try #require(store.project.tasks.first { $0.id == release.id })
        fixed.constraint = nil
        store.update(fixed)
        #expect(store.violations.filter { $0.taskID == release.id }.isEmpty)
    }
}

import Foundation
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

/// v0.14 G8：基线菜单与图例（docs/features/10-multi-baseline-gantt.md §4 / §5）。
///
/// 覆盖用户可见路径：① 创建入口恒为「基线」菜单第 1 项，且带快捷键；
/// ② 逐条基线子菜单的 12 条命令（显示 / 对比 / 8 色 / 改名 / 删除）齐全且 id 唯一；
/// ③ 勾选态、置灰态与图例顺序由 BaselineMenuModel 一份口径给出；
/// ④ 颜色项不进 ⌘K；⑤ 改名草稿归一化。
@MainActor
@Suite("基线菜单与图例（v0.14）")
struct BaselineMenuTests {
    private func makeDefaults() -> UserDefaults {
        let suite = "zeno.v014.menu.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private func makeStore() -> WorkspaceStore {
        WorkspaceStore(defaults: makeDefaults(), seedsDemoData: true)
    }

    private func makeCatalog(_ store: WorkspaceStore) -> [ZenoCommand] {
        ZenoCommandCatalog.make(store: store, requestOpen: {}, requestSave: {}, requestSaveAs: {})
    }

    private func command(_ commands: [ZenoCommand], _ id: String) throws -> ZenoCommand {
        try #require(commands.first { $0.id == id })
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("zeno-v014-menu-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    /// 建 N 条基线，返回按创建顺序的 ID。
    @discardableResult
    private func createBaselines(_ count: Int, in store: WorkspaceStore) -> [UUID] {
        var ids: [UUID] = []
        for index in 0..<count {
            store.dispatch(.createBaseline("基线 \(index)"))
            ids.append(store.baselines[index].id)
        }
        return ids
    }

    private func model(_ store: WorkspaceStore) -> BaselineMenuModel {
        BaselineMenuModel(baselines: store.baselines, viewState: store.viewState)
    }

    private func visibleBaselineIDs(_ commands: [ZenoCommand]) -> [ZenoCommand] {
        commands.filter { $0.group == .baseline && !$0.isPaletteHidden }
    }

    // MARK: - 菜单结构

    /// 无基线时命令总数 50：v0.14 的 44 条 + v0.15 的「管理基线…」「导出偏差 CSV…」
    /// + F-22-06 的「项目设置…」+ v1.2 互操作 3 条（导入 / 导出 MSPDI / 导出 OmniPlan 置灰）。
    @Test func catalogKeepsLegacyCountWithoutBaselines() {
        let commands = makeCatalog(makeStore())
        #expect(commands.count == 50)
        #expect(Set(commands.map(\.id)).count == commands.count)
        // 新增分组必须至少有一条命令，否则分组集合与菜单对不上。
        #expect(Set(commands.map(\.group)) == Set(ZenoCommandGroup.allCases))
        #expect(commands.contains { $0.group == .baseline })
    }

    /// 创建入口：基线组第 1 条、⌥⌘B、标题非空（D-035 的可发现性靠这条）。
    @Test func createCommandLeadsBaselineGroupWithShortcut() throws {
        let commands = makeCatalog(makeStore())
        let baselineGroup = commands.filter { $0.group == .baseline }
        #expect(baselineGroup.first?.id == "baseline.create")
        #expect(try command(commands, "baseline.create").shortcut?.label == "⌥⌘B")
        // 管理入口排在静态命令末尾（菜单里也排在图例之后），但不抢快捷键。
        let staticBaselineIDs = commands
            .filter { $0.group == .baseline && !$0.id.hasPrefix("baseline.visibility.")
                && !$0.id.hasPrefix("baseline.compare.")
                && !$0.id.hasPrefix("baseline.color.")
                && !$0.id.hasPrefix("baseline.rename.")
                && !$0.id.hasPrefix("baseline.delete.")
            }
            .map(\.id)
        #expect(staticBaselineIDs == ["baseline.create", "baseline.compareClear", "baseline.manage", "baseline.exportCSV"])
        #expect(try command(commands, "baseline.manage").shortcut == nil)

        // 菜单栏分组标题与面板分组标签同源。
        #expect(ZenoCommandGroup.baseline.title == I18n.t("menu.group.baseline", "Baseline"))
    }

    /// 每条基线 12 条命令（显示 1 + 对比 1 + 8 色 + 改名 1 + 删除 1），id 不重复也不串基线。
    @Test func everyBaselineGetsTwelveCommands() throws {
        let store = makeStore()
        let ids = createBaselines(4, in: store)
        let commands = makeCatalog(store)

        #expect(commands.count == 50 + 12 * 4)
        #expect(Set(commands.map(\.id)).count == commands.count)

        for baseline in store.baselines {
            let key = baseline.id.uuidString
            // 单条基线恰好 12 条（不靠总数蒙：总数错了也能定位到具体那条）。
            #expect(commands.filter { $0.id.contains(key) }.count == 12)
            #expect(commands.contains { $0.id == "baseline.visibility.\(key)" })
            #expect(commands.contains { $0.id == "baseline.compare.\(key)" })
            #expect(commands.contains { $0.id == "baseline.rename.\(key)" })
            #expect(commands.contains { $0.id == "baseline.delete.\(key)" })
            for colorIndex in 0 ..< BaselinePalette.count {
                #expect(commands.contains { $0.id == "baseline.color.\(key).\(colorIndex)" })
            }
        }
        // 四条的 id 键各自独立：不会出现两条命令指向同一条基线。
        #expect(Set(ids.map(\.uuidString)).count == ids.count)
    }

    /// 颜色项只进菜单、不进 ⌘K：每条基线的面板可见项是 4 条（显示 / 对比 / 改名 / 删除）
    /// + 3 条静态（新建 / 不对比 / 管理基线）——面板入口漏进 ⌘K 才算漏，颜色挤进去才算多。
    @Test func colorCommandsAreHiddenFromPalette() {
        let store = makeStore()
        createBaselines(2, in: store)
        let commands = makeCatalog(store)

        let paletteVisible = visibleBaselineIDs(commands)
        #expect(paletteVisible.count == 4 + 4 * 2)
        #expect(!paletteVisible.contains { $0.id.hasPrefix("baseline.color.") })
        #expect(commands.contains { $0.id.hasPrefix("baseline.color.") && $0.isPaletteHidden })
    }

    // MARK: - 勾选与置灰

    /// 显示命令是纯视图状态：改图、不进撤销栈、不置脏。
    @Test func visibilityCommandTogglesPureViewState() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.zeno")
        let ids = createBaselines(1, in: store)
        // 新建会自动加入显示（§6），先退回未显示再验证「勾上」。
        store.dispatch(.setBaselineVisible(ids[0], false))
        store.save(to: url)
        #expect(!store.hasUnsavedChanges)
        let depth = store.undoDepthForTesting

        let commands = makeCatalog(store)
        try command(commands, "baseline.visibility.\(ids[0].uuidString)").action()

        #expect(store.viewState.visibleBaselineIDs == [ids[0]])
        #expect(store.undoDepthForTesting == depth)
        #expect(!store.hasUnsavedChanges)

        // 再点一次执行时重算状态：同一份（可能已过期的）命令仍能正确取消勾选。
        try command(commands, "baseline.visibility.\(ids[0].uuidString)").action()
        #expect(store.viewState.visibleBaselineIDs.isEmpty)
    }

    /// 主对比是单选：点第二条后前一条自动不再是当前。
    @Test func compareCommandKeepsSingleSelection() throws {
        let store = makeStore()
        let ids = createBaselines(2, in: store)
        store.dispatch(.setBaseline(ids[0]))
        let commands = makeCatalog(store)

        try command(commands, "baseline.compare.\(ids[1].uuidString)").action()
        #expect(store.selectedBaseline?.id == ids[1])

        let snapshot = model(store)
        #expect(snapshot.items.filter(\.isCompared).map(\.id) == [ids[1]])

        // 「不对比」清空选择，且菜单里该项打勾。
        try command(commands, "baseline.compareClear").action()
        #expect(store.selectedBaseline == nil)
        #expect(model(store).isCompareCleared)
    }

    /// 满 3 条时第 4 条置灰（会话会拒绝），前三条都不受影响。
    @Test func fourthBaselineVisibilityIsBlocked() {
        let store = makeStore()
        createBaselines(4, in: store)
        let snapshot = model(store)

        #expect(snapshot.items.map(\.isVisibleInGantt) == [true, true, true, false])
        #expect(snapshot.items.map(\.isVisibilityBlocked) == [false, false, false, true])
        #expect(snapshot.hiddenCount == 1)
    }

    // MARK: - 改色

    /// 8 色命令：当前色打勾、改色写模型并进撤销栈（一步）。
    @Test func colorCommandsMarkCurrentAndAreUndoable() throws {
        let store = makeStore()
        let directory = try makeTemporaryDirectory()
        let url = directory.appendingPathComponent("plan.zeno")
        let ids = createBaselines(1, in: store)
        store.save(to: url)
        let before = try #require(store.baselines.first?.colorIndex)
        let depth = store.undoDepthForTesting
        let commands = makeCatalog(store)

        let current = model(store).items[0].colorIndex
        #expect(current == before)
        #expect(BaselineMenuTests.colorIDs(ids[0], in: commands).count == BaselinePalette.count)

        let target = (before + 4) % BaselinePalette.count
        try command(commands, "baseline.color.\(ids[0].uuidString).\(target)").action()

        #expect(store.baselines.first?.colorIndex == target)
        #expect(model(store).items[0].colorIndex == target)
        #expect(store.undoDepthForTesting == depth + 1)

        store.dispatch(.undo)
        #expect(store.baselines.first?.colorIndex == before)
    }

    private static func colorIDs(_ id: UUID, in commands: [ZenoCommand]) -> [String] {
        commands
            .map(\.id)
            .filter { $0.hasPrefix("baseline.color.\(id.uuidString).") }
    }

    /// 色名与调色板一一对应：数量相等、互不重复，越界有兜底文案。
    @Test func colorNamesCoverPalette() {
        #expect(BaselineColorNames.count == BaselinePalette.count)
        #expect(DesignTokens.baselinePalette.count == BaselinePalette.count)

        let titles = (0 ..< BaselineColorNames.count).map(BaselineColorNames.title)
        #expect(Set(titles).count == titles.count)
        #expect(titles.allSatisfy { !$0.isEmpty })
        #expect(!BaselineColorNames.title(BaselinePalette.count).isEmpty)
    }

    /// 图例色块用非模板图：菜单里才按调色板原色显示（模板图会被菜单染成单色）。
    @Test func swatchesAreOpaqueColoredImages() {
        for index in 0 ..< BaselinePalette.count {
            let image = BaselineSwatch.nsImage(index)
            #expect(!image.isTemplate)
            #expect(image.size == NSSize(width: 10, height: 10))
        }
        // 越界索引回落首色，不崩。
        #expect(!BaselineSwatch.nsImage(BaselinePalette.count).isTemplate)
    }

    // MARK: - 图例

    /// 图例顺序 = 甘特轨道顺序，且带名称 / 颜色名 / 创建日期。
    @Test func legendFollowsTrackOrder() throws {
        let store = makeStore()
        let ids = createBaselines(3, in: store)
        let snapshot = model(store)

        #expect(snapshot.legend.map(\.baselineID) == ids)
        // 与甘特轨道同序：快照里真的画出来的顺序必须一致（同一份归一化口径）。
        let trackIDs = store.snapshot.gantt.visibleBaselineIDs
        #expect(!trackIDs.isEmpty)
        #expect(snapshot.legend.map(\.baselineID) == trackIDs)
        #expect(snapshot.legend.map(\.colorIndex) == snapshot.items.map(\.colorIndex))

        let first = try #require(snapshot.legend.first)
        let title = BaselineMenuModel.legendTitle(first)
        #expect(title.contains(first.name))
        #expect(title.contains(BaselineColorNames.title(first.colorIndex)))
        #expect(title.contains(Display.date(first.createdAt)))
        #expect(snapshot.hiddenCount == 0)
    }

    /// 超出上限时图例只列前 3 条，未显示条数单独给出（菜单底部的「另有 N 条未显示」）。
    @Test func legendTruncatesToLimitAndCountsHidden() {
        let store = makeStore()
        let ids = createBaselines(5, in: store)
        let snapshot = model(store)

        #expect(snapshot.legend.count == BaselineLanes.maxVisible)
        #expect(snapshot.legend.map(\.baselineID) == Array(ids.prefix(BaselineLanes.maxVisible)))
        #expect(snapshot.hiddenCount == 5 - BaselineLanes.maxVisible)
    }

    /// 「另有 N 条未显示」= 被上限截断的条数，表驱动锁死口径：
    /// 只有勾满 maxVisible 且还有剩余基线时才非零，其余情形一律 0。
    @Test func hiddenCountOnlyTracksCapTruncation() {
        struct Case { let total: Int; let unchecked: Int; let expected: Int }
        let cases = [
            Case(total: 0, unchecked: 0, expected: 0),
            Case(total: 1, unchecked: 0, expected: 0),
            Case(total: 1, unchecked: 1, expected: 0),
            Case(total: 3, unchecked: 0, expected: 0),
            Case(total: 4, unchecked: 0, expected: 1),
            Case(total: 4, unchecked: 1, expected: 0),
            Case(total: 5, unchecked: 0, expected: 2),
            Case(total: 5, unchecked: 2, expected: 0),
        ]
        for item in cases {
            let store = makeStore()
            let ids = createBaselines(item.total, in: store)
            // 新建会自动占满前 3 个名额（§6），这里只把指定的头部几条退掉。
            for index in 0 ..< item.unchecked {
                store.dispatch(.setBaselineVisible(ids[index], false))
            }
            #expect(
                model(store).hiddenCount == item.expected,
                "total=\(item.total) unchecked=\(item.unchecked)"
            )
        }
    }

    /// 一条都没勾（或没建）时图例为空，菜单只剩「尚未创建基线 / 不对比」这类静态项。
    @Test func emptyStateHasNoLegend() throws {
        let store = makeStore()
        #expect(model(store).items.isEmpty)
        #expect(model(store).legend.isEmpty)
        #expect(model(store).hiddenCount == 0)
        #expect(model(store).isCompareCleared)

        let ids = createBaselines(1, in: store)
        store.dispatch(.setBaselineVisible(ids[0], false))
        #expect(model(store).legend.isEmpty)
        #expect(model(store).items[0].isVisibleInGantt == false)
        // 只是没勾上，不是被上限截断：不该出「另有 N 条未显示」。
        #expect(model(store).hiddenCount == 0)
    }

    /// 勾选前缀与既有菜单同一写法。
    @Test func checkMarkPrefixMatchesExistingMenus() {
        #expect(BaselineMenuMark.title("在甘特图中显示", isOn: true) == "✓ 在甘特图中显示")
        #expect(BaselineMenuMark.title("在甘特图中显示", isOn: false) == "在甘特图中显示")
    }

    // MARK: - 改名与删除

    /// 改名草稿归一化：去空白、空白串不提交（会话本身也会拒绝空名）。
    @Test func renameDraftIsTrimmedAndBlankRejected() {
        #expect(BaselineRenamePrompt.normalized("  保守版  ") == "保守版")
        #expect(BaselineRenamePrompt.normalized("   ") == nil)
        #expect(BaselineRenamePrompt.normalized("") == nil)
    }

    /// 删除命令沿用既有二次确认：先登记待删，确认后才真的删。
    @Test func deleteCommandGoesThroughConfirmation() throws {
        let store = makeStore()
        let ids = createBaselines(1, in: store)
        let commands = makeCatalog(store)
        let delete = try command(commands, "baseline.delete.\(ids[0].uuidString)")
        #expect(delete.isDestructive)

        delete.action()
        #expect(store.pendingBaselineDeletion?.id == ids[0])
        #expect(store.baselines.count == 1)

        store.confirmPendingBaselineDeletion()
        #expect(store.baselines.isEmpty)
    }
}

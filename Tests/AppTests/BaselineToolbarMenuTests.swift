import Foundation
import Testing
import KaidoCore
import KaidoPresentation
@testable import KaidoMacApp

/// v0.16：工具栏基线菜单与菜单栏「基线」菜单同源（docs/features/10-multi-baseline-gantt.md §5）。
///
/// 工具栏那颗棋盘旗此前只有「选对比 / 改名 / 删除」，「在甘特图中显示」与 8 色改色
/// 只能在菜单栏改。现在两处都渲染 `BaselineMenuContent`，按 `BaselineMenuID` 生成的 id
/// 从同一份注册表取命令——菜单项与命令之间不再有两套手写字符串。
///
/// 本套件锁两件事：① 注册表里的基线命令 id 与渲染方会去取的 id 是同一批（漏一条就
/// 是菜单里凭空少一项，且不报错）；② 勾选被拒时一定有可见理由，不留「点了没反应」。
@MainActor
@Suite("基线工具栏菜单与菜单栏同源（v0.16）")
struct BaselineToolbarMenuTests {
    private func makeStore() -> WorkspaceStore {
        let suite = "kaido.v016.toolbar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(defaults: defaults, seedsDemoData: true)
    }

    private func makeCatalog(_ store: WorkspaceStore) -> [KaidoCommand] {
        KaidoCommandCatalog.make(store: store, requestOpen: {}, requestSave: {}, requestSaveAs: {})
    }

    @discardableResult
    private func createBaselines(_ count: Int, in store: WorkspaceStore) -> [UUID] {
        for index in 0 ..< count {
            store.dispatch(.createBaseline("基线 \(index)"))
        }
        return store.baselines.map(\.id)
    }

    /// 渲染方会去注册表取的 id：4 条静态项 + 每条基线 12 条（显示 / 对比 / 8 色 / 改名 / 删除）。
    private func renderedIDs(_ ids: [UUID]) -> Set<String> {
        var result: Set<String> = [
            BaselineMenuID.create,
            BaselineMenuID.compareClear,
            BaselineMenuID.manage,
            BaselineMenuID.exportCSV,
        ]
        for id in ids {
            result.insert(BaselineMenuID.visibility(id))
            result.insert(BaselineMenuID.compare(id))
            for colorIndex in 0 ..< BaselinePalette.count {
                result.insert(BaselineMenuID.color(id, colorIndex))
            }
            result.insert(BaselineMenuID.rename(id))
            result.insert(BaselineMenuID.delete(id))
        }
        return result
    }

    /// 双向对齐：注册表登记的基线命令 == 菜单（工具栏与菜单栏）会去取的命令。
    ///
    /// 多一条 = 有人加了命令却没接进菜单；少一条 = 菜单要的命令注册表没有，
    /// 而 `BaselineMenuContent` 取不到命令是静默跳过，界面上只会「少一项」。
    @Test func menuNamingMatchesRegisteredCommands() {
        let store = makeStore()
        let ids = createBaselines(3, in: store)
        let registered = Set(makeCatalog(store).filter { $0.group == .baseline }.map(\.id))

        #expect(registered == renderedIDs(ids))
        #expect(ids.count == 3)
    }

    /// 无基线时只剩静态 4 条：工具栏与菜单栏都不会渲染出「空子菜单」。
    @Test func emptyWorkspaceOnlyHasStaticItems() {
        let store = makeStore()
        #expect(Set(makeCatalog(store).filter { $0.group == .baseline }.map(\.id)) == renderedIDs([]))
    }

    /// 满 3 条时第 4 条的勾选被会话拒绝，菜单据此置灰——且置灰项一定伴随
    /// 「另有 N 条未显示」的解释（`hiddenCount > 0`），不会只灰不说原因。
    @Test func blockedVisibilityIsAlwaysExplained() {
        let store = makeStore()
        let ids = createBaselines(5, in: store)
        var model = BaselineMenuModel(baselines: store.baselines, viewState: store.viewState)

        #expect(model.items.map(\.isVisibilityBlocked) == [false, false, false, true, true])
        #expect(model.hiddenCount == 2)
        // 置灰不是画着玩的：真的去勾一次也进不了轨道。
        store.dispatch(.setBaselineVisible(ids[3], true))
        model = BaselineMenuModel(baselines: store.baselines, viewState: store.viewState)
        #expect(model.items[3].isVisibleInGantt == false)

        // 让出一个名额后立即解禁：置灰态不会残留在已经能勾上的条目上。
        store.dispatch(.setBaselineVisible(ids[0], false))
        model = BaselineMenuModel(baselines: store.baselines, viewState: store.viewState)
        #expect(model.items[3].isVisibilityBlocked == false)
        #expect(model.hiddenCount == 0)
    }
}

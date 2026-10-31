import SwiftUI
import KaidoCore
import KaidoPresentation

/// 「基线」菜单内容（v0.14 / docs/features/10-multi-baseline-gantt.md §5）。
///
/// 菜单栏顶级菜单与 ⌘K 同源：可执行项全部从 commands 注册表按 id 取，这里只负责排布
/// （子菜单 / 勾选 / 置灰）与图例——文案与动作都不在这里写第二份。
///
/// 结构（自上而下）：
/// 1. 新建基线…（恒第 1 项：D-035 的教训是入口藏起来就找不到）
/// 2. 逐条基线子菜单：在甘特图中显示 / 设为主对比 / 颜色 ▸ / 重命名… / 删除…
/// 3. 另有 N 条未显示（被上限截断时）
/// 4. 不对比
/// 5. 图例：色块 + 名称 + 创建日期，顺序 = 甘特轨道顺序
/// 6. 管理基线…（恒最底：逐条管理的收口入口 → 基线面板）
///
/// 图例放**底部**而不是顶部：第一项必须留给「新建基线」，图例是参考信息，
/// 放顶部会把唯一且必要的入口挤下去。
struct BaselineMenuContent: View {
    @ObservedObject var store: WorkspaceStore
    let commands: [KaidoCommand]
    /// 是否在菜单项上挂快捷键。只有菜单栏（`KaidoMenuCommands`）该挂：
    /// 工具栏菜单与菜单栏同时注册同一个组合键，会变成两条同键命令。
    var showsShortcuts: Bool = true

    private var model: BaselineMenuModel {
        BaselineMenuModel(baselines: store.baselines, viewState: store.viewState)
    }

    var body: some View {
        let model = self.model
        item(BaselineMenuID.create)
        Divider()
        if model.items.isEmpty {
            Text(I18n.t("menu.baseline.empty", "No Baselines Yet"))
                .disabled(true)
        } else {
            ForEach(model.items) { baseline in
                Menu(baseline.name) {
                    submenu(for: baseline)
                }
            }
            if model.hiddenCount > 0 {
                Text(I18n.t("menu.baseline.hidden_count", "%1$ld more not shown", model.hiddenCount))
                    .disabled(true)
            }
        }
        Divider()
        item(BaselineMenuID.compareClear, marked: model.isCompareCleared)
        legend(model.legend)
        // 管理入口放最底（v0.15）：新建永远第 1 项，面板是逐条管理后的延伸动作，
        // 放上面会把「新建基线」挤下去（§5 顶部的理由同样适用于底部收口）。
        Divider()
        item(BaselineMenuID.manage)
        // v0.15.1：CSV 导出此前只有 CLI 入口，界面里找不到（用户实测反馈）。
        item(BaselineMenuID.exportCSV)
    }

    // MARK: - 逐条基线

    @ViewBuilder
    private func submenu(for baseline: BaselineMenuItem) -> some View {
        item(BaselineMenuID.visibility(baseline.id), marked: baseline.isVisibleInGantt)
            // 满 3 条时勾不上（会话拒绝）：置灰 + 底部「另有 N 条未显示」把原因说清。
            .disabled(baseline.isVisibilityBlocked)
        Divider()
        item(BaselineMenuID.compare(baseline.id), marked: baseline.isCompared)
        Menu(I18n.t("menu.baseline.color_menu", "Color")) {
            ForEach(0 ..< BaselineColorNames.count, id: \.self) { colorIndex in
                item(
                    BaselineMenuID.color(baseline.id, colorIndex),
                    marked: colorIndex == baseline.colorIndex
                )
            }
        }
        Divider()
        item(BaselineMenuID.rename(baseline.id))
        item(BaselineMenuID.delete(baseline.id))
    }

    // MARK: - 图例

    @ViewBuilder
    private func legend(_ items: [BaselineLegendItem]) -> some View {
        if !items.isEmpty {
            Divider()
            Text(I18n.t("menu.baseline.legend.header", "Legend"))
                .disabled(true)
            ForEach(items) { entry in
                Button {} label: {
                    Label {
                        Text(BaselineMenuModel.legendTitle(entry))
                    } icon: {
                        BaselineSwatch.image(entry.colorIndex)
                    }
                }
                .disabled(true)
            }
        }
    }

    // MARK: - 注册表取项

    /// 从注册表取一条命令渲染成菜单项（缺项时不渲染：菜单不造动作，只排布）。
    @ViewBuilder
    private func item(_ id: String, marked: Bool = false) -> some View {
        if let command = commands.first(where: { $0.id == id }) {
            let title = BaselineMenuMark.title(command.title, isOn: marked)
            if command.isDestructive {
                Button(title, role: .destructive) { command.action() }
            } else if let shortcut = command.shortcut, showsShortcuts {
                Button(title) { command.action() }
                    .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
            } else {
                Button(title) { command.action() }
            }
        }
    }
}

/// 基线命令 id（v0.16）：注册表（`KaidoCommandCatalog.baselineCommands`）与渲染方
/// （菜单栏、工具栏、本文件的 `BaselineMenuContent`）共用这一份命名。
///
/// 以前两侧各写一遍字符串插值，id 漂了不会报错——`item(_:marked:)` 在注册表里取不到
/// 命令就静默不渲染，菜单项凭空消失。命名收在这里后，渲染方要的 id 就是注册表登记的 id。
enum BaselineMenuID {
    static let create = "baseline.create"
    static let compareClear = "baseline.compareClear"
    static let manage = "baseline.manage"
    static let exportCSV = "baseline.exportCSV"

    static func visibility(_ baselineID: UUID) -> String {
        "baseline.visibility.\(baselineID.uuidString)"
    }

    static func compare(_ baselineID: UUID) -> String {
        "baseline.compare.\(baselineID.uuidString)"
    }

    /// 改色：一条基线 × 一个调色板索引。
    static func color(_ baselineID: UUID, _ colorIndex: Int) -> String {
        "baseline.color.\(baselineID.uuidString).\(colorIndex)"
    }

    static func rename(_ baselineID: UUID) -> String {
        "baseline.rename.\(baselineID.uuidString)"
    }

    static func delete(_ baselineID: UUID) -> String {
        "baseline.delete.\(baselineID.uuidString)"
    }
}
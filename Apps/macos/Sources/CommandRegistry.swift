import AppKit
import SwiftUI
import KaidoCore
import KaidoPresentation
import InteropOmniPlan

/// 就地编辑时的原生文本撤销。
///
/// 菜单替换了系统的 `.undoRedo` 分组；若直接走会话快照，⌘Z 会把整条输入
/// 连同上一次结构变更一起回退。文本字段持有焦点时优先交给字段编辑器。
enum FieldEditorUndo {
    @MainActor
    static func perform(redo: Bool) -> Bool {
        // `NSApp` 是隐式解包可选值：测试等无 AppKit 生命周期的进程里必须安全返回。
        guard let app = NSApp,
              let window = app.keyWindow,
              let textView = window.firstResponder as? NSTextView,
              let manager = textView.undoManager ?? window.undoManager else {
            return false
        }
        if redo {
            guard manager.canRedo else { return false }
            manager.redo()
        } else {
            guard manager.canUndo else { return false }
            manager.undo()
        }
        return true
    }
}

/// 命令快捷键（菜单与命令面板共用同一份定义）。
struct KaidoShortcut {
    let key: KeyEquivalent
    let modifiers: EventModifiers

    /// 面板中展示的快捷键文本，如「⌘⇧K」。
    var label: String {
        var text = ""
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        switch key.character {
        case "\r": text += "↩"
        case "\u{1b}": text += "⎋"
        default: text += String(key.character).uppercased()
        }
        return text
    }
}

/// 菜单分组（F-0705）：分组是语义枚举，显示名走 Catalog。
///
/// 用中文串当标识会让「菜单构建匹配分组」和「面板显示分组名」绑在同一份可变文案上——
/// 换语言就会静默失配（菜单变空）。这里只留 case，文案由 `title` 查 Catalog。
enum KaidoCommandGroup: String, CaseIterable, Hashable, Sendable {
    case file, edit, outline, task, view, project, baseline, find

    /// 菜单标题 / 面板分组标签。
    var title: String {
        switch self {
        case .file: return I18n.t("menu.group.file", "File")
        case .edit: return I18n.t("menu.group.edit", "Edit")
        case .outline: return I18n.t("menu.group.outline", "Outline")
        case .task: return I18n.t("menu.group.task", "Task")
        case .view: return I18n.t("menu.group.view", "Workspace")
        // 项目级设置（工作日历）与「任务」分开：前者作用于整个项目，不在某一行上。
        case .project: return I18n.t("menu.group.project", "Project")
        case .baseline: return I18n.t("menu.group.baseline", "Baseline")
        case .find: return I18n.t("menu.group.find", "Find")
        }
    }
}

/// 一条可执行命令（US-E4-05 / F-41-01）。菜单栏与 ⌘K 面板均消费此注册表。
struct KaidoCommand: Identifiable {
    let id: String
    let title: String
    /// 菜单分组（文件 / 编辑 / 大纲 / 任务 / 视图 / 查找）。
    let group: KaidoCommandGroup
    let shortcut: KaidoShortcut?
    /// 旧标题，仅用于命令面板搜索（不显示在菜单）。
    let aliases: [String]
    /// 不进 ⌘K 面板（菜单里仍然有）。
    ///
    /// 用于「一基线 × 8 色」这类组合项：进面板会把面板挤成一份色卡（10 §5）。
    let isPaletteHidden: Bool
    /// 菜单项按破坏性操作渲染（删除基线）。
    let isDestructive: Bool
    /// 是否可执行。false = 菜单与 ⌘K 都置灰（如尚未实现的导出通道）。
    ///
    /// 取舍是「留条目 + 置灰」而不是「干脆不注册」：入口缺失时用户以为功能不存在，
    /// 置灰加说明才看得出「这条路存在，只是还没通」。
    let isEnabled: Bool
    /// 置灰原因（菜单与面板的 tooltip）。
    let disabledHint: String?
    let action: @MainActor () -> Void

    init(
        id: String,
        title: String,
        group: KaidoCommandGroup,
        shortcut: KaidoShortcut? = nil,
        aliases: [String] = [],
        isPaletteHidden: Bool = false,
        isDestructive: Bool = false,
        isEnabled: Bool = true,
        disabledHint: String? = nil,
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.shortcut = shortcut
        self.aliases = aliases
        self.isPaletteHidden = isPaletteHidden
        self.isDestructive = isDestructive
        self.isEnabled = isEnabled
        self.disabledHint = disabledHint
        self.action = action
    }
}

/// 命令注册表：应用内唯一的命令定义来源（US-E4-05 验收 3）。
@MainActor
enum KaidoCommandCatalog {
    static func make(
        store: WorkspaceStore,
        requestOpen: @escaping @MainActor () -> Void,
        requestSave: @escaping @MainActor () -> Void,
        requestSaveAs: @escaping @MainActor () -> Void
    ) -> [KaidoCommand] {
        [
            KaidoCommand(
                id: "file.open",
                title: I18n.t("menu.file.open_project", "Open Project…"),
                group: .file,
                shortcut: KaidoShortcut(key: "o", modifiers: .command),
                action: requestOpen
            ),
            KaidoCommand(
                id: "file.save",
                title: I18n.t("menu.file.save", "Save"),
                group: .file,
                shortcut: KaidoShortcut(key: "s", modifiers: .command),
                action: requestSave
            ),
            KaidoCommand(
                id: "file.saveAs",
                title: I18n.t("menu.file.save_as", "Save As…"),
                group: .file,
                shortcut: KaidoShortcut(key: "s", modifiers: [.command, .shift]),
                aliases: [I18n.t("menu.file.save_as.alias", "Save a copy")],
                action: requestSaveAs
            ),
            KaidoCommand(
                id: "file.loadExample",
                title: I18n.t("menu.file.load_example", "Load Example Project"),
                group: .file,
                aliases: [I18n.t("menu.file.load_example.alias_demo", "Load demo data"), I18n.t("menu.file.load_example.alias_example", "Example project")],
                action: { store.loadExampleProject() }
            ),
            KaidoCommand(
                id: "edit.undo",
                title: I18n.t("menu.edit.undo", "Undo"),
                group: .edit,
                shortcut: KaidoShortcut(key: "z", modifiers: .command),
                action: {
                    if !FieldEditorUndo.perform(redo: false) {
                        store.dispatch(.undo)
                    }
                }
            ),
            KaidoCommand(
                id: "edit.redo",
                title: I18n.t("menu.edit.redo", "Redo"),
                group: .edit,
                shortcut: KaidoShortcut(key: "z", modifiers: [.command, .shift]),
                action: {
                    if !FieldEditorUndo.perform(redo: true) {
                        store.dispatch(.redo)
                    }
                }
            ),
            KaidoCommand(
                id: "outline.indent",
                title: I18n.t("action.indent", "Indent"),
                group: .outline,
                shortcut: KaidoShortcut(key: "]", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.indent(id))
                }
            ),
            KaidoCommand(
                id: "outline.outdent",
                title: I18n.t("action.outdent", "Outdent"),
                group: .outline,
                shortcut: KaidoShortcut(key: "[", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.outdent(id))
                }
            ),
            KaidoCommand(
                id: "outline.newSibling",
                title: I18n.t("action.new_sibling", "New Sibling Task"),
                group: .outline,
                shortcut: KaidoShortcut(key: .return, modifiers: .command),
                action: {
                    if let id = store.selection {
                        store.dispatch(.createSibling(after: id))
                    } else {
                        store.dispatch(.createTask(parentID: nil, kind: .task))
                    }
                }
            ),
            KaidoCommand(
                id: "task.new",
                title: I18n.t("action.new_task", "New Task"),
                group: .task,
                shortcut: KaidoShortcut(key: "n", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .task)) }
            ),
            KaidoCommand(
                id: "task.newGroup",
                title: I18n.t("action.new_group", "New Group"),
                group: .task,
                shortcut: KaidoShortcut(key: "g", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .group)) }
            ),
            KaidoCommand(
                id: "task.newMilestone",
                title: I18n.t("action.new_milestone", "New Milestone"),
                group: .task,
                shortcut: KaidoShortcut(key: "m", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .milestone)) }
            ),
            // 项目设置（F-22-06）：工作日历的唯一编辑入口；菜单与 ⌘K 同源。
            KaidoCommand(
                id: "project.settings",
                title: I18n.t("menu.project.settings", "Project Settings…"),
                group: .project,
                aliases: [
                    I18n.t("menu.project.settings.alias_calendar", "Work calendar"),
                    I18n.t("menu.project.settings.alias_holidays", "Weekends and holidays"),
                ],
                action: { store.presentProjectSettings() }
            ),
            // MCP 服务（商店版托管 MCP）：AI 客户端配置与授权目录的唯一入口。
            KaidoCommand(
                id: "project.mcpService",
                title: I18n.t("menu.project.mcp_service", "MCP Service…"),
                group: .project,
                aliases: [
                    I18n.t("menu.project.mcp_service.alias_ai", "AI access"),
                    I18n.t("menu.project.mcp_service.alias_token", "Access token"),
                ],
                action: { store.presentMCPService() }
            ),
            // 互操作（v1.2 / 14 §P4）：导入必须先过预检再落地；导出是单向快照 + 旁注。
            // 三个入口都在「项目」分组下：它们作用于整份计划，不在某一行任务上。
            KaidoCommand(
                id: "project.import",
                title: I18n.t("menu.project.import", "Import…"),
                group: .project,
                aliases: [
                    I18n.t("menu.project.import.alias_msproject", "Import MS Project XML"),
                    I18n.t("menu.project.import.alias_omniplan", "Import OmniPlan"),
                ],
                action: { store.presentImport() }
            ),
            KaidoCommand(
                id: "project.exportMSProjectXML",
                title: I18n.t("menu.project.export_mspdi", "Export as MS Project XML…"),
                group: .project,
                aliases: [
                    I18n.t("menu.project.export_mspdi.alias_save", "Save as MS Project XML"),
                    I18n.t("menu.project.export_mspdi.alias_mspdi", "MSPDI export"),
                ],
                action: { store.presentMSProjectXMLExport() }
            ),
            KaidoCommand(
                id: "project.exportOmniPlan",
                title: I18n.t("menu.project.export_omniplan", "Export as OmniPlan…"),
                group: .project,
                aliases: [
                    I18n.t("menu.project.export_omniplan.alias_save", "Save as OmniPlan"),
                    I18n.t("menu.project.export_omniplan.alias_oplx", "OmniPlan export"),
                ],
                isEnabled: InteropFormats.canWrite(formatID: OmniPlanAdapter.formatID),
                action: { store.presentOmniPlanExport() }
            ),
            KaidoCommand(
                id: "view.plan",
                title: I18n.t("menu.view.plan", "Plan"),
                group: .view,
                shortcut: KaidoShortcut(key: "1", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.plan.alias", "Task view")],
                action: { store.dispatch(.setMode(.plan)) }
            ),
            KaidoCommand(
                id: "view.outline",
                title: I18n.t("menu.view.outline", "Outline"),
                group: .view,
                shortcut: KaidoShortcut(key: "2", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.outline.alias", "Gantt view")],
                action: { store.dispatch(.setMode(.outline)) }
            ),
            KaidoCommand(
                id: "view.focus",
                title: I18n.t("menu.view.chart_focus", "Focus Chart"),
                group: .view,
                shortcut: KaidoShortcut(key: "l", modifiers: [.command, .option]),
                action: { store.dispatch(.toggleChartFocus) }
            ),
            KaidoCommand(
                id: "view.violations",
                title: I18n.t("menu.view.violations", "Show Inspector · Violations"),
                group: .view,
                shortcut: KaidoShortcut(key: "v", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.violations.alias", "Show/hide the violations panel")],
                action: {
                    store.dispatch(.setInspectorVisible(true))
                    store.dispatch(.setInspectorTab(.violations))
                }
            ),
            KaidoCommand(
                id: "view.today",
                title: I18n.t("menu.view.today", "Go to Today"),
                group: .view,
                shortcut: KaidoShortcut(key: "t", modifiers: [.command, .option]),
                action: { store.dispatch(.goToToday) }
            ),
            KaidoCommand(
                id: "view.nonWorkingDays",
                title: I18n.t("menu.view.non_working_days", "Show/Hide Non-Working Days"),
                group: .view,
                action: { store.dispatch(.toggleNonWorkingDays) }
            ),
            // 基线入口（v0.13.3 → v0.14）：工具栏那颗棋盘旗在窄窗口会被系统收进溢出菜单，
            // 单独设一个顶级「基线」菜单后，新建入口恒为该项第 1 条（D-035）。
            KaidoCommand(
                id: BaselineMenuID.create,
                title: I18n.t("menu.baseline.create", "New Baseline"),
                group: .baseline,
                shortcut: KaidoShortcut(key: "b", modifiers: [.command, .option]),
                action: { store.dispatch(.createBaseline(nil)) }
            ),
            KaidoCommand(
                id: BaselineMenuID.compareClear,
                title: I18n.t("menu.baseline.none", "Stop Comparing Baseline"),
                group: .baseline,
                action: { store.dispatch(.setBaseline(nil)) }
            ),
            // 面板入口（v0.15）：逐条基线的完整管理（条目数 / 孤儿 / 基线后新增）。
            // 静态命令：⌘K 里必须找得到（D-035），但不给快捷键——这是低频的管理动作。
            KaidoCommand(
                id: BaselineMenuID.manage,
                title: I18n.t("menu.baseline.manage", "Manage Baselines…"),
                group: .baseline,
                aliases: [I18n.t("menu.baseline.manage.alias", "Open the baselines panel")],
                action: { store.presentBaselinePanel() }
            ),
            // v0.15.1：CSV 导出此前只在 CLI 有入口，界面里找不到（用户实测）。
            KaidoCommand(
                id: BaselineMenuID.exportCSV,
                title: I18n.t("menu.baseline.export_csv", "Export Variance CSV…"),
                group: .baseline,
                aliases: [I18n.t("menu.baseline.export_csv.alias", "Save baseline variance as a spreadsheet")],
                action: { store.presentVarianceCSVExport() }
            ),
            KaidoCommand(
                id: "view.criticalPath",
                title: I18n.t("menu.view.critical_path", "Show/Hide Critical Path"),
                group: .view,
                action: { store.dispatch(.toggleCriticalPath) }
            ),
            KaidoCommand(
                id: "view.filterBar",
                title: I18n.t("menu.view.filter_bar", "Show Filter Bar"),
                group: .view,
                action: { store.filterBarVisible = true }
            ),
            KaidoCommand(
                id: "view.dayWidthWider",
                title: I18n.t("menu.view.day_width_wider", "Wider Days"),
                group: .view,
                shortcut: KaidoShortcut(key: "+", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_wider.alias_a", "Increase day width"), I18n.t("menu.view.day_width_wider.alias_b", "Zoom day width in")],
                action: { store.dispatch(.nudgeCustomDayWidth(by: GanttScale.dayWidthStep)) }
            ),
            KaidoCommand(
                id: "view.dayWidthNarrower",
                title: I18n.t("menu.view.day_width_narrower", "Narrower Days"),
                group: .view,
                shortcut: KaidoShortcut(key: "-", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_narrower.alias_a", "Decrease day width"), I18n.t("menu.view.day_width_narrower.alias_b", "Zoom day width out")],
                action: { store.dispatch(.nudgeCustomDayWidth(by: -GanttScale.dayWidthStep)) }
            ),
            KaidoCommand(
                id: "view.dayWidthReset",
                title: I18n.t("menu.view.day_width_reset", "Reset Day Width"),
                group: .view,
                shortcut: KaidoShortcut(key: "0", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_reset.alias", "Reset day width")],
                action: { store.dispatch(.clearCustomDayWidth) }
            ),
            KaidoCommand(
                id: "find.show",
                title: I18n.t("menu.find.show", "Find…"),
                group: .find,
                shortcut: KaidoShortcut(key: "f", modifiers: .command),
                action: {
                    store.filterBarVisible = true
                    store.showFindBar = true
                    store.findFocusToken += 1
                }
            ),
            KaidoCommand(
                id: "find.next",
                title: I18n.t("menu.find.next", "Find Next"),
                group: .find,
                shortcut: KaidoShortcut(key: "g", modifiers: .command),
                action: { store.find.findNext() }
            ),
            KaidoCommand(
                id: "find.previous",
                title: I18n.t("menu.find.previous", "Find Previous"),
                group: .find,
                shortcut: KaidoShortcut(key: "g", modifiers: [.command, .shift]),
                action: { store.find.findPrevious() }
            ),
            KaidoCommand(
                id: "find.regex",
                title: I18n.t("menu.find.regex", "Toggle Regex Mode"),
                group: .find,
                shortcut: KaidoShortcut(key: "e", modifiers: [.command, .option]),
                action: { store.find.regexMode.toggle() }
            ),
            KaidoCommand(
                id: "palette.show",
                title: I18n.t("menu.find.command_palette", "Command Palette"),
                group: .find,
                shortcut: KaidoShortcut(key: "k", modifiers: .command),
                action: { store.showCommandPalette = true }
            )
        ] + recentCommands(store: store) + baselineCommands(store: store) + OutlineColumnPreferences.toggleable.map { column in
            // 大纲列显隐（F-14-20 / F-0719）：与表头右键菜单同源动作；
            // 序号/任务说明固定显示，故由 `toggleable`（可隐藏列 + 可选列）派生，
            // 不手写条目以免两处漂移。
            KaidoCommand(
                id: "view.outlineColumn.\(column.rawValue)",
                title: I18n.t("menu.view.outline_column", "Show/Hide %1$@ Column", Display.outlineColumnTitle(column)),
                group: .view,
                action: { store.dispatch(.toggleOutlineColumn(column)) }
            )
        }
    }

    /// 逐条基线的命令（v0.14 §5）：显示 / 对比 / 8 色 / 改名 / 删除，每条基线 12 条。
    ///
    /// id 用基线 UUID 而不是数组下标：删掉中间一条后下标会漂移，命令就可能指到别人的
    /// 基线上；UUID 让「哪条命令动哪条基线」在菜单重建前后一致。
    /// 颜色项标 isPaletteHidden——8 色 × N 条进 ⌘K 会把面板挤成色卡（§5）。
    private static func baselineCommands(store: WorkspaceStore) -> [KaidoCommand] {
        store.baselines.flatMap { baseline -> [KaidoCommand] in
            var items: [KaidoCommand] = [
                KaidoCommand(
                    id: BaselineMenuID.visibility(baseline.id),
                    title: I18n.t("menu.baseline.show_in_gantt", "Show in Gantt"),
                    group: .baseline,
                    // 菜单里父级子菜单已经是基线名，面板里没有上下文，故把名称放进别名可搜。
                    aliases: [
                        baseline.name,
                        I18n.t("menu.baseline.show_named", "Show %1$@", baseline.name),
                        I18n.t("menu.baseline.hide_named", "Hide %1$@", baseline.name),
                    ],
                    action: {
                        // 目标状态在执行时读：菜单可能在状态变化之前就建好了。
                        let isVisible = BaselineMenuModel(
                            baselines: store.baselines,
                            viewState: store.viewState
                        ).items.first { $0.id == baseline.id }?.isVisibleInGantt ?? false
                        store.dispatch(.setBaselineVisible(baseline.id, !isVisible))
                    }
                ),
                KaidoCommand(
                    id: BaselineMenuID.compare(baseline.id),
                    title: I18n.t("menu.baseline.set_compared", "Compare Against This Baseline"),
                    group: .baseline,
                    aliases: [
                        baseline.name,
                        I18n.t("menu.baseline.compare_named", "Compare with %1$@", baseline.name),
                    ],
                    action: { store.dispatch(.setBaseline(baseline.id)) }
                ),
            ]
            items += (0 ..< BaselineColorNames.count).map { colorIndex in
                KaidoCommand(
                    id: BaselineMenuID.color(baseline.id, colorIndex),
                    title: BaselineColorNames.title(colorIndex),
                    group: .baseline,
                    isPaletteHidden: true,
                    action: { store.dispatch(.setBaselineColor(baseline.id, colorIndex)) }
                )
            }
            items.append(KaidoCommand(
                id: BaselineMenuID.rename(baseline.id),
                title: I18n.t("menu.baseline.rename", "Rename Baseline…"),
                group: .baseline,
                action: {
                    BaselineRenamePrompt.present(currentName: baseline.name) { name in
                        store.dispatch(.renameBaseline(baseline.id, name))
                    }
                }
            ))
            items.append(KaidoCommand(
                id: BaselineMenuID.delete(baseline.id),
                title: I18n.t("menu.baseline.delete", "Delete Baseline…"),
                group: .baseline,
                isDestructive: true,
                // 沿用既有二次确认：只登记待删，确认对话框在 WorkspaceView。
                action: { store.dispatch(.deleteBaseline(baseline.id)) }
            ))
            return items
        }
    }

    /// 「最近打开」命令：每条最近文件一条（菜单子项与 ⌘K 面板同源），列表非空时再给一条清除。
    ///
    /// id 用序号而不是路径：路径可能含空格、斜杠与变音符，当 SwiftUI 标识或菜单键都不稳；
    /// 顺序即列表顺序，action 已捕获 URL。
    private static func recentCommands(store: WorkspaceStore) -> [KaidoCommand] {
        let urls = store.recentProjects
        let names = RecentProjects.displayNames(for: urls)
        let items = zip(urls, names).enumerated().map { index, pair in
            KaidoCommand(
                id: "file.openRecent.item.\(index)",
                title: pair.1,
                group: .file,
                aliases: [I18n.t("menu.file.open_recent", "Open Recent"), pair.0.path],
                action: { store.openRecentProject(pair.0) }
            )
        }
        guard !items.isEmpty else { return [] }
        return items + [
            KaidoCommand(
                id: "file.openRecent.clear",
                title: I18n.t("menu.file.open_recent.clear", "Clear Menu"),
                group: .file,
                aliases: [I18n.t("menu.file.open_recent.clear.alias", "Clear recent projects")],
                action: { store.clearRecentProjects() }
            )
        ]
    }
}

extension View {
    /// 只有需要说明时才挂 tooltip：空字符串会挂出一个空气泡。
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text, !text.isEmpty {
            help(text)
        } else {
            self
        }
    }
}

/// 由注册表生成菜单栏（US-E4-05 验收 3：菜单命令与面板同源）。
struct KaidoMenuCommands: Commands {
    let commands: [KaidoCommand]
    /// 语言偏好的可观察镜像：写偏好不会触发 SwiftUI 重算，勾选态需要它才会立刻更新。
    @AppStorage(AppLanguage.defaultsKey) private var languageRaw = AppLanguage.system.rawValue
    /// 工作台状态：顶级「基线」菜单要按当前基线渲染子菜单与图例。
    ///
    /// 与 `commands` 同源：菜单只排布，动作与文案仍由注册表提供。
    let store: WorkspaceStore
    /// 「检查更新…」入口（OTA；nil = 不挂菜单，供测试省略）。
    var checkForUpdates: (() -> Void)? = nil

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(I18n.t("menu.app.about", "About Kaido")) { Self.showAboutPanel() }
            if let checkForUpdates {
                Button(I18n.t("menu.app.check_for_updates", "Check for Updates…")) { checkForUpdates() }
            }
            Divider()
            languageMenu
        }
        CommandGroup(replacing: .saveItem) {
            Divider()
            items(group: .file)
        }
        // 撤销/重做必须经过会话快照；替换系统 NSResponder 撤销入口。
        CommandGroup(replacing: .undoRedo) {
            items(group: .edit)
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(group: .outline)
        }
        CommandMenu(KaidoCommandGroup.task.title) {
            items(group: .task)
        }
        CommandMenu(KaidoCommandGroup.view.title) {
            items(group: .view)
        }
        // 「项目」独立成顶级菜单：设置作用于整个项目，混在「任务」里语义不对。
        CommandMenu(KaidoCommandGroup.project.title) {
            items(group: .project)
        }
        // 「基线」独立成顶级菜单（v0.14 §5）：创建入口不再只靠工具栏溢出菜单（D-035）。
        CommandMenu(KaidoCommandGroup.baseline.title) {
            BaselineMenuContent(store: store, commands: commands)
        }
        CommandMenu(KaidoCommandGroup.find.title) {
            items(group: .find)
        }
    }

    // MARK: - 界面语言（F-0706）

    /// 三档语言：跟随系统 / 简体中文 / English；写入偏好后重启生效。
    ///
    /// 不做运行中热切换：菜单栏常驻应用的视图重建路径分散（主窗口、面板、弹窗、菜单），
    /// 需要为全链路注入 locale 并强制重建（设计 §5，P2 未验证）。
    /// 用 `@AppStorage` 观察同一偏好键：选完立刻刷新勾选态，并弹出「已保存，重启生效」提示。
    /// 之前只写 UserDefaults 不触发 SwiftUI 重算，菜单关掉就再无任何反馈（用户以为没生效）。
    @ViewBuilder
    private var languageMenu: some View {
        Menu(I18n.t("menu.language.title", "Language")) {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Button {
                    AppLanguage.selected = language
                    Self.confirmLanguageChange(language)
                } label: {
                    Text(selectedLanguage == language ? "✓ \(language.displayName)" : language.displayName)
                }
            }
            Divider()
            Text(I18n.t("menu.language.restart_hint", "Takes effect after restarting Kaido"))
        }
    }

    /// 当前选择：读偏好键对应字段（`@AppStorage` 变化会触发菜单重建）。
    private var selectedLanguage: AppLanguage {
        AppLanguage(rawValue: languageRaw) ?? .system
    }

    /// 选完语言给一次明确反馈：菜单关闭后不再有任何可见变化，用户会以为「没反应」。
    static func confirmLanguageChange(_ language: AppLanguage) {
        let alert = NSAlert()
        alert.messageText = I18n.t(
            "alert.language.changed.title",
            "Language saved: %1$@",
            language.displayName
        )
        alert.informativeText = I18n.t(
            "alert.language.changed.message",
            "Quit and reopen Kaido to apply it — the window title bar, menus and system dialogs switch together."
        )
        alert.alertStyle = .informational
        alert.addButton(withTitle: I18n.t("action.ok", "OK"))
        alert.runModal()
    }

    @ViewBuilder
    private func items(group: KaidoCommandGroup) -> some View {
        if group == .file {
            ForEach(commands.filter { $0.group == .file && !Self.isRecent($0) }) { command in
                commandButton(command)
                // macOS 惯例：「最近打开」紧跟「打开…」。
                if command.id == "file.open" {
                    openRecentMenu
                }
            }
        } else {
            ForEach(commands.filter { $0.group == group }) { commandButton($0) }
        }
    }

    /// 该命令是否承载「最近打开」（菜单子项 + ⌘K 面板条目），这类项不直接平铺到文件菜单。
    private static func isRecent(_ command: KaidoCommand) -> Bool {
        command.id.hasPrefix("file.openRecent.")
    }

    /// 「最近打开」子菜单：项从注册表取，菜单与 ⌘K 面板因此只有一个来源。
    @ViewBuilder
    private var openRecentMenu: some View {
        let recents = commands.filter { $0.id.hasPrefix("file.openRecent.item.") }
        let clear = commands.first { $0.id == "file.openRecent.clear" }
        Menu(I18n.t("menu.file.open_recent", "Open Recent")) {
            if recents.isEmpty {
                Button(I18n.t("menu.file.open_recent.empty", "No Recent Projects")) {}
                    .disabled(true)
            } else {
                ForEach(recents) { commandButton($0) }
                if let clear {
                    Divider()
                    commandButton(clear)
                }
            }
        }
    }

    @ViewBuilder
    private func commandButton(_ command: KaidoCommand) -> some View {
        if let shortcut = command.shortcut {
            Button(command.title) { command.action() }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
                .disabled(!command.isEnabled)
                .helpIfPresent(command.disabledHint)
        } else {
            Button(command.title) { command.action() }
                .disabled(!command.isEnabled)
                .helpIfPresent(command.disabledHint)
        }
    }

    // MARK: - 关于面板

    /// 应用版本号：发版前更新。
    static let appVersion = "2.1.0"

    /// 版权与联系邮箱：法律声明，不随界面语言变化，也不进 String Catalog。
    static let copyrightNotice = "Copyright (c) 2026 cygnusyang <ruohuyang@gmail.com>"

    /// 「关于 Kaido」面板：版本号 + 编译时间 + 版权。
    /// 打包应用读 Info.plist 的 CFBundleVersion（构建时写入的时间戳）；
    /// 开发态（swift run）取可执行文件的修改时间作为编译时间。
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kaido",
            .applicationVersion: appVersion,
            .credits: NSAttributedString(
                // 首行是构建时间（随语言）；次行是版权与联系邮箱，法律声明不参与翻译。
                string: I18n.t("menu.app.about.built_at", "Built %1$@", buildDescription)
                    + "\n" + Self.copyrightNotice,
                attributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor]
            ),
        ])
    }

    private static var buildDescription: String {
        if let stamp = Bundle.main.infoDictionary?["CFBundleVersion"] as? String,
           let parsed = Self.parseBuildStamp(stamp) {
            return parsed
        }
        // 开发态无打包 Info.plist：可执行文件修改时间即编译时间。
        if let url = Bundle.main.executableURL,
           let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
           let modified = attributes[.modificationDate] as? Date {
            return Self.formatBuildTime(modified)
        }
        return I18n.t("menu.app.about.unknown_time", "Unknown time")
    }

    /// 解析打包时写入的 `yyyyMMdd.HHmm` 时间戳。
    private static func parseBuildStamp(_ stamp: String) -> String? {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd.HHmm"
        guard let date = formatter.date(from: stamp) else { return nil }
        return formatBuildTime(date)
    }

    private static func formatBuildTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }
}

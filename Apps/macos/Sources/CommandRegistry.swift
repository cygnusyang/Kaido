import AppKit
import SwiftUI
import KairoCore
import KairoPresentation

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
struct KairoShortcut {
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
enum KairoCommandGroup: String, CaseIterable, Hashable, Sendable {
    case file, edit, outline, task, view, find

    /// 菜单标题 / 面板分组标签。
    var title: String {
        switch self {
        case .file: return I18n.t("menu.group.file", "File")
        case .edit: return I18n.t("menu.group.edit", "Edit")
        case .outline: return I18n.t("menu.group.outline", "Outline")
        case .task: return I18n.t("menu.group.task", "Task")
        case .view: return I18n.t("menu.group.view", "Workspace")
        case .find: return I18n.t("menu.group.find", "Find")
        }
    }
}

/// 一条可执行命令（US-E4-05 / F-41-01）。菜单栏与 ⌘K 面板均消费此注册表。
struct KairoCommand: Identifiable {
    let id: String
    let title: String
    /// 菜单分组（文件 / 编辑 / 大纲 / 任务 / 视图 / 查找）。
    let group: KairoCommandGroup
    let shortcut: KairoShortcut?
    /// 旧标题，仅用于命令面板搜索（不显示在菜单）。
    let aliases: [String]
    let action: @MainActor () -> Void

    init(
        id: String,
        title: String,
        group: KairoCommandGroup,
        shortcut: KairoShortcut? = nil,
        aliases: [String] = [],
        action: @escaping @MainActor () -> Void
    ) {
        self.id = id
        self.title = title
        self.group = group
        self.shortcut = shortcut
        self.aliases = aliases
        self.action = action
    }
}

/// 命令注册表：应用内唯一的命令定义来源（US-E4-05 验收 3）。
@MainActor
enum KairoCommandCatalog {
    static func make(
        store: WorkspaceStore,
        requestOpen: @escaping @MainActor () -> Void,
        requestSave: @escaping @MainActor () -> Void,
        requestSaveAs: @escaping @MainActor () -> Void
    ) -> [KairoCommand] {
        [
            KairoCommand(
                id: "file.open",
                title: I18n.t("menu.file.open_project", "Open Project…"),
                group: .file,
                shortcut: KairoShortcut(key: "o", modifiers: .command),
                action: requestOpen
            ),
            KairoCommand(
                id: "file.save",
                title: I18n.t("menu.file.save", "Save"),
                group: .file,
                shortcut: KairoShortcut(key: "s", modifiers: .command),
                action: requestSave
            ),
            KairoCommand(
                id: "file.saveAs",
                title: I18n.t("menu.file.save_as", "Save As…"),
                group: .file,
                shortcut: KairoShortcut(key: "s", modifiers: [.command, .shift]),
                aliases: [I18n.t("menu.file.save_as.alias", "Save a copy")],
                action: requestSaveAs
            ),
            KairoCommand(
                id: "file.loadExample",
                title: I18n.t("menu.file.load_example", "Load Example Project"),
                group: .file,
                aliases: [I18n.t("menu.file.load_example.alias_demo", "Load demo data"), I18n.t("menu.file.load_example.alias_example", "Example project")],
                action: { store.loadExampleProject() }
            ),
            KairoCommand(
                id: "edit.undo",
                title: I18n.t("menu.edit.undo", "Undo"),
                group: .edit,
                shortcut: KairoShortcut(key: "z", modifiers: .command),
                action: {
                    if !FieldEditorUndo.perform(redo: false) {
                        store.dispatch(.undo)
                    }
                }
            ),
            KairoCommand(
                id: "edit.redo",
                title: I18n.t("menu.edit.redo", "Redo"),
                group: .edit,
                shortcut: KairoShortcut(key: "z", modifiers: [.command, .shift]),
                action: {
                    if !FieldEditorUndo.perform(redo: true) {
                        store.dispatch(.redo)
                    }
                }
            ),
            KairoCommand(
                id: "outline.indent",
                title: I18n.t("action.indent", "Indent"),
                group: .outline,
                shortcut: KairoShortcut(key: "]", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.indent(id))
                }
            ),
            KairoCommand(
                id: "outline.outdent",
                title: I18n.t("action.outdent", "Outdent"),
                group: .outline,
                shortcut: KairoShortcut(key: "[", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.outdent(id))
                }
            ),
            KairoCommand(
                id: "outline.newSibling",
                title: I18n.t("action.new_sibling", "New Sibling Task"),
                group: .outline,
                shortcut: KairoShortcut(key: .return, modifiers: .command),
                action: {
                    if let id = store.selection {
                        store.dispatch(.createSibling(after: id))
                    } else {
                        store.dispatch(.createTask(parentID: nil, kind: .task))
                    }
                }
            ),
            KairoCommand(
                id: "task.new",
                title: I18n.t("action.new_task", "New Task"),
                group: .task,
                shortcut: KairoShortcut(key: "n", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .task)) }
            ),
            KairoCommand(
                id: "task.newGroup",
                title: I18n.t("action.new_group", "New Group"),
                group: .task,
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .group)) }
            ),
            KairoCommand(
                id: "task.newMilestone",
                title: I18n.t("action.new_milestone", "New Milestone"),
                group: .task,
                shortcut: KairoShortcut(key: "m", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .milestone)) }
            ),
            KairoCommand(
                id: "view.plan",
                title: I18n.t("menu.view.plan", "Plan"),
                group: .view,
                shortcut: KairoShortcut(key: "1", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.plan.alias", "Task view")],
                action: { store.dispatch(.setMode(.plan)) }
            ),
            KairoCommand(
                id: "view.outline",
                title: I18n.t("menu.view.outline", "Outline"),
                group: .view,
                shortcut: KairoShortcut(key: "2", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.outline.alias", "Gantt view")],
                action: { store.dispatch(.setMode(.outline)) }
            ),
            KairoCommand(
                id: "view.focus",
                title: I18n.t("menu.view.chart_focus", "Focus Chart"),
                group: .view,
                shortcut: KairoShortcut(key: "l", modifiers: [.command, .option]),
                action: { store.dispatch(.toggleChartFocus) }
            ),
            KairoCommand(
                id: "view.violations",
                title: I18n.t("menu.view.violations", "Show Inspector · Violations"),
                group: .view,
                shortcut: KairoShortcut(key: "v", modifiers: [.command, .option]),
                aliases: [I18n.t("menu.view.violations.alias", "Show/hide the violations panel")],
                action: {
                    store.dispatch(.setInspectorVisible(true))
                    store.dispatch(.setInspectorTab(.violations))
                }
            ),
            KairoCommand(
                id: "view.today",
                title: I18n.t("menu.view.today", "Go to Today"),
                group: .view,
                shortcut: KairoShortcut(key: "t", modifiers: [.command, .option]),
                action: { store.dispatch(.goToToday) }
            ),
            KairoCommand(
                id: "view.nonWorkingDays",
                title: I18n.t("menu.view.non_working_days", "Show/Hide Non-Working Days"),
                group: .view,
                action: { store.dispatch(.toggleNonWorkingDays) }
            ),
            KairoCommand(
                id: "view.criticalPath",
                title: I18n.t("menu.view.critical_path", "Show/Hide Critical Path"),
                group: .view,
                action: { store.dispatch(.toggleCriticalPath) }
            ),
            KairoCommand(
                id: "view.filterBar",
                title: I18n.t("menu.view.filter_bar", "Show Filter Bar"),
                group: .view,
                action: { store.filterBarVisible = true }
            ),
            KairoCommand(
                id: "view.dayWidthWider",
                title: I18n.t("menu.view.day_width_wider", "Wider Days"),
                group: .view,
                shortcut: KairoShortcut(key: "+", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_wider.alias_a", "Increase day width"), I18n.t("menu.view.day_width_wider.alias_b", "Zoom day width in")],
                action: { store.dispatch(.nudgeCustomDayWidth(by: GanttScale.dayWidthStep)) }
            ),
            KairoCommand(
                id: "view.dayWidthNarrower",
                title: I18n.t("menu.view.day_width_narrower", "Narrower Days"),
                group: .view,
                shortcut: KairoShortcut(key: "-", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_narrower.alias_a", "Decrease day width"), I18n.t("menu.view.day_width_narrower.alias_b", "Zoom day width out")],
                action: { store.dispatch(.nudgeCustomDayWidth(by: -GanttScale.dayWidthStep)) }
            ),
            KairoCommand(
                id: "view.dayWidthReset",
                title: I18n.t("menu.view.day_width_reset", "Reset Day Width"),
                group: .view,
                shortcut: KairoShortcut(key: "0", modifiers: .command),
                aliases: [I18n.t("menu.view.day_width_reset.alias", "Reset day width")],
                action: { store.dispatch(.clearCustomDayWidth) }
            ),
            KairoCommand(
                id: "find.show",
                title: I18n.t("menu.find.show", "Find…"),
                group: .find,
                shortcut: KairoShortcut(key: "f", modifiers: .command),
                action: {
                    store.filterBarVisible = true
                    store.showFindBar = true
                    store.findFocusToken += 1
                }
            ),
            KairoCommand(
                id: "find.next",
                title: I18n.t("menu.find.next", "Find Next"),
                group: .find,
                shortcut: KairoShortcut(key: "g", modifiers: .command),
                action: { store.find.findNext() }
            ),
            KairoCommand(
                id: "find.previous",
                title: I18n.t("menu.find.previous", "Find Previous"),
                group: .find,
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .shift]),
                action: { store.find.findPrevious() }
            ),
            KairoCommand(
                id: "find.regex",
                title: I18n.t("menu.find.regex", "Toggle Regex Mode"),
                group: .find,
                shortcut: KairoShortcut(key: "e", modifiers: [.command, .option]),
                action: { store.find.regexMode.toggle() }
            ),
            KairoCommand(
                id: "palette.show",
                title: I18n.t("menu.find.command_palette", "Command Palette"),
                group: .find,
                shortcut: KairoShortcut(key: "k", modifiers: .command),
                action: { store.showCommandPalette = true }
            )
        ] + recentCommands(store: store) + OutlineColumnPreferences.toggleable.map { column in
            // 大纲列显隐（F-14-20 / F-0719）：与表头右键菜单同源动作；
            // 序号/任务说明固定显示，故由 `toggleable`（可隐藏列 + 可选列）派生，
            // 不手写条目以免两处漂移。
            KairoCommand(
                id: "view.outlineColumn.\(column.rawValue)",
                title: I18n.t("menu.view.outline_column", "Show/Hide %1$@ Column", Display.outlineColumnTitle(column)),
                group: .view,
                action: { store.dispatch(.toggleOutlineColumn(column)) }
            )
        }
    }

    /// 「最近打开」命令：每条最近文件一条（菜单子项与 ⌘K 面板同源），列表非空时再给一条清除。
    ///
    /// id 用序号而不是路径：路径可能含空格、斜杠与变音符，当 SwiftUI 标识或菜单键都不稳；
    /// 顺序即列表顺序，action 已捕获 URL。
    private static func recentCommands(store: WorkspaceStore) -> [KairoCommand] {
        let urls = store.recentProjects
        let names = RecentProjects.displayNames(for: urls)
        let items = zip(urls, names).enumerated().map { index, pair in
            KairoCommand(
                id: "file.openRecent.item.\(index)",
                title: pair.1,
                group: .file,
                aliases: [I18n.t("menu.file.open_recent", "Open Recent"), pair.0.path],
                action: { store.openRecentProject(pair.0) }
            )
        }
        guard !items.isEmpty else { return [] }
        return items + [
            KairoCommand(
                id: "file.openRecent.clear",
                title: I18n.t("menu.file.open_recent.clear", "Clear Menu"),
                group: .file,
                aliases: [I18n.t("menu.file.open_recent.clear.alias", "Clear recent projects")],
                action: { store.clearRecentProjects() }
            )
        ]
    }
}

/// 由注册表生成菜单栏（US-E4-05 验收 3：菜单命令与面板同源）。
struct KairoMenuCommands: Commands {
    let commands: [KairoCommand]
    /// 「检查更新…」入口（OTA；nil = 不挂菜单，供测试省略）。
    var checkForUpdates: (() -> Void)? = nil

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(I18n.t("menu.app.about", "About Kairo")) { Self.showAboutPanel() }
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
        CommandMenu(KairoCommandGroup.task.title) {
            items(group: .task)
        }
        CommandMenu(KairoCommandGroup.view.title) {
            items(group: .view)
        }
        CommandMenu(KairoCommandGroup.find.title) {
            items(group: .find)
        }
    }

    // MARK: - 界面语言（F-0706）

    /// 三档语言：跟随系统 / 简体中文 / English；写入偏好后重启生效。
    ///
    /// 不做运行中热切换：菜单栏常驻应用的视图重建路径分散（主窗口、面板、弹窗、菜单），
    /// 需要为全链路注入 locale 并强制重建（设计 §5，P2 未验证）。
    @ViewBuilder
    private var languageMenu: some View {
        let selected = AppLanguage.selected
        Menu(I18n.t("menu.language.title", "Language")) {
            ForEach(AppLanguage.allCases, id: \.self) { language in
                Button {
                    AppLanguage.selected = language
                } label: {
                    Text(selected == language ? "✓ \(language.displayName)" : language.displayName)
                }
            }
            Divider()
            Text(I18n.t("menu.language.restart_hint", "Takes effect after restarting Kairo"))
        }
    }

    @ViewBuilder
    private func items(group: KairoCommandGroup) -> some View {
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
    private static func isRecent(_ command: KairoCommand) -> Bool {
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
    private func commandButton(_ command: KairoCommand) -> some View {
        if let shortcut = command.shortcut {
            Button(command.title) { command.action() }
                .keyboardShortcut(shortcut.key, modifiers: shortcut.modifiers)
        } else {
            Button(command.title) { command.action() }
        }
    }

    // MARK: - 关于面板

    /// 应用版本号：发版前更新。
    static let appVersion = "0.13.1"

    /// 版权与联系邮箱：法律声明，不随界面语言变化，也不进 String Catalog。
    static let copyrightNotice = "Copyright (c) 2026 cygnusyang <ruohuyang@gmail.com>"

    /// 「关于 Kairo」面板：版本号 + 编译时间 + 版权。
    /// 打包应用读 Info.plist 的 CFBundleVersion（构建时写入的时间戳）；
    /// 开发态（swift run）取可执行文件的修改时间作为编译时间。
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kairo",
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

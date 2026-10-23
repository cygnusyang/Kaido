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

/// 一条可执行命令（US-E4-05 / F-41-01）。菜单栏与 ⌘K 面板均消费此注册表。
struct KairoCommand: Identifiable {
    let id: String
    let title: String
    /// 菜单分组：文件 / 大纲 / 任务 / 视图 / 查找。
    let group: String
    let shortcut: KairoShortcut?
    /// 旧标题，仅用于命令面板搜索（不显示在菜单）。
    let aliases: [String]
    let action: @MainActor () -> Void

    init(
        id: String,
        title: String,
        group: String,
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
                title: "打开项目…",
                group: "文件",
                shortcut: KairoShortcut(key: "o", modifiers: .command),
                action: requestOpen
            ),
            KairoCommand(
                id: "file.save",
                title: "保存",
                group: "文件",
                shortcut: KairoShortcut(key: "s", modifiers: .command),
                action: requestSave
            ),
            KairoCommand(
                id: "file.saveAs",
                title: "另存为…",
                group: "文件",
                shortcut: KairoShortcut(key: "s", modifiers: [.command, .shift]),
                aliases: ["保存副本"],
                action: requestSaveAs
            ),
            KairoCommand(
                id: "file.loadExample",
                title: "载入示例项目",
                group: "文件",
                aliases: ["载入演示数据", "示例项目"],
                action: { store.loadExampleProject() }
            ),
            KairoCommand(
                id: "edit.undo",
                title: "撤销",
                group: "编辑",
                shortcut: KairoShortcut(key: "z", modifiers: .command),
                action: {
                    if !FieldEditorUndo.perform(redo: false) {
                        store.dispatch(.undo)
                    }
                }
            ),
            KairoCommand(
                id: "edit.redo",
                title: "重做",
                group: "编辑",
                shortcut: KairoShortcut(key: "z", modifiers: [.command, .shift]),
                action: {
                    if !FieldEditorUndo.perform(redo: true) {
                        store.dispatch(.redo)
                    }
                }
            ),
            KairoCommand(
                id: "outline.indent",
                title: "缩进",
                group: "大纲",
                shortcut: KairoShortcut(key: "]", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.indent(id))
                }
            ),
            KairoCommand(
                id: "outline.outdent",
                title: "减少缩进",
                group: "大纲",
                shortcut: KairoShortcut(key: "[", modifiers: .command),
                action: {
                    guard let id = store.selection else { return }
                    store.dispatch(.outdent(id))
                }
            ),
            KairoCommand(
                id: "outline.newSibling",
                title: "新建同级任务",
                group: "大纲",
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
                title: "新建任务",
                group: "任务",
                shortcut: KairoShortcut(key: "n", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .task)) }
            ),
            KairoCommand(
                id: "task.newGroup",
                title: "新建群组",
                group: "任务",
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .group)) }
            ),
            KairoCommand(
                id: "task.newMilestone",
                title: "新建里程碑",
                group: "任务",
                shortcut: KairoShortcut(key: "m", modifiers: [.command, .option]),
                action: { store.dispatch(.createTask(parentID: nil, kind: .milestone)) }
            ),
            KairoCommand(
                id: "view.plan",
                title: "计划",
                group: "视图",
                shortcut: KairoShortcut(key: "1", modifiers: [.command, .option]),
                aliases: ["任务视图"],
                action: { store.dispatch(.setMode(.plan)) }
            ),
            KairoCommand(
                id: "view.outline",
                title: "大纲",
                group: "视图",
                shortcut: KairoShortcut(key: "2", modifiers: [.command, .option]),
                aliases: ["甘特视图"],
                action: { store.dispatch(.setMode(.outline)) }
            ),
            KairoCommand(
                id: "view.focus",
                title: "图表聚焦",
                group: "视图",
                shortcut: KairoShortcut(key: "l", modifiers: [.command, .option]),
                action: { store.dispatch(.toggleChartFocus) }
            ),
            KairoCommand(
                id: "view.violations",
                title: "显示检查器·违例",
                group: "视图",
                shortcut: KairoShortcut(key: "v", modifiers: [.command, .option]),
                aliases: ["显示/隐藏违例面板"],
                action: {
                    store.dispatch(.setInspectorVisible(true))
                    store.dispatch(.setInspectorTab(.violations))
                }
            ),
            KairoCommand(
                id: "view.today",
                title: "回到今天",
                group: "视图",
                shortcut: KairoShortcut(key: "t", modifiers: [.command, .option]),
                action: { store.dispatch(.goToToday) }
            ),
            KairoCommand(
                id: "view.criticalPath",
                title: "显示/隐藏重要路径",
                group: "视图",
                action: { store.dispatch(.toggleCriticalPath) }
            ),
            KairoCommand(
                id: "view.filterBar",
                title: "显示筛选栏",
                group: "视图",
                action: { store.filterBarVisible = true }
            ),
            KairoCommand(
                id: "view.dayWidthWider",
                title: "加宽每日",
                group: "视图",
                shortcut: KairoShortcut(key: "+", modifiers: .command),
                aliases: ["日宽加宽", "放大日宽"],
                action: { store.dispatch(.nudgeCustomDayWidth(by: GanttScale.dayWidthStep)) }
            ),
            KairoCommand(
                id: "view.dayWidthNarrower",
                title: "收窄每日",
                group: "视图",
                shortcut: KairoShortcut(key: "-", modifiers: .command),
                aliases: ["日宽收窄", "缩小日宽"],
                action: { store.dispatch(.nudgeCustomDayWidth(by: -GanttScale.dayWidthStep)) }
            ),
            KairoCommand(
                id: "view.dayWidthReset",
                title: "重置每日宽度",
                group: "视图",
                shortcut: KairoShortcut(key: "0", modifiers: .command),
                aliases: ["日宽重置"],
                action: { store.dispatch(.clearCustomDayWidth) }
            ),
            KairoCommand(
                id: "find.show",
                title: "查找…",
                group: "查找",
                shortcut: KairoShortcut(key: "f", modifiers: .command),
                action: {
                    store.filterBarVisible = true
                    store.showFindBar = true
                    store.findFocusToken += 1
                }
            ),
            KairoCommand(
                id: "find.next",
                title: "查找下一个",
                group: "查找",
                shortcut: KairoShortcut(key: "g", modifiers: .command),
                action: { store.find.findNext() }
            ),
            KairoCommand(
                id: "find.previous",
                title: "查找上一个",
                group: "查找",
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .shift]),
                action: { store.find.findPrevious() }
            ),
            KairoCommand(
                id: "find.regex",
                title: "切换正则模式",
                group: "查找",
                shortcut: KairoShortcut(key: "e", modifiers: [.command, .option]),
                action: { store.find.regexMode.toggle() }
            ),
            KairoCommand(
                id: "palette.show",
                title: "命令面板",
                group: "查找",
                shortcut: KairoShortcut(key: "k", modifiers: .command),
                action: { store.showCommandPalette = true }
            )
        ] + OutlineColumnPreferences.configurable.map { column in
            // 大纲列显隐（F-14-20）：与表头右键菜单同源动作；
            // 序号/任务说明固定显示，故由 `configurable` 派生，不手写 8 条以免两处漂移。
            KairoCommand(
                id: "view.outlineColumn.\(column.rawValue)",
                title: "显示/隐藏\(Display.outlineColumnTitle(column))列",
                group: "视图",
                action: { store.dispatch(.toggleOutlineColumn(column)) }
            )
        }
    }
}

/// 由注册表生成菜单栏（US-E4-05 验收 3：菜单命令与面板同源）。
struct KairoMenuCommands: Commands {
    let commands: [KairoCommand]
    /// 「检查更新…」入口（OTA；nil = 不挂菜单，供测试省略）。
    var checkForUpdates: (() -> Void)? = nil

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button("关于 Kairo") { Self.showAboutPanel() }
            if let checkForUpdates {
                Button("检查更新…") { checkForUpdates() }
            }
        }
        CommandGroup(replacing: .saveItem) {
            Divider()
            items(group: "文件")
        }
        // 撤销/重做必须经过会话快照；替换系统 NSResponder 撤销入口。
        CommandGroup(replacing: .undoRedo) {
            items(group: "编辑")
        }
        CommandGroup(after: .pasteboard) {
            Divider()
            items(group: "大纲")
        }
        CommandMenu("任务") {
            items(group: "任务")
        }
        CommandMenu("视图") {
            items(group: "视图")
        }
        CommandMenu("查找") {
            items(group: "查找")
        }
    }

    @ViewBuilder
    private func items(group: String) -> some View {
        ForEach(commands.filter { $0.group == group }) { command in
            commandButton(command)
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
    static let appVersion = "0.8.1"

    /// 「关于 Kairo」面板：版本号 + 编译时间。
    /// 打包应用读 Info.plist 的 CFBundleVersion（构建时写入的时间戳）；
    /// 开发态（swift run）取可执行文件的修改时间作为编译时间。
    static func showAboutPanel() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Kairo",
            .applicationVersion: appVersion,
            .credits: NSAttributedString(
                string: "编译于 \(buildDescription)",
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
        return "未知时间"
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

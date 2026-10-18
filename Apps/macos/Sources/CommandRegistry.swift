import SwiftUI
import KairoCore

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
    let action: @MainActor () -> Void
}

/// 命令注册表：应用内唯一的命令定义来源（US-E4-05 验收 3）。
@MainActor
enum KairoCommandCatalog {
    static func make(
        store: ProjectStore,
        find: FindModel,
        requestOpen: @escaping @MainActor () -> Void,
        requestSave: @escaping @MainActor () -> Void
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
                id: "outline.indent",
                title: "缩进",
                group: "大纲",
                shortcut: KairoShortcut(key: "]", modifiers: .command),
                action: { store.indentSelected() }
            ),
            KairoCommand(
                id: "outline.outdent",
                title: "减少缩进",
                group: "大纲",
                shortcut: KairoShortcut(key: "[", modifiers: .command),
                action: { store.outdentSelected() }
            ),
            KairoCommand(
                id: "outline.newSibling",
                title: "新建同级任务",
                group: "大纲",
                shortcut: KairoShortcut(key: .return, modifiers: .command),
                action: { store.insertSiblingAfterSelection() }
            ),
            KairoCommand(
                id: "task.new",
                title: "新建任务",
                group: "任务",
                shortcut: KairoShortcut(key: "n", modifiers: [.command, .option]),
                action: { store.addTask(kind: .task) }
            ),
            KairoCommand(
                id: "task.newGroup",
                title: "新建群组",
                group: "任务",
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .option]),
                action: { store.addTask(kind: .group) }
            ),
            KairoCommand(
                id: "task.newMilestone",
                title: "新建里程碑",
                group: "任务",
                shortcut: KairoShortcut(key: "m", modifiers: [.command, .option]),
                action: { store.addTask(kind: .milestone) }
            ),
            KairoCommand(
                id: "view.outline",
                title: "任务视图",
                group: "视图",
                shortcut: nil,
                action: { store.viewMode = .outline }
            ),
            KairoCommand(
                id: "view.gantt",
                title: "甘特视图",
                group: "视图",
                shortcut: nil,
                action: { store.viewMode = .gantt }
            ),
            KairoCommand(
                id: "view.violations",
                title: "显示/隐藏违例面板",
                group: "视图",
                shortcut: KairoShortcut(key: "v", modifiers: [.command, .option]),
                action: { store.showViolations.toggle() }
            ),
            KairoCommand(
                id: "find.show",
                title: "查找…",
                group: "查找",
                shortcut: KairoShortcut(key: "f", modifiers: .command),
                action: {
                    store.showFindBar = true
                    store.findFocusToken += 1
                }
            ),
            KairoCommand(
                id: "find.next",
                title: "查找下一个",
                group: "查找",
                shortcut: KairoShortcut(key: "g", modifiers: .command),
                action: { find.findNext() }
            ),
            KairoCommand(
                id: "find.previous",
                title: "查找上一个",
                group: "查找",
                shortcut: KairoShortcut(key: "g", modifiers: [.command, .shift]),
                action: { find.findPrevious() }
            ),
            KairoCommand(
                id: "find.regex",
                title: "切换正则模式",
                group: "查找",
                shortcut: KairoShortcut(key: "e", modifiers: [.command, .option]),
                action: { find.regexMode.toggle() }
            ),
            KairoCommand(
                id: "palette.show",
                title: "命令面板",
                group: "查找",
                shortcut: KairoShortcut(key: "k", modifiers: .command),
                action: { store.showCommandPalette = true }
            )
        ]
    }
}

/// 由注册表生成菜单栏（US-E4-05 验收 3：菜单命令与面板同源）。
struct KairoMenuCommands: Commands {
    let commands: [KairoCommand]

    var body: some Commands {
        CommandGroup(after: .saveItem) {
            Divider()
            items(group: "文件")
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
}

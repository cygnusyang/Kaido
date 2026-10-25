import AppKit
import Foundation

/// 基线改名弹窗（v0.13 既有文案，v0.14 起菜单栏与工具栏共用同一条路径）。
///
/// 菜单项动作拿不到视图的 @State：若菜单另起一套 SwiftUI alert，改名就有了两个入口、
/// 两份校验。这里用挂在当前窗口上的 NSAlert 承接，两处都调它，输入校验只有 normalized 一份。
@MainActor
enum BaselineRenamePrompt {
    /// 名字归一化：去首尾空白；空串回落 nil（不提交——会话本身也会拒绝空名）。
    nonisolated static func normalized(_ draft: String) -> String? {
        let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// 弹窗改名；用户取消或只输入空白时不回调。
    static func present(currentName: String, onCommit: @escaping @MainActor (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = I18n.t("alert.baseline.rename.title", "Rename Baseline")
        let field = NSTextField(string: currentName)
        field.placeholderString = I18n.t("alert.baseline.rename.placeholder", "Baseline name")
        field.frame = NSRect(x: 0, y: 0, width: 260, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: I18n.t("action.ok", "OK"))
        alert.addButton(withTitle: I18n.t("action.cancel", "Cancel"))
        // 无窗口（纯逻辑测试 / 无界面进程）时静默返回：改名不是必须失败的路径。
        guard let window = NSApp?.keyWindow ?? NSApp?.mainWindow else { return }
        alert.beginSheetModal(for: window) { response in
            guard response == .alertFirstButtonReturn,
                  let name = normalized(field.stringValue) else { return }
            Task { @MainActor in onCommit(name) }
        }
    }
}
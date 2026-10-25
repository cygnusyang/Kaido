import AppKit
import UniformTypeIdentifiers

/// 退出守卫（ADR-013）：有未保存修改时，⌘Q 前必须由用户选择保存、丢弃或取消。
///
/// 提示与面板经三个可注入点呈现（默认走 NSAlert / NSSavePanel）：退出路径的
/// 「必拦」「保存失败不退」两条判据因此可在测试里断言，不必等模态窗口点击。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 用户在退出提示里的选择。
    enum QuitChoice {
        case saveAndQuit
        case discardAndQuit
        case cancel
    }

    weak var store: WorkspaceStore?

    /// 退出裁决提示（测试注入桩，避免模态阻塞）。
    var askQuitChoice: @MainActor (WorkspaceStore) -> QuitChoice = {
        AppDelegate.promptQuitChoice(for: $0)
    }
    /// 尚无保存路径时的另存为面板（测试注入桩）。
    var chooseSaveURL: @MainActor (WorkspaceStore) -> URL? = {
        AppDelegate.promptSaveURL(for: $0)
    }
    /// 保存失败提示（测试注入桩）。
    var showSaveError: @MainActor (String) -> Void = { message in
        AppDelegate.promptSaveError(message)
    }

    /// 启动即把应用内语言同步到进程级本地化（#15）。
    ///
    /// 修的是历史安装：早前只写了 `KairoLanguage`，没写 `AppleLanguages`，
    /// 这类用户升级后若不重选语言，系统菜单会一直停在系统语言。这里每次启动
    /// 幂等重写一次，保证两套语言来源一致。
    func applicationWillFinishLaunching(_ notification: Notification) {
        AppLanguage.applyProcessLocalization(choice: AppLanguage.stored())
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        terminationReply()
    }

    /// 退出裁决（不依赖 NSApplication 实例，测试直接调用）。
    func terminationReply() -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedChanges else { return .terminateNow }
        switch askQuitChoice(store) {
        case .saveAndQuit:
            return saveAndTerminate(store)
        case .discardAndQuit:
            return .terminateNow
        case .cancel:
            return .terminateCancel
        }
    }

    private func saveAndTerminate(_ store: WorkspaceStore) -> NSApplication.TerminateReply {
        if store.projectURL != nil {
            store.save()
        } else {
            guard let url = chooseSaveURL(store) else { return .terminateCancel }
            store.save(to: url)
        }
        // 退出是最后一次落盘机会：失败态或仍然脏都不得放行。
        guard store.saveState != .failed, !store.hasUnsavedChanges else {
            // 先取走错误文本再弹窗：模态期间视图的 alertMessage 绑定仍挂着，
            // 取消退出后会再补弹一次同样的错误（同一失败弹两次）。
            let message = store.alertMessage
                ?? I18n.t("alert.save_failed.message", "The project file could not be saved; quit cancelled.")
            store.alertMessage = nil
            showSaveError(message)
            return .terminateCancel
        }
        return .terminateNow
    }

    private static func promptQuitChoice(for store: WorkspaceStore) -> QuitChoice {
        let alert = NSAlert()
        alert.messageText = I18n.t("alert.unsaved_quit.title", "Unsaved changes")
        alert.informativeText = I18n.t("alert.unsaved_quit.message", "Quitting will discard unsaved changes to the current project.")
        alert.alertStyle = .warning
        alert.addButton(withTitle: I18n.t("alert.unsaved_quit.save_and_quit", "Save and Quit"))
        alert.addButton(withTitle: I18n.t("alert.unsaved_quit.discard_and_quit", "Discard Changes and Quit"))
        alert.addButton(withTitle: I18n.t("action.cancel", "Cancel"))
        switch alert.runModal() {
        case .alertFirstButtonReturn: return .saveAndQuit
        case .alertSecondButtonReturn: return .discardAndQuit
        default: return .cancel
        }
    }

    private static func promptSaveURL(for store: WorkspaceStore) -> URL? {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.kairo]
        panel.nameFieldStringValue = store.suggestedSaveFilename
        guard panel.runModal() == .OK else { return nil }
        return panel.url
    }

    private static func promptSaveError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = I18n.t("alert.save_failed.title", "Save Failed")
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.addButton(withTitle: I18n.t("action.ok", "OK"))
        alert.runModal()
    }
}

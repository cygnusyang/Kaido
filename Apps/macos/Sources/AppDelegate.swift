import AppKit
import UniformTypeIdentifiers

/// 退出守卫（ADR-013）：有未保存修改时，⌘Q 前必须由用户选择保存、丢弃或取消。
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var store: WorkspaceStore?

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store, store.hasUnsavedChanges else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "有未保存的修改"
        alert.informativeText = "退出将丢失当前项目的未保存修改。"
        alert.alertStyle = .warning
        alert.addButton(withTitle: "保存并退出")
        alert.addButton(withTitle: "放弃修改并退出")
        alert.addButton(withTitle: "取消")
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            return saveAndTerminate(store)
        case .alertSecondButtonReturn:
            return .terminateNow
        default:
            return .terminateCancel
        }
    }

    private func saveAndTerminate(_ store: WorkspaceStore) -> NSApplication.TerminateReply {
        if store.projectURL != nil {
            store.save()
            guard store.saveState != .failed else {
                showSaveError(store)
                return .terminateCancel
            }
            return .terminateNow
        }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.kairo]
        panel.nameFieldStringValue = store.suggestedSaveFilename
        guard panel.runModal() == .OK, let url = panel.url else { return .terminateCancel }
        store.save(to: url)
        guard store.saveState != .failed else {
            showSaveError(store)
            return .terminateCancel
        }
        return .terminateNow
    }

    private func showSaveError(_ store: WorkspaceStore) {
        let alert = NSAlert()
        alert.messageText = "保存失败"
        alert.informativeText = store.alertMessage ?? "无法保存项目文件，已取消退出。"
        alert.alertStyle = .critical
        alert.addButton(withTitle: "好")
        alert.runModal()
        store.alertMessage = nil
    }
}

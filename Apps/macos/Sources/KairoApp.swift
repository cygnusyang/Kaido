import Foundation
import SwiftUI
import KairoCore

@main
struct KairoApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var store = WorkspaceStore()
    @State private var showOpenPanel = false
    @State private var showSavePanel = false
    @State private var errorMessage: String?

    var body: some Scene {
        WindowGroup("Kairo") {
            WorkspaceView(store: store, commands: commandCatalog)
                .frame(
                    minWidth: DesignTokens.minimumWindowWidth,
                    minHeight: DesignTokens.minimumWindowHeight
                )
                .onAppear { appDelegate.store = store }
                .onOpenURL { handleDeepLink($0) }
                .fileImporter(
                    isPresented: $showOpenPanel,
                    allowedContentTypes: [.kairo],
                    allowsMultipleSelection: false
                ) { result in
                    if case .success(let urls) = result, let url = urls.first {
                        openFile(url)
                    }
                }
                .fileExporter(
                    isPresented: $showSavePanel,
                    document: KairoDocument(state: store.exportState),
                    contentType: .kairo,
                    defaultFilename: store.suggestedSaveFilename
                ) { result in
                    switch result {
                    case .success(let url):
                        finishExport(to: url)
                    case .failure(let error):
                        store.cancelExport()
                        if let message = ExportFailure.message(for: error) {
                            errorMessage = message
                        }
                    }
                }
                .alert(
                    "错误",
                    isPresented: Binding(
                        get: { errorMessage != nil },
                        set: { if !$0 { errorMessage = nil } }
                    )
                ) {
                    Button("好", role: .cancel) {}
                } message: {
                    Text(errorMessage ?? "")
                }
        }
        .defaultSize(
            width: DesignTokens.defaultWindowWidth,
            height: DesignTokens.defaultWindowHeight
        )
        .commands {
            KairoMenuCommands(commands: commandCatalog)
        }
    }

    /// 全应用命令注册表：菜单栏与 ⌘K 面板共用（US-E4-05 验收 3）。
    private var commandCatalog: [KairoCommand] {
        KairoCommandCatalog.make(
            store: store,
            requestOpen: { showOpenPanel = true },
            requestSave: { saveDocument() },
            requestSaveAs: { saveDocumentAs() }
        )
    }

    // MARK: - 深链

    /// `kairo://task/<id>`、`kairo://task?title=<标题>`、`kairo://project/<id>`（US-E5-04）。
    /// 双击 `.kairo` 文件走 LaunchServices 的 `file://` 事件，直接按文件打开。
    private func handleDeepLink(_ url: URL) {
        if url.isFileURL {
            openFile(url)
            return
        }
        guard let link = KairoDeepLink.parse(url) else {
            errorMessage = "无法识别的 Kairo 链接：\(url.absoluteString)"
            return
        }
        let project = store.exportProject
        let match = KairoDeepLinkResolver.resolve(link, in: project)
        switch link.target {
        case .projectID:
            if !match.projectMatched {
                errorMessage = "链接指向其他项目；当前项目为「\(project.metadata.title)」"
            }
        case .taskID, .taskTitle:
            guard let id = match.taskID else {
                errorMessage = "链接中的任务不在当前项目中：\(url.absoluteString)"
                return
            }
            store.reveal(id)
            if match.matchCount > 1 {
                errorMessage = "有 \(match.matchCount) 个同名任务，已定位第一个"
            }
        }
    }

    // MARK: - 文件操作

    private func openFile(_ url: URL) {
        store.openAsync(url: url)
    }

    private func saveDocument() {
        if store.projectURL != nil {
            store.save()
            if let message = store.alertMessage {
                errorMessage = message
                store.alertMessage = nil
            }
        } else {
            // 尚无保存路径：走 fileExporter 选择位置。
            store.beginExport()
            showSavePanel = true
        }
    }

    /// 另存为：始终打开位置选择面板，默认文件名由存储层按当前状态生成。
    private func saveDocumentAs() {
        store.beginExport()
        showSavePanel = true
    }

    private func finishExport(to url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        // 文件导出器已写入快照；再次 save 会重复写同一文件。
        store.rememberSaveURL(url)
        if let message = store.alertMessage {
            errorMessage = message
            store.alertMessage = nil
        }
    }
}

/// `fileExporter` 失败回调分类：用户取消是正常路径，不弹错误。
enum ExportFailure {
    /// 用户取消返回 nil；其他错误返回可展示的消息。
    static func message(for error: Error) -> String? {
        let nsError = error as NSError
        guard nsError.domain == NSCocoaErrorDomain,
              nsError.code == NSUserCancelledError else {
            return error.localizedDescription
        }
        return nil
    }
}

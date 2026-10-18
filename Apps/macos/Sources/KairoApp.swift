import SwiftUI
import KairoCore

@main
struct KairoApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var find = FindModel()
    @State private var showOpenPanel = false
    @State private var showSavePanel = false
    @State private var errorMessage: String?
    /// 由 kairo:// 深链解析出的待选中任务；ContentView 消费后清空。
    @State private var deepLinkTaskID: UUID?

    var body: some Scene {
        WindowGroup("Kairo") {
            ContentView(store: store, find: find, deepLinkTaskID: $deepLinkTaskID)
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
                    document: KairoDocument(project: store.project),
                    contentType: .kairo,
                    defaultFilename: "project.kairo"
                ) { result in
                    if case .success(let url) = result {
                        rememberExportedURL(url)
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
        .commands {
            KairoCommands(find: find)
            CommandGroup(after: .saveItem) {
                Button("打开…") { showOpenPanel = true }
                    .keyboardShortcut("o", modifiers: .command)
                Button("保存") { saveDocument() }
                    .keyboardShortcut("s", modifiers: .command)
            }
        }
    }

    // MARK: - 深链

    /// `kairo://task/<id>`、`kairo://task?title=<标题>`、`kairo://project/<id>`（US-E5-04）。
    private func handleDeepLink(_ url: URL) {
        guard let link = KairoDeepLink.parse(url) else {
            errorMessage = "无法识别的 Kairo 链接：\(url.absoluteString)"
            return
        }
        let match = KairoDeepLinkResolver.resolve(link, in: store.project)
        switch link.target {
        case .projectID:
            if !match.projectMatched {
                errorMessage = "链接指向其他项目；当前项目为「\(store.project.metadata.title)」"
            }
        case .taskID, .taskTitle:
            guard let id = match.taskID else {
                errorMessage = "链接中的任务不在当前项目中：\(url.absoluteString)"
                return
            }
            deepLinkTaskID = id
            if match.matchCount > 1 {
                errorMessage = "有 \(match.matchCount) 个同名任务，已定位第一个"
            }
        }
    }

    // MARK: - 文件操作

    private func openFile(_ url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            try store.open(url: url)
        } catch {
            presentError(error)
        }
    }

    private func saveDocument() {
        if store.projectURL != nil {
            do {
                try store.save()
            } catch {
                presentError(error)
            }
        } else {
            // 尚无保存路径：走 fileExporter 选择位置。
            showSavePanel = true
        }
    }

    private func rememberExportedURL(_ url: URL) {
        // fileExporter 已写 .kairo（与 saveProject 同一编码器）；回填路径供 ⌘S 直存。
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        store.rememberSaveURL(url)
    }

    private func presentError(_ error: Error) {
        errorMessage = String(describing: error)
    }
}

/// App menu for find actions. Buttons act on the shared `FindModel`
/// instance owned by the app.
struct KairoCommands: Commands {
    @ObservedObject var find: FindModel

    var body: some Commands {
        CommandMenu("查找") {
            Button("查找下一个") { find.findNext() }
                .keyboardShortcut("g", modifiers: .command)
            Button("查找上一个") { find.findPrevious() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            Divider()
            Toggle("正则模式", isOn: $find.regexMode)
                .keyboardShortcut("e", modifiers: [.command, .option])
        }
    }
}

import SwiftUI
import KairoCore

@main
struct KairoApp: App {
    @StateObject private var store = ProjectStore()
    @StateObject private var find = FindModel()
    @State private var showOpenPanel = false
    @State private var showSavePanel = false
    @State private var errorMessage: String?

    var body: some Scene {
        WindowGroup("Kairo") {
            ContentView(store: store, find: find)
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

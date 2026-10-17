import SwiftUI
import KairoCore

@main
struct KairoApp: App {
    @StateObject private var store = ProjectStore(project: SeedData.makeProject())
    @StateObject private var find = FindModel()

    var body: some Scene {
        WindowGroup("Kairo") {
            ContentView(store: store, find: find)
        }
        .commands {
            KairoCommands(find: find)
        }
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

import Foundation
import KairoCore

/// 应用层可观察门面：包装纯逻辑的 KairoCore `Project`（ADR-004）。
/// 核心模型不做平台绑定；本门面负责在 SwiftUI 里发出变更通知。
/// 所有会改动 `tasks` 的入口都经由这里，保证 UI 刷新。
@MainActor
final class ProjectStore: ObservableObject {
    @Published var project: Project

    init(project: Project = Project()) {
        self.project = project
    }

    func add(_ task: TaskItem) {
        project.add(task)
        objectWillChange.send()
    }

    func update(_ task: TaskItem) {
        project.update(task)
        objectWillChange.send()
    }

    func remove(id: UUID) {
        project.remove(id: id)
        objectWillChange.send()
    }
}

import Foundation
import KairoCore
import KairoCommands

/// 应用层可观察门面：包装 KairoSession 命令层（ADR-004 / ADR-005 契约同源）。
/// 会话为命令层事实源（与 MCP、CLI 同一操作路径）；本门面把会话项目镜像为
/// @Published 供 SwiftUI 刷新，文件打开 / 保存统一经会话。
@MainActor
final class ProjectStore: ObservableObject {
    @Published private(set) var project: Project
    private let session: KairoSession

    init() {
        let session = KairoSession()
        self.session = session
        _ = try? session.createProject(title: "未命名项目")
        // 首启动演示数据（Sprint 0 保留）：任务直接加入会话项目（同一实例引用）。
        let seed = SeedData.makeProject()
        for task in seed.tasks { session.project?.add(task) }
        self.project = session.project ?? Project()
    }

    /// 已打开项目的保存路径（nil = 尚未保存过）。
    var projectURL: URL? { session.projectURL }

    /// 打开 .kairo：经会话校验格式（含 formatVersion）并载入。
    func open(url: URL) throws {
        _ = try session.openProject(at: url)
        project = session.project ?? project
        objectWillChange.send()
    }

    /// 保存到指定路径（nil = 使用已打开路径）。
    func save(to url: URL? = nil) throws {
        _ = try session.saveProject(to: url)
        objectWillChange.send()
    }

    /// 另存为完成后记录路径（供后续 ⌘S 直存）。
    func rememberSaveURL(_ url: URL) {
        session.setProjectURL(url)
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

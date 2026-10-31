import Foundation
import SwiftUI
import UniformTypeIdentifiers
import KaidoCore

extension UTType {
    /// .kaido 单文件格式的动态类型（未注册正式 UTType，按扩展名兜底）。
    static var kaido: UTType {
        UTType(filenameExtension: "kaido") ?? .data
    }
}

/// 文件导出文档：fileExporter 写 .kaido。
/// 与 KaidoSession.saveProject 共用 KaidoFile 编码器（字节一致，ADR-005 契约同源）；
/// 读取不经此处——打开统一走 KaidoSession.openProject（含 formatVersion 校验）。
struct KaidoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.kaido] }

    /// 值快照而非活模型：系统可能在非主线程调用 `fileWrapper`。
    let state: ProjectState

    init(state: ProjectState) {
        self.state = state
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadCorruptFile)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let project = Project()
        state.apply(to: project)
        let data = try KaidoFile.encode(project: project)
        return FileWrapper(regularFileWithContents: data)
    }
}

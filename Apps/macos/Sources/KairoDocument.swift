import Foundation
import SwiftUI
import UniformTypeIdentifiers
import KairoCore

extension UTType {
    /// .kairo 单文件格式的动态类型（未注册正式 UTType，按扩展名兜底）。
    static var kairo: UTType {
        UTType(filenameExtension: "kairo") ?? .data
    }
}

/// 文件导出文档：fileExporter 写 .kairo。
/// 与 KairoSession.saveProject 共用 KairoFile 编码器（字节一致，ADR-005 契约同源）；
/// 读取不经此处——打开统一走 KairoSession.openProject（含 formatVersion 校验）。
struct KairoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.kairo] }

    let project: Project

    init(project: Project) {
        self.project = project
    }

    init(configuration: ReadConfiguration) throws {
        throw CocoaError(.fileReadCorruptFile)
    }

    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        let data = try KairoFile.encode(project: project)
        return FileWrapper(regularFileWithContents: data)
    }
}

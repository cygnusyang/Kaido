import Foundation
import SwiftUI
import UniformTypeIdentifiers
import ZenoCore

extension UTType {
    /// .zeno 单文件格式的动态类型（未注册正式 UTType，按扩展名兜底）。
    static var zeno: UTType {
        UTType(filenameExtension: "zeno") ?? .data
    }
}

/// 文件导出文档：fileExporter 写 .zeno。
/// 与 ZenoSession.saveProject 共用 ZenoFile 编码器（字节一致，ADR-005 契约同源）；
/// 读取不经此处——打开统一走 ZenoSession.openProject（含 formatVersion 校验）。
struct ZenoDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.zeno] }

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
        let data = try ZenoFile.encode(project: project)
        return FileWrapper(regularFileWithContents: data)
    }
}

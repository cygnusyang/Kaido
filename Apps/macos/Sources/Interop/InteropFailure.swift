import Foundation
import ZenoInterop

/// 互操作失败的展示口径：一个 `message` 就是用户该看的那句话。
///
/// 底层错误有三类（`InteropError` / 文件读取 / 写盘），界面只该看到一个可操作的提示，
/// 不该把 NSError 的 domain 与 code 摊给用户看。
struct InteropFailure: Error, Equatable {
    let message: String

    init(message: String) {
        self.message = message
    }

    /// 把任意错误折成一句提示。
    static func message(for error: Error) -> String {
        switch error {
        case let interop as InteropError: return interop.description
        case let failure as InteropFailure: return failure.message
        default: return error.localizedDescription
        }
    }
}

/// 一次导出的结果摘要：导出成功后提示什么、从哪里打开旁注。
struct ExportedSnapshot: Identifiable, Equatable {
    let id: UUID
    /// 主文件名（提示里只说文件名，不铺全路径）。
    let fileName: String
    /// 旁注文件路径：「打开旁注」的入口。
    let notesURL: URL

    init(fileName: String, notesURL: URL) {
        self.id = UUID()
        self.fileName = fileName
        self.notesURL = notesURL
    }
}

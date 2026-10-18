import Foundation
import KairoCore

/// 机器可读输出（US-E5-02 验收 2）：供脚本与插件 hook 直接解析。
/// 字段与 `.kairo` 模型一致（camelCase、ISO 8601 日期），不做二次裁剪。
enum CLIOutput {
    static func taskListJSON(_ tasks: [TaskItem]) throws -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return String(decoding: try encoder.encode(tasks), as: UTF8.self)
    }
}

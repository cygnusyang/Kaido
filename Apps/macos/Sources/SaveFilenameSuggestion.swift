import Foundation

/// 「另存为」文件名建议（FR-FILE-SAVEAS-2）：纯函数，便于独立验证。
///
/// 已有保存路径时沿用当前文件名；否则由项目标题生成：
/// 去掉首尾空格与点，`/`、`:` 与控制字符替换为 `-`，补 `.kairo` 后缀。
/// 标题为空或清洗后无有效字符时回退 `project.kairo`。
enum SaveFilenameSuggestion {
    static let fallback = "project.kairo"

    private static let kairoExtension = ".kairo"
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "."))

    static func suggest(currentURL: URL?, title: String) -> String {
        if let currentURL {
            let filename = currentURL.lastPathComponent
            if !filename.isEmpty {
                return withKairoExtension(filename)
            }
        }
        let cleaned = sanitize(title)
        // 只剩替换产生的 `-` 与空白，视为标题全非法。
        guard cleaned.contains(where: { !$0.isWhitespace && $0 != "-" }) else {
            return fallback
        }
        return withKairoExtension(cleaned)
    }

    private static func sanitize(_ title: String) -> String {
        String(title.map { character in
            isIllegal(character) ? "-" : character
        }).trimmingCharacters(in: trimCharacters)
    }

    private static func isIllegal(_ character: Character) -> Bool {
        if character == "/" || character == ":" { return true }
        return character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    private static func withKairoExtension(_ filename: String) -> String {
        filename.lowercased().hasSuffix(kairoExtension) ? filename : filename + kairoExtension
    }
}

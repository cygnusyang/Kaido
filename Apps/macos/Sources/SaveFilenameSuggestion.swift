import Foundation

/// 「另存为」文件名建议（FR-FILE-SAVEAS-2）：纯函数，便于独立验证。
///
/// 已有保存路径时沿用当前文件名；否则由项目标题生成：
/// 去掉首尾空格与点，`/`、`:` 与控制字符替换为 `-`，补 `.zeno` 后缀。
/// 标题为空或清洗后无有效字符时回退 `project.zeno`。
enum SaveFilenameSuggestion {
    static let fallback = "project.zeno"

    private static let zenoExtension = ".zeno"
    /// 默认文件名的 UTF-8 字节上限；超出时按字符截断基名并保留后缀。
    private static let maxFilenameBytes = 200
    private static let trimCharacters = CharacterSet.whitespacesAndNewlines
        .union(CharacterSet(charactersIn: "."))

    static func suggest(currentURL: URL?, title: String) -> String {
        if let currentURL {
            let filename = currentURL.lastPathComponent
            // 隐藏文件（以 `.` 开头）不适合作为默认名，交给标题生成。
            if !filename.isEmpty, !filename.hasPrefix(".") {
                return withZenoExtension(filename)
            }
        }
        let cleaned = sanitize(title)
        // 只剩替换产生的 `-` 与空白，视为标题全非法。
        guard cleaned.contains(where: { !$0.isWhitespace && $0 != "-" }) else {
            return fallback
        }
        return withZenoExtension(cleaned)
    }

    private static func sanitize(_ title: String) -> String {
        var cleaned = String(title.map { character in
            isIllegal(character) ? "-" : character
        }).trimmingCharacters(in: trimCharacters)
        // 替换产生的尾部 `-` 及随后露出的空白不进入文件名。
        while let last = cleaned.last, last == "-" || last.isWhitespace || last == "." {
            cleaned.removeLast()
        }
        return cleaned
    }

    private static func isIllegal(_ character: Character) -> Bool {
        if character == "/" || character == ":" { return true }
        return character.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// 补 `.zeno` 后缀；超过文件名字节上限时按字符截断基名，保证 UTF-8 完整。
    private static func withZenoExtension(_ filename: String) -> String {
        let name = filename.lowercased().hasSuffix(zenoExtension)
            ? filename : filename + zenoExtension
        guard name.utf8.count > maxFilenameBytes else { return name }
        let suffix = String(name.suffix(zenoExtension.count))
        var base = String(name.dropLast(zenoExtension.count))
        while !base.isEmpty, base.utf8.count + suffix.utf8.count > maxFilenameBytes {
            base.removeLast()
        }
        return base + suffix
    }
}

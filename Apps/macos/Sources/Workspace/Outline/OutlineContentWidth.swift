import AppKit
import KaidoPresentation

/// 内容自适应列宽（#48）：按当前项目实际出现的文本测量列宽，取代固定常量。
///
/// 固定常量的问题：序号列曾是 44pt（为放下「10.12」而设），但四级序号
/// 「1.2.3.4」、带进位前缀的「1.2.3.10」都更宽，超出部分被行裁剪吃掉，
/// 用户看到的就是「序号显示不全」；反过来，只到「1.2」的项目里 44pt 又留了大截空白。
///
/// 各列口径不同：
/// - `number`：宽度**完全**由内容决定——最宽序号 + 内边距，不低于 `minimumNumber`
///   （再窄连表头「序号」两字都会被裁）；
/// - `predecessors`：只做「不截断」的下界——不小于派生宽，只有多前置长串时才变宽，
///   既有观感不变。
///
/// 候选串有上限（`candidateLimit`）：大项目里逐行测量会让每次重绘都多花几毫秒。
/// 序号是等宽数字加点，同长度里宽度由字符种类决定，因此按「长度最长」取候选即可覆盖最宽串。
enum OutlineContentWidth {
    /// 序号列最小宽度（点）：11pt 下「序号」两字约 22pt，加表头左右各 4pt 内边距，32pt 才不裁字。
    static let minimumNumber: CGFloat = 32

    /// 序号格内边距（点）：右 6pt（行内 `padding(.trailing, 6)`）+ 左 4pt（与表头内边距同值）。
    static let numberPadding: CGFloat = 10

    /// 文本格内边距（点）：`EditableTextCell` 左右各 4pt。
    static let textPadding: CGFloat = 8

    /// 单次测量的候选条数上限：同长度的并列串最多测这么多条。
    static let candidateLimit = 16

    /// 按当前行集合算出内容自适应列宽（点）；键缺省的列沿用派生宽。
    ///
    /// 行集合来自快照，折叠/展开、增删任务后 `rows` 变化，宽度随之重算——
    /// 折叠起来的深层任务不占宽度，展开后立刻回来。
    ///
    /// - Parameter rows: 大纲当前可见行（快照顺序）。
    /// - Returns: 列 → 宽度（点），只含内容可驱动的列（`number` / `predecessors`）。
    static func widths(for rows: [PlanRow]) -> [OutlineColumn: CGFloat] {
        let numberFont = NSFont.monospacedDigitSystemFont(
            ofSize: DesignTokens.captionFontSize,
            weight: .regular
        )
        let textFont = NSFont.systemFont(ofSize: DesignTokens.bodyFontSize)

        let numberMeasure = measuredWidth(rows.lazy.map(\.outlineNumber), font: numberFont)
        let predecessorMeasure = measuredWidth(
            rows.lazy.map { $0.predecessorsText.isEmpty ? Display.placeholder : $0.predecessorsText },
            font: textFont
        )
        // 前置列表的既有宽度是「没有前置也占 96pt」的观感基线，只上探不下压。
        let predecessorFloor = OutlineColumn.predecessors.width(bodyFontSize: DesignTokens.bodyFontSize)

        return [
            .number: max(numberMeasure + numberPadding, minimumNumber),
            .predecessors: max(predecessorMeasure + textPadding, predecessorFloor),
        ]
    }

    /// 一组文本里最宽的一条（点）：按长度取候选，再逐个量宽取最大。
    ///
    /// 空集合返回 0（调用方各自用下限托底）。
    static func measuredWidth(_ texts: some Sequence<String>, font: NSFont) -> CGFloat {
        var longest = 0
        var candidates: [String] = []
        for text in texts {
            if text.count > longest {
                longest = text.count
                candidates = [text]
            } else if text.count == longest && candidates.count < candidateLimit {
                candidates.append(text)
            }
        }
        return candidates.reduce(0) { widest, candidate in
            max(widest, textWidth(candidate, font: font))
        }
    }

    /// 单条文本的排版宽度（点，向上取整）：少取半像素会重新引入「末位被裁」。
    static func textWidth(_ text: String, font: NSFont) -> CGFloat {
        guard !text.isEmpty else { return 0 }
        let width = (text as NSString).size(withAttributes: [.font: font]).width
        return ceil(width)
    }
}

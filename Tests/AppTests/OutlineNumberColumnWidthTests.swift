import AppKit
import CoreGraphics
import Testing
import ZenoCore
import ZenoPresentation
@testable import ZenoMacApp

// #48「大纲序号显示不全」回归：序号列宽曾固定 44pt（为放下「10.12」而设），
// 四级 / 多级序号（1.2.3.4、1.2.3.10）比它宽，超出的部分被行 `.clipped()` 吃掉，
// 用户看到的就是序号缺位；短序号项目里 44pt 又白白占走任务说明的宽度。
//
// 本文件的断言口径：列宽 ≥ 每个序号串在**表格实际字体**（11pt 等宽数字）下的排版宽度 + 右侧 6pt 内边距。
// 测量不复用 `OutlineContentWidth` 的内部实现，直接用 `NSString.size(withAttributes:)`
// 独立量一遍——否则实现量错，测试会跟着一起错。

@MainActor
@Suite("大纲序号列宽（#48）")
struct OutlineNumberColumnWidthTests {
    /// 行内序号格实际字体：`OutlineRowView` 用 `.system(size: captionFontSize).monospacedDigit()`。
    private var numberFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: DesignTokens.captionFontSize, weight: .regular)
    }

    /// 序号串在表格字体下的排版宽度（点）；测试侧的独立测量。
    private func textWidth(_ text: String) -> CGFloat {
        ceil((text as NSString).size(withAttributes: [.font: numberFont]).width)
    }

    /// 序号格右侧内边距：`OutlineRowView` 的 `.padding(.trailing, 6)`。
    private let trailingPadding: CGFloat = 6

    private func rows(_ numbers: [String], predecessors: [String] = []) -> [PlanRow] {
        numbers.enumerated().map { index, number in
            PlanRow(
                id: UUID(),
                depth: number.split(separator: ".").count - 1,
                outlineNumber: number,
                kind: .task,
                title: "任务 \(index + 1)",
                status: .pending,
                priority: .normal,
                predecessorsText: index < predecessors.count ? predecessors[index] : ""
            )
        }
    }

    private func layout(for rows: [PlanRow], totalWidth: CGFloat = 600) -> OutlineColumnLayout {
        OutlineColumnLayout(
            columns: OutlineColumn.visibleColumns(outlineWidth: 600),
            totalWidth: totalWidth,
            focused: false,
            contentWidths: OutlineContentWidth.widths(for: rows)
        )
    }

    /// 1.2.3.10 比 1.2.3.4 多一位，列宽必须更宽（固定常量下两者相等，后者被裁）。
    @Test func longerOutlineNumberYieldsWiderColumn() {
        let short = layout(for: rows(["1", "1.2", "1.2.3.4"]))
        let long = layout(for: rows(["1", "1.2", "1.2.3.10"]))

        #expect(long.width(of: .number) > short.width(of: .number))
        #expect(short.width(of: .number) >= textWidth("1.2.3.4") + trailingPadding)
        #expect(long.width(of: .number) >= textWidth("1.2.3.10") + trailingPadding)
    }

    /// 项目里出现的每个序号串都必须放得下：一个都不能被裁（含进位到两位的 1.2.10）。
    @Test func everyOutlineNumberFitsTheColumn() {
        let numbers = ["1", "1.1", "1.2", "1.2.1", "1.2.10", "1.2.3.4", "1.2.3.10", "10.12"]
        let layout = layout(for: rows(numbers))
        let width = layout.width(of: .number)

        for number in numbers {
            #expect(width >= textWidth(number) + trailingPadding)
        }
        #expect(!numbers.contains { textWidth($0) + trailingPadding > width })
    }

    /// 六级含两位数序号：宽 ≈73pt，加内边距 83pt 已超过旧的拖拽上界 80。
    /// 内容自适应必须原样生效，用户拖宽也要拖得到（上界 120，见 `widthRange`）。
    @Test func deepOutlineNumberExceedsLegacyUpperBound() {
        let number = "1.2.3.10.4.11"
        let layout = layout(for: rows(["1", "1.2", number]))
        let width = layout.width(of: .number)
        let legacyUpperBound: CGFloat = 80

        #expect(width >= textWidth(number) + trailingPadding)
        #expect(width > legacyUpperBound, "六级序号宽 \(width) 应超过旧上界 \(legacyUpperBound)")
        #expect(width == textWidth(number) + OutlineContentWidth.numberPadding)
        #expect(OutlineColumnPreferences.widthRange(for: .number).upperBound >= width,
                "拖拽上界要包住内容宽，否则一拖就被夹回去")
    }

    /// 深一层序号带来的增量必须体现在宽度上：宽度跟随内容，而不是跟随行数。
    @Test func columnWidthTracksContentNotRowCount() {
        let few = layout(for: rows(["1", "1.2.3.10"]))
        let many = layout(for: rows((1...50).map { "1.\($0)" }))

        #expect(few.width(of: .number) > many.width(of: .number))
    }

    /// 窄窗口下序号列不被压缩系数带窄：压缩只吃任务说明的余量。
    @Test func numberColumnIsNotCompressedOnNarrowOutline() {
        let wide = layout(for: rows(["1", "1.2.3.10"]), totalWidth: 600)
        let narrow = layout(for: rows(["1", "1.2.3.10"]), totalWidth: 360)

        #expect(narrow.width(of: .number) == wide.width(of: .number))
        #expect(narrow.width(of: .number) >= textWidth("1.2.3.10") + trailingPadding)
    }

    /// 空项目：不崩、序号列回到最小值，且不占 44pt 的旧常量空白。
    @Test func emptyOutlineKeepsNumberColumnMinimal() {
        let empty = layout(for: [])
        let width = OutlineContentWidth.widths(for: [])[.number] ?? 0

        #expect(width == OutlineContentWidth.minimumNumber)
        #expect(width < OutlineColumn.number.width(bodyFontSize: DesignTokens.bodyFontSize))
        #expect(empty.width(of: .number) == OutlineContentWidth.minimumNumber)
        // 空项目仍要能画出任务说明列，且宽度不为负。
        #expect(empty.width(of: .title) > 0)
    }

    /// 前置任务列同属「固定常量」缺陷：多个前置的长串必须放得下，短项目保持既有 96pt 观感。
    @Test func longPredecessorListWidensWithoutShrinkingShortCase() {
        let longText = "A8FC:fs+1.5, B2DE:fs, C4E1:ss"
        let long = layout(for: rows(["1"], predecessors: [longText]))
        let short = layout(for: rows(["1"], predecessors: ["A8FC:fs"]))

        let bodyFont = NSFont.systemFont(ofSize: DesignTokens.bodyFontSize)
        let needed = ceil((longText as NSString).size(withAttributes: [.font: bodyFont]).width) + 8
        #expect(long.width(of: .predecessors) >= needed)
        // 短串项目不缩窄：与派生宽（96pt）逐位相同，既有观感不变。
        #expect(short.width(of: .predecessors) == CGFloat(
            OutlineColumn.predecessors.width(bodyFontSize: DesignTokens.bodyFontSize)
        ))
    }
}

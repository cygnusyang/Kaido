import AppKit
import SwiftUI

/// 设计 token（docs/DESIGN.md / ui-redesign.md §2.9）。
///
/// 全部颜色按浅色 / 深色 / 高对比模式动态解析；视图不直接写字面色值。
enum DesignTokens {
    /// 正文 13pt；大纲、画布、状态栏共用。
    static let bodyFontSize: CGFloat = 13
    static let captionFontSize: CGFloat = 11
    static let rowHeight: CGFloat = 28
    static let headerHeight: CGFloat = 44
    static let headerTierHeight: CGFloat = 22
    static let toolbarHeight: CGFloat = 52
    static let filterBarHeight: CGFloat = 32
    static let statusBarHeight: CGFloat = 26
    static let outlineMinWidth: CGFloat = 320
    static let outlineMaxWidth: CGFloat = 640
    static let canvasMinWidth: CGFloat = 320
    static let focusedOutlineWidth: CGFloat = 180
    static let inspectorMinWidth: CGFloat = 280
    static let inspectorMaxWidth: CGFloat = 420
    static let minimumWindowWidth: CGFloat = 820
    static let minimumWindowHeight: CGFloat = 520
    static let defaultWindowWidth: CGFloat = 1440
    static let defaultWindowHeight: CGFloat = 900
    static let inspectorThreshold: CGFloat = 1120

    // MARK: - 表面与文字

    static let surfaceBase = color(light: "FFFFFF", dark: "1C1C1E")
    static let surfaceChrome = color(light: "F6F7F9", dark: "242426")
    static let surfaceElevated = color(light: "FFFFFF", dark: "2C2C2E")
    static let separator = color(
        light: "D8DAE0", dark: "3A3A3C",
        highLight: "6E7686", highDark: "A8B0BE"
    )
    static let grid = color(light: "E6E8EC", dark: "303032")
    static let nonWorkingBand = color(light: "F2F3F5", dark: "232325")
    static let selection = color(light: "E4E7FA", dark: "2B3050")

    static let textPrimary = color(light: "1C1C1E", dark: "F2F2F7")
    static let textSecondary = color(light: "5C6169", dark: "A6A6AD")

    // MARK: - 语义

    static let today = color(
        light: "4A56D6", dark: "9AA6FF",
        highLight: "2C6BC9", highDark: "8FC0FF"
    )
    static let criticalGraphic = color(light: "A13EF2", dark: "A13EF2")
    static let criticalText = color(light: "7A1FC4", dark: "C79BFF")
    static let overdue = color(light: "C4121F", dark: "FF453A")
    static let violationError = color(light: "C4121F", dark: "FF453A")
    static let violationWarning = color(light: "A15C00", dark: "FF9F0A")
    static let statusSuccess = color(light: "1E7B4D", dark: "4BD18A")
    static let accentBase = color(light: "5F6CF8", dark: "5F6CF8")
    static let accentStrong = color(light: "4A56D6", dark: "9AA6FF")

    // MARK: - 图形

    static let progressTrack = color(light: "E4E7EC", dark: "3A3A3C")
    static let progressFill = color(light: "3D74C9", dark: "6FA3E8")
    static let dependency = color(light: "7A8290", dark: "8B93A3")

    // MARK: - 基线调色板（10-multi-baseline-gantt §4）

    // 索引语义与 ZenoCore.BaselinePalette.count 一一对应（8 色），顺序即索引：
    // 0 青 / 1 琥珀 / 2 绿 / 3 品红 / 4 橄榄 / 5 深靛 / 6 棕 / 7 岩蓝。
    // 快照只存索引，颜色值只此一份（ADR-013）。
    static let baselineLane0 = color(light: "0E7C7C", dark: "4FC7C4")
    static let baselineLane1 = color(light: "A86800", dark: "E3A63C")
    static let baselineLane2 = color(light: "2E7D46", dark: "5CC088")
    static let baselineLane3 = color(light: "9C2A6B", dark: "DE7BA8")
    static let baselineLane4 = color(light: "6B7A1F", dark: "A9B84E")
    // 深靛而非藏青：藏青与计划条 progressFill 同色系，会把「承诺」误读成「进行中」（§11 裁定）。
    static let baselineLane5 = color(light: "4B3F9E", dark: "9A8CE0")
    static let baselineLane6 = color(light: "7A5433", dark: "BE9066")
    static let baselineLane7 = color(light: "0F7089", dark: "4FB3CE")

    /// 按下标取基线色；越界回落首色（调用方应先用 BaselinePalette 归一索引）。
    static let baselinePalette: [Color] = [
        baselineLane0, baselineLane1, baselineLane2, baselineLane3,
        baselineLane4, baselineLane5, baselineLane6, baselineLane7,
    ]

    // MARK: - 叠加

    static let hoverOverlay = Color.primary.opacity(0.04)
    static let dropTargetOverlay = accentStrong.opacity(0.08)
    static let focusRingOuter = accentBase.opacity(0.35)

    /// 选中行内语义色文字统一回落为 `textPrimary`（ui-redesign §2.9）。
    static func semanticText(
        _ base: Color,
        isSelected: Bool
    ) -> Color {
        isSelected ? textPrimary : base
    }

    // MARK: - 解析

    private static func color(
        light: String,
        dark: String,
        highLight: String? = nil,
        highDark: String? = nil
    ) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let match = appearance.bestMatch(from: [
                .accessibilityHighContrastDarkAqua,
                .accessibilityHighContrastAqua,
                .darkAqua,
                .aqua
            ])
            switch match {
            case .accessibilityHighContrastDarkAqua:
                return NSColor(hex: highDark ?? dark)
            case .accessibilityHighContrastAqua:
                return NSColor(hex: highLight ?? light)
            case .darkAqua:
                return NSColor(hex: dark)
            default:
                return NSColor(hex: light)
            }
        })
    }
}

extension NSColor {
    /// `RRGGBB` 十六进制；非法输入回退为不透明黑。
    convenience init(hex: String) {
        let cleaned = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        var value: UInt64 = 0
        Scanner(string: cleaned).scanHexInt64(&value)
        let red = CGFloat((value >> 16) & 0xFF) / 255
        let green = CGFloat((value >> 8) & 0xFF) / 255
        let blue = CGFloat(value & 0xFF) / 255
        self.init(srgbRed: red, green: green, blue: blue, alpha: 1)
    }
}

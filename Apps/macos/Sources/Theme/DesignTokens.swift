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

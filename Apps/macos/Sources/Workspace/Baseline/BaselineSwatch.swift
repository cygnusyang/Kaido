import AppKit
import SwiftUI

/// 图例色块：菜单项里的那枚小方块。
///
/// 菜单会把 SF Symbol 当模板图渲染成单色，颜色就丢了；这里画一张**非模板** NSImage，
/// 菜单才按原色显示。越界索引回落首色（索引本应已由 BaselinePalette 归一）。
enum BaselineSwatch {
    /// 菜单项图片（10×10，2pt 圆角）。
    static func image(_ colorIndex: Int) -> Image {
        Image(nsImage: nsImage(colorIndex))
    }

    static func nsImage(_ colorIndex: Int) -> NSImage {
        let palette = DesignTokens.baselinePalette
        let color = palette.indices.contains(colorIndex) ? palette[colorIndex] : palette[0]
        let fill = NSColor(color)
        let image = NSImage(size: NSSize(width: 10, height: 10), flipped: false) { rect in
            fill.setFill()
            NSBezierPath(roundedRect: rect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2).fill()
            return true
        }
        image.isTemplate = false
        return image
    }
}
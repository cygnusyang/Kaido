import AppKit
import SwiftUI

/// 离屏渲染快照：统一为 RGBA8 像素，供测试判断画面是否为空、两个状态是否不同。
struct RenderedSnapshot {
    let width: Int
    let height: Int
    /// 每像素 4 字节（R、G、B、A），按行优先排列。
    let pixels: [UInt8]

    var pixelCount: Int { width * height }

    /// 非透明像素占比；空白（未绘制任何内容）画面为 0。
    var nonTransparentRatio: Double {
        guard pixelCount > 0 else { return 0 }
        var opaque = 0
        for index in stride(from: 3, to: pixels.count, by: 4) where pixels[index] > 0 {
            opaque += 1
        }
        return Double(opaque) / Double(pixelCount)
    }

    /// 采样统计不同颜色数量；纯色空白画面为 1。
    var distinctColorCount: Int {
        guard pixelCount > 0 else { return 0 }
        var colors = Set<UInt32>()
        let step = max(pixelCount / 40_000, 1)
        for pixel in stride(from: 0, to: pixelCount, by: step) {
            let base = pixel * 4
            let value = UInt32(pixels[base]) << 24
                | UInt32(pixels[base + 1]) << 16
                | UInt32(pixels[base + 2]) << 8
                | UInt32(pixels[base + 3])
            colors.insert(value)
        }
        return colors.count
    }

    /// 两张同尺寸画面的像素差异占比；尺寸不同视为完全不同。
    func differenceRatio(from other: RenderedSnapshot) -> Double {
        guard width == other.width, height == other.height,
              pixels.count == other.pixels.count, pixelCount > 0 else { return 1 }
        var differing = 0
        for pixel in 0..<pixelCount {
            let base = pixel * 4
            if pixels[base] != other.pixels[base]
                || pixels[base + 1] != other.pixels[base + 1]
                || pixels[base + 2] != other.pixels[base + 2]
                || pixels[base + 3] != other.pixels[base + 3] {
                differing += 1
            }
        }
        return Double(differing) / Double(pixelCount)
    }
}

/// SwiftUI 视图的离屏渲染入口（`ImageRenderer`，无需窗口服务器）。
@MainActor
enum GUIRenderer {
    static func snapshot<V: View>(
        _ view: V,
        width: CGFloat,
        height: CGFloat
    ) -> RenderedSnapshot? {
        let renderer = ImageRenderer(content: view.frame(width: width, height: height))
        renderer.scale = 1
        renderer.proposedSize = ProposedViewSize(width: width, height: height)
        guard let image = renderer.cgImage else { return nil }
        return snapshot(from: image)
    }

    private static func snapshot(from image: CGImage) -> RenderedSnapshot? {
        let width = image.width
        let height = image.height
        guard width > 0, height > 0 else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let drew = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drew else { return nil }
        return RenderedSnapshot(width: width, height: height, pixels: pixels)
    }
}

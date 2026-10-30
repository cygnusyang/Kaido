import SwiftUI
import KairoPresentation

/// 画布内的「窗口外还有任务」提示胶囊（D-040 / D-043）。
///
/// 启动窗口锚今天：项目整体在过去、或大量任务落在窗口之外时，画布看起来是空的，
/// 用户会以为任务丢了。提示只说三件事——还有多少条看不见、在窗口哪一侧、
/// 以及一键「适合项目」把它们带回视野。
///
/// 视觉沿用「回到今天」胶囊的语言（`surfaceElevated` 填充 + `separator` 描边 + 小阴影）：
/// 提示本身不能遮挡画布，所以不走 `.alert` / `.sheet` 那类模态形态；
/// 结构固定为「图标徽章 + 说明文字 + 右侧动作按钮」。
struct OffWindowHint: View {
    /// 外溢统计（`GanttSnapshot.offWindow`）；计数为 0 时调用方不应展示本视图。
    let coverage: GanttWindowCoverage
    /// 点击「适合项目」：由调用方决定 dispatch 哪个动作（画布传 `.setFitZoom(true)`）。
    let onFitProject: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            badge
            Text(Self.message(for: coverage))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: onFitProject) {
                Text(Self.fitTitle)
                    .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.accentStrong)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .fill(DesignTokens.accentBase.opacity(0.12))
                    )
            }
            .buttonStyle(.plain)
            .help(Self.fitTitle)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Capsule().fill(DesignTokens.surfaceElevated))
        .overlay(Capsule().stroke(DesignTokens.separator, lineWidth: 1))
        .shadow(radius: 2, y: 1)
    }

    /// 方向徽章：箭头指向条所在的一侧，让「去哪找」在一眼之内成立。
    private var badge: some View {
        Image(systemName: Self.symbol(for: coverage.side))
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesignTokens.accentStrong)
            .frame(width: 18, height: 18)
            .background(Circle().fill(DesignTokens.accentBase.opacity(0.12)))
    }

    /// 「适合项目」复用状态栏的既有词条，避免同一动作出现两种译名。
    private static var fitTitle: String {
        I18n.t("statusbar.zoom.preset.fit", "Fit to project")
    }

    static func symbol(for side: GanttWindowCoverage.Side) -> String {
        switch side {
        case .before: return "arrow.left"
        case .after: return "arrow.right"
        case .both: return "arrow.left.arrow.right"
        }
    }

    /// 提示文案：按侧别取词条，计数走位置参数（中英语序不同，占位符一律 `%1$ld`）。
    static func message(for coverage: GanttWindowCoverage) -> String {
        let count = coverage.offWindowCount
        switch coverage.side {
        case .before:
            return I18n.t(
                "timeline.off_window.before",
                "%1$ld tasks are before the visible window",
                count
            )
        case .after:
            return I18n.t(
                "timeline.off_window.after",
                "%1$ld tasks are after the visible window",
                count
            )
        case .both:
            return I18n.t(
                "timeline.off_window.both",
                "%1$ld tasks are outside the visible window",
                count
            )
        }
    }
}

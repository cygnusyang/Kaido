import SwiftUI
import KaidoPresentation

/// 画布右上角的「离开当前位置」入口（D-054）。
///
/// 用户口径（2026-10-30）：「在任何时候，只要当前的窗口不在任务规划的区间内，
/// 在那一行上面就应该有一个按钮，可以快速回到任务排期的周期里面。」
///
/// **位置独立于滚动内容**：入口挂在滚动容器的 `.overlay` 上，不挂在画布内容里——
/// v1.4.0 的两个入口都在内容坐标系（提示贴内容顶部、今天胶囊在内容里垂直居中），
/// 纵向一滚就离开视口。这是 D-054 的失效面：不是信号缺失，是入口画在了视口之外。
///
/// 视觉沿用「回到今天」胶囊的语言（`surfaceElevated` 填充 + `separator` 描边 +
/// 小阴影），结构固定为「图标徽章 + 说明文字 + 右侧动作」：
/// - `.offSchedule`：整枚胶囊就是按钮，点哪儿都算（用户的目标动作只有一个）；
/// - `.offWindow`：徽章 + 「窗口外还有 N 条」+ 「适合项目」按钮。
struct TimelineNavigationChip: View {
    /// 呈现层裁定的入口（`GanttSnapshot.navigation`）；nil 时调用方不展示本视图。
    let navigation: GanttNavigation
    /// 外溢统计：`.offWindow` 的文案带条数；其余 case 不读。
    let coverage: GanttWindowCoverage
    /// 可用宽度上限（画布宽 − 边距）：文字按它截断，胶囊不越过画布压到大纲列上。
    let maxWidth: CGFloat
    /// 点击入口：调用方按 `navigation.action` 派发。
    let action: () -> Void

    /// 胶囊高度：与表头、状态栏控件同档，不随文字行数变化。
    private static let height: CGFloat = 24

    var body: some View {
        Group {
            switch navigation {
            case .offSchedule(let side): offScheduleChip(side)
            case .offWindow: offWindowChip
            }
        }
        .frame(maxWidth: max(maxWidth, 0), alignment: .trailing)
        .frame(height: Self.height)
    }

    // MARK: - 两个形态

    /// 排期整体在窗口某一侧：整枚胶囊可点，点完窗口回到排期区间。
    private func offScheduleChip(_ side: OffScheduleSide) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                badge(Self.symbol(for: side))
                Text(Self.returnTitle)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.horizontal, 10)
            .frame(height: Self.height)
            .background(capsule)
        }
        .buttonStyle(.plain)
        .help(Self.returnHelp)
        .accessibilityLabel(Self.returnTitle)
    }

    /// 窗口与排期相交但仍有条在窗口外：沿用 D-040 / D-043 的措辞与「适合项目」动作。
    private var offWindowChip: some View {
        HStack(spacing: 6) {
            badge(Self.symbol(for: coverage.side))
            Text(Self.offWindowMessage(for: coverage))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .lineLimit(1)
                .truncationMode(.tail)
            Button(action: action) {
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
            // 只念按钮动作本身，整句提示已由左侧 Text 读一次。
            .accessibilityLabel(Self.fitTitle)
        }
        .padding(.horizontal, 10)
        .frame(height: Self.height)
        .background(capsule)
    }

    // MARK: - 外观

    /// 方向徽章：箭头指向该去的一侧，让「往哪找」在一眼之内成立。
    private func badge(_ symbol: String) -> some View {
        Image(systemName: symbol)
            // 装饰性：文案已经说清方向，VoiceOver 不必先念一遍 arrow。
            .accessibilityHidden(true)
            .font(.system(size: 10, weight: .semibold))
            .foregroundStyle(DesignTokens.accentStrong)
            .frame(width: 18, height: 18)
            .background(Circle().fill(DesignTokens.accentBase.opacity(0.12)))
    }

    private var capsule: some View {
        Capsule()
            .fill(DesignTokens.surfaceElevated)
            .overlay(Capsule().stroke(DesignTokens.separator, lineWidth: 1))
            .shadow(radius: 2, y: 1)
    }

    // MARK: - 取词

    /// 「回到排期」：两个侧别共用一个词条，方向由徽章箭头表达（箭头语言中立）。
    private static var returnTitle: String {
        I18n.t("action.return_to_schedule", "Return to schedule")
    }

    private static var returnHelp: String {
        I18n.t(
            "action.return_to_schedule.help",
            "Move the window back to the scheduled period"
        )
    }

    /// 「适合项目」复用状态栏的既有词条，避免同一动作出现两种译名。
    private static var fitTitle: String {
        I18n.t("statusbar.zoom.preset.fit", "Fit to project")
    }

    /// 排期所在方向的箭头（`.offSchedule`）：排期在窗口之后 ⇒ 朝右，之前 ⇒ 朝左。
    static func symbol(for side: OffScheduleSide) -> String {
        switch side {
        case .ahead: return "arrow.right"
        case .behind: return "arrow.left"
        }
    }

    /// 外溢方向的箭头（`.offWindow`）：与 D-040 提示同一套语义。
    static func symbol(for side: GanttWindowCoverage.Side) -> String {
        switch side {
        case .before: return "arrow.left"
        case .after: return "arrow.right"
        case .both: return "arrow.left.arrow.right"
        }
    }

    /// 外溢提示文案：按侧别取词条，计数走位置参数（中英语序不同，占位符一律 `%1$ld`）。
    static func offWindowMessage(for coverage: GanttWindowCoverage) -> String {
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

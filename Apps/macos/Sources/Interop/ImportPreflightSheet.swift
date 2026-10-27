import AppKit
import SwiftUI

/// 导入预检 sheet（13-interop-mapping §5 硬要求：**不可跳过、不可默认折叠**）。
///
/// 四块内容自上而下：将导入什么、日历怎么换算、哪些语义变了、依赖明细与其余损失。默认按钮是
/// 「取消」：预检的意义是让人有机会说「不导」，所以回车不落地，Esc 也是取消。
/// 面板形态沿用项目设置 / 基线管理：图标徽章 + 标题 + 说明的头部、分区卡片、右对齐按钮。
struct ImportPreflightSheet: View {
    let preflight: ImportPreflight
    /// 不能落地时的原因（当前项目有未保存修改）；nil = 可以导入。
    let blockedReason: String?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// 复制反馈：按下后短暂变成「已复制」，避免用户以为没生效又点一次。
    @State private var copied = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    scaleSection
                    if let calendar = preflight.calendar {
                        calendarSection(calendar)
                    }
                    // 「已换算」排在日历之后、明细之前：语义变了的条目是用户最需要先看见的一类，
                    // 只剩在下钻明细里等于没提醒（约束降级、自定义域丢弃都在这里）。
                    if !preflight.conversionLosses.isEmpty {
                        lossSection(
                            I18n.t("interop.section.converted", "Converted (semantics changed)"),
                            rows: preflight.conversionLosses
                        )
                    }
                    if !preflight.dependencyLosses.isEmpty {
                        lossSection(
                            I18n.t("interop.section.dependencies", "Dependency details"),
                            rows: preflight.dependencyLosses
                        )
                    }
                    if !preflight.calendarLosses.isEmpty {
                        lossSection(
                            I18n.t("interop.section.calendar_losses", "Calendar items"),
                            rows: preflight.calendarLosses
                        )
                    }
                    lossSection(
                        I18n.t("interop.section.losses", "Lost or downgraded fields"),
                        rows: preflight.losses
                    )
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 620)
        .background(DesignTokens.surfaceBase)
        .onExitCommand(perform: onCancel)
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "square.and.arrow.down")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.accentStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(I18n.t("interop.import.title", "Review before importing"))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("\(preflight.formatName) · \(preflight.formatVersion) · \(preflight.fileName)")
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(preflight.summary)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 将导入什么

    private var scaleSection: some View {
        section(I18n.t("interop.section.scale", "What will be imported")) {
            ForEach(preflight.scale) { row in
                HStack(spacing: 8) {
                    Text(row.title)
                        .font(.system(size: DesignTokens.bodyFontSize))
                        .foregroundStyle(DesignTokens.textPrimary)
                    Spacer(minLength: 0)
                    Text(String(row.value))
                        .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold).monospacedDigit())
                        .foregroundStyle(DesignTokens.textPrimary)
                }
            }
        }
    }

    // MARK: - 日历换算

    private func calendarSection(_ calendar: ImportPreflight.CalendarConversion) -> some View {
        section(I18n.t("interop.section.calendar", "Calendar conversion")) {
            Text(preflight.calendarLine(calendar))
                .font(.system(size: DesignTokens.bodyFontSize))
                .foregroundStyle(DesignTokens.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            if calendar.estimatedAdvanceDays != nil {
                // 偏差是预估值：用警告色而不是错误色，避免看起来像「导入会失败」。
                HStack(spacing: 6) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(DesignTokens.violationWarning)
                    Text(I18n.t(
                        "interop.calendar.estimate_note",
                        "This is an estimate from the longest dependency chain, not a recomputed schedule."
                    ))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                }
            }
        }
    }

    // MARK: - 有损清单

    @ViewBuilder
    private func lossSection(_ title: String, rows: [ImportPreflight.LossRow]) -> some View {
        section(title) {
            if rows.isEmpty {
                Text(I18n.t("interop.losses.none", "Nothing in this group will be lost."))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            } else {
                ForEach(rows) { row in
                    LossRowView(row: row)
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Button(copied
                ? I18n.t("interop.import.copied", "Copied")
                : I18n.t("interop.import.copy", "Copy Report")
            ) {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(preflight.copyText, forType: .string)
                copied = true
            }
            .help(I18n.t("interop.import.copy.help", "Copy the whole report as text, e.g. to send to the other side"))

            if let blockedReason {
                Text(blockedReason)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.violationWarning)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)

            Button(I18n.t("action.cancel", "Cancel"), action: onCancel)
                // 默认按钮是取消：预检的用途是留一次「不导」的机会（13 §5）。
                .keyboardShortcut(.defaultAction)

            Button(I18n.t("interop.import.confirm", "Import"), action: onConfirm)
                .disabled(blockedReason != nil)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 版式

    private func section<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            VStack(alignment: .leading, spacing: 8) {
                content()
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(DesignTokens.surfaceChrome, in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// 一条有损登记：种类徽章 + 字段名 × 计数 + 说明 + 原值样例。
struct LossRowView: View {
    let row: ImportPreflight.LossRow

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(InteropFormats.kindLabel(row.kind))
                    .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                    .foregroundStyle(kindColor)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(kindColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                Text(row.field)
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .medium))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text("× \(row.count)")
                    .font(.system(size: DesignTokens.bodyFontSize).monospacedDigit())
                    .foregroundStyle(DesignTokens.textSecondary)
                Spacer(minLength: 0)
            }
            Text(row.detail)
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            if !row.samples.isEmpty {
                Text(I18n.t("interop.losses.samples", "e.g. %1$@", row.samples.joined(separator: ", ")))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                    .lineLimit(2)
            }
        }
    }

    /// dropped 是「没有了」，用错误色；degraded/converted/derived 只是弱化，用警告色。
    private var kindColor: Color {
        row.kind == .dropped ? DesignTokens.violationError : DesignTokens.violationWarning
    }
}

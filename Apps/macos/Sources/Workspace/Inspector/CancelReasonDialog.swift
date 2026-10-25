import SwiftUI

/// 取消原因的输入口径（v0.16 D）：视图、应用层、会话层共用同一条规则。
///
/// 单一取舍：去首尾空白后为空 = 没填。视图据此就地提示、应用层据此不写库，
/// 避免「视图放过、Store 拒绝」的错位。
enum CancelReasonInput {
    /// 归一后的原因；纯空白返回 `nil`。
    static func normalized(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// 取消任务的原因输入弹层（v0.16 D）。
///
/// 空白原因**不关弹层、不发请求**，就地标红提示；确认后只把归一过的原因交给
/// 调用方（写库与会话校验都发生在应用层）。
struct CancelReasonDialog: View {
    let taskTitle: String
    let onConfirm: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var reason = ""
    @State private var showsEmptyHint = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(DesignTokens.violationWarning)
                Text(I18n.t("inspector.cancel_reason.title", "Cancel task"))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Spacer(minLength: 0)
            }
            Text(I18n.t(
                "inspector.cancel_reason.message",
                "%1$@ will be marked as cancelled and removed from the schedule. A reason is required.",
                taskTitle
            ))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
            .fixedSize(horizontal: false, vertical: true)

            TextField(
                I18n.t("inspector.cancel_reason.placeholder", "Why is this task cancelled?"),
                text: $reason
            )
            .textFieldStyle(.roundedBorder)
            .onSubmit(confirm)

            if showsEmptyHint {
                Label(
                    I18n.t("inspector.cancel_reason.empty", "Please enter a reason for cancelling"),
                    systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.violationError)
            }

            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button(I18n.t("action.cancel", "Cancel")) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(I18n.t("action.confirm_cancel", "Mark Cancelled"), action: confirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
        .frame(width: 380)
        .background(DesignTokens.surfaceBase)
    }

    /// 空白原因就地提示：不清空输入、不关弹层、不回调。
    private func confirm() {
        guard let trimmed = CancelReasonInput.normalized(reason) else {
            showsEmptyHint = true
            return
        }
        onConfirm(trimmed)
    }
}

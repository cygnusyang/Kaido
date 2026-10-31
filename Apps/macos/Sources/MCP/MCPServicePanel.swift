import SwiftUI
import AppKit
import KaidoPresentation

/// MCP 服务面板（App Store 版）：开关、端点与 token、客户端配置片段、授权目录。
///
/// 商店版必须由 app 自己托管 MCP 服务，用户要在这里完成三件事：
/// ① 打开服务并拿到可粘贴的客户端配置；② 复制/重置 token；
/// ③ 授权 MCP 能读写的目录（沙盒下没有全盘权限，必须显式选）。
///
/// 样式与项目设置面板一致：图标徽章 + 标题 + 说明的头部、分区卡片、右对齐底部按钮。
struct MCPServicePanel: View {
    @ObservedObject var service: MCPService
    @ObservedObject var authorization: MCPAuthorizationStore
    let onClose: () -> Void

    /// 刚复制过的条目（按钮上短暂显示「已复制」，避免用户重复点）。
    @State private var copied: String?
    @State private var isChoosingFolder = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 14) {
                serviceSection
                clientSection
                folderSection
            }
            .padding(16)
            Spacer(minLength: 0)
            Divider()
            footer
        }
        .frame(width: 620, height: 680)
        .background(DesignTokens.surfaceBase)
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: true
        ) { result in
            guard case .success(let urls) = result else { return }
            for url in urls {
                let accessing = url.startAccessingSecurityScopedResource()
                authorization.authorize(url)
                if accessing { url.stopAccessingSecurityScopedResource() }
            }
        }
    }

    // MARK: - 头部

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "point.3.connected.trianglepath.dotted")
                .font(.system(size: 16))
                .foregroundStyle(DesignTokens.accentStrong)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(I18n.t("panel.mcp.title", "MCP Service"))
                    .font(.system(size: DesignTokens.bodyFontSize, weight: .semibold))
                    .foregroundStyle(DesignTokens.textPrimary)
                Text(I18n.t(
                    "panel.mcp.subtitle",
                    "Let an AI client work on your projects. The service runs inside Kaido and can only touch the folders you authorize below."
                ))
                .font(.system(size: DesignTokens.captionFontSize))
                .foregroundStyle(DesignTokens.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    // MARK: - 服务

    private var serviceSection: some View {
        section(I18n.t("panel.mcp.section.service", "Service")) {
            Toggle(I18n.t("panel.mcp.enable", "Run MCP service"), isOn: $service.isEnabled)
                .toggleStyle(.switch)
            HStack(spacing: 6) {
                Text(statusText)
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(statusIsProblem ? DesignTokens.violationWarning : DesignTokens.textSecondary)
                if let endpoint = service.endpoint {
                    Text(endpoint)
                        .font(.system(size: DesignTokens.captionFontSize, design: .monospaced))
                        .foregroundStyle(DesignTokens.textSecondary)
                        .textSelection(.enabled)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 8) {
                Text(I18n.t("panel.mcp.token", "Access token"))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
                Text(maskedToken)
                    .font(.system(size: DesignTokens.captionFontSize, design: .monospaced))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Button(copied == "token"
                       ? I18n.t("panel.mcp.copied", "Copied")
                       : I18n.t("panel.mcp.copy_token", "Copy")) {
                    copy(service.token, tag: "token")
                }
                Button(I18n.t("panel.mcp.regenerate", "Reset")) {
                    service.regenerateToken()
                }
            }
        }
    }

    // MARK: - 客户端配置

    private var clientSection: some View {
        section(I18n.t("panel.mcp.section.client", "Client configuration")) {
            Text(I18n.t(
                "panel.mcp.client.caption",
                "Paste this into your client's MCP settings (Claude Desktop, Claude Code, Cursor). Port is assigned per launch, so re-copy after restarting Kaido."
            ))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
            ScrollView {
                Text(service.clientConfiguration)
                    .font(.system(size: DesignTokens.captionFontSize, design: .monospaced))
                    .foregroundStyle(DesignTokens.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .frame(height: 108)
            .background(DesignTokens.surfaceChrome)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            HStack {
                Spacer(minLength: 0)
                Button(copied == "config"
                       ? I18n.t("panel.mcp.copied", "Copied")
                       : I18n.t("panel.mcp.copy_config", "Copy configuration")) {
                    copy(service.clientConfiguration, tag: "config")
                }
                .disabled(!service.status.isRunning)
            }
        }
    }

    // MARK: - 授权目录

    private var folderSection: some View {
        section(I18n.t("panel.mcp.section.folders", "Authorized folders")) {
            Text(I18n.t(
                "panel.mcp.folders.caption",
                "The sandbox blocks everything else. Projects outside these folders cannot be opened or saved by an AI client."
            ))
            .font(.system(size: DesignTokens.captionFontSize))
            .foregroundStyle(DesignTokens.textSecondary)
            if authorization.roots.isEmpty {
                Text(I18n.t("panel.mcp.folders.empty", "No folder authorized yet."))
                    .font(.system(size: DesignTokens.captionFontSize))
                    .foregroundStyle(DesignTokens.textSecondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(authorization.roots) { root in
                            HStack(spacing: 8) {
                                Image(systemName: "folder")
                                    .foregroundStyle(DesignTokens.textSecondary)
                                Text(root.url.path)
                                    .font(.system(size: DesignTokens.captionFontSize, design: .monospaced))
                                    .foregroundStyle(DesignTokens.textPrimary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 0)
                                Button(I18n.t("panel.mcp.folders.remove", "Remove")) {
                                    authorization.revoke(root.id)
                                }
                                .buttonStyle(.link)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 92)
            }
            HStack {
                Spacer(minLength: 0)
                Button(I18n.t("panel.mcp.folders.add", "Add Folder…")) {
                    isChoosingFolder = true
                }
            }
        }
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer(minLength: 0)
            Button(I18n.t("panel.mcp.done", "Done")) { onClose() }
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - 片段

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: DesignTokens.captionFontSize, weight: .semibold))
                .foregroundStyle(DesignTokens.textSecondary)
            content()
        }
    }

    private var statusText: String {
        switch service.status {
        case .stopped:
            return I18n.t("panel.mcp.status.stopped", "Stopped")
        case .starting:
            return I18n.t("panel.mcp.status.starting", "Starting…")
        case .running:
            return I18n.t("panel.mcp.status.running", "Running at")
        case .failed(let message):
            return I18n.t("panel.mcp.status.failed", "Failed: %1$@", message)
        }
    }

    private var statusIsProblem: Bool {
        if case .failed = service.status { return true }
        return false
    }

    private var maskedToken: String {
        let token = service.token
        guard token.count > 8 else { return token }
        return String(token.prefix(4)) + "••••" + String(token.suffix(4))
    }

    private func copy(_ text: String, tag: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copied = tag
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copied == tag { copied = nil }
        }
    }
}

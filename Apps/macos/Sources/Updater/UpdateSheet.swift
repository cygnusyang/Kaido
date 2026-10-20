// UpdateSheet.swift —— 更新面板（8 态渲染 + 安装确认纪律）。
//
// 纪律（沿 COFFER 裁定）：安装唯一入口为 .downloaded 态确认弹窗——
// 「退出 + 替换二进制」动作单点化确认；.installing 态放开交互关闭
//（关闭即走「关面板 → 0.5s → terminate」序列）；检查失败绝不静默归
// 「已是最新」。

import SwiftUI
import KairoUpdater

/// 更新面板（由「检查更新…」菜单触发挂载）。
struct UpdateSheet: View {
    @ObservedObject var updater: UpdaterManager
    /// 关闭请求（.installing 确认后由本面板发起，交宿主执行退出序列）。
    let onRequestClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            switch updater.state {
            case .idle, .checking:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在检查更新…")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            case .upToDate:
                VStack(alignment: .leading, spacing: 10) {
                    Text("已是最新版本")
                    Button("好") { updater.dismiss(); onRequestClose() }
                }
            case .updateAvailable(let info):
                updateAvailableView(info)
            case .downloading(let progress):
                VStack(alignment: .leading, spacing: 10) {
                    Text("正在下载更新…（\(Int(progress * 100))%）")
                    ProgressView(value: progress)
                }
            case .downloaded:
                downloadedConfirmView
            case .installing:
                HStack(spacing: 10) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在安装，应用即将退出并自动重启…")
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 24)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 10) {
                    Text(message)
                        .foregroundStyle(.red)
                    HStack {
                        Button("重试") { Task { await updater.check() } }
                        Button("关闭") { updater.dismiss(); onRequestClose() }
                    }
                }
            }
        }
        .padding(20)
        .frame(width: 360)
    }

    /// 发现可更新：版本信息 + 下载 / 跳过。
    @ViewBuilder
    private func updateAvailableView(_ info: UpdateInfo) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("发现新版本 \(info.version)")
                .font(.headline)
            if let notes = info.notes, !notes.isEmpty {
                Text(notes)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text("下载并验证后需要退出应用完成安装。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("下载更新") { Task { await updater.download() } }
                    .keyboardShortcut(.defaultAction)
                if !info.securityCritical {
                    Button("跳过此版本") { updater.skipCurrentUpdate(); onRequestClose() }
                }
            }
        }
    }

    /// 下载完成确认：唯一安装入口（退出 + 替换二进制）。
    private var downloadedConfirmView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("更新已下载并通过验证")
                .font(.headline)
            Text("将退出应用、替换二进制并自动重启。")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack {
                Button("退出并安装") {
                    Task {
                        await updater.install()
                        // install() 成功路径不返回状态迁移（保持 .installing）；
                        // 失败会转 .failed，仅在 still installing 时执行退出序列。
                        if case .installing = updater.state {
                            try? await Task.sleep(nanoseconds: 500_000_000)
                            NSApp.terminate(nil)
                        }
                    }
                }
                    .keyboardShortcut(.defaultAction)
                Button("取消") { updater.dismiss(); onRequestClose() }
            }
        }
    }
}

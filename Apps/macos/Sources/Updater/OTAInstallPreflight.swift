// OTAInstallPreflight.swift —— 「退出并安装」之前的未保存收口（issue #17）。
//
// 旧实现的病根：未保存裁决留在 AppDelegate.applicationShouldTerminate 的
// NSAlert.runModal() 里，而替换脚本只肯等 60s（InstallerScript.replacement）。
// 用户没作答 / 选取消 / 保存失败 → 进程不退 → 脚本写 app_not_quitting 放弃，
// 面板停在「正在安装更新」且没有任何按钮。
//
// 现在裁决前移到安装之前：先把脏状态同步落盘，失败就**不启动脚本**，由面板
// .failed 说明原因并给出重试/关闭。于是进入 .installing 时
// hasUnsavedChanges == false，退出守卫不必再介入这条非交互路径。

import Foundation
import KaidoUpdater

/// 安装前的落盘收口。
@MainActor
enum OTAInstallPreflight {
    /// 把未保存修改落盘。
    ///
    /// - Returns: nil = 就绪（可以启动替换脚本）；否则是可展示的失败
    ///   （.installSaveFailed），调用方不得启动脚本。
    static func run(store: WorkspaceStore) -> UpdaterFailure? {
        guard store.hasUnsavedChanges else { return nil }
        // 无保存路径时无法静默落盘：明说不装，而不是把人推回另存为模态。
        guard store.projectURL != nil else {
            return UpdaterFailure(
                code: .installSaveFailed,
                parameters: [
                    "detail": I18n.t(
                        "update.error.install_save_no_location",
                        "the project has not been saved to disk yet; save it first and try again"),
                ])
        }
        store.save()
        guard store.saveState != .failed, !store.hasUnsavedChanges else {
            // 先取走错误文本：面板已经说明原因，视图不该再补弹同一个保存失败。
            let message = store.alertMessage
                ?? I18n.t("update.error.unknown_detail", "unknown cause")
            store.alertMessage = nil
            return UpdaterFailure(code: .installSaveFailed, parameters: ["detail": message])
        }
        return nil
    }
}

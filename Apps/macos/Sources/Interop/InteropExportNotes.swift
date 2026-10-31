import Foundation
import KaidoInterop

/// 导出旁注文件（13-interop-mapping §5 / 14 §P1）。
///
/// 为什么不写进对方的 Notes：那会污染对方原文，回导时又混进任务备注，两头都不干净。
/// 旁注是**与主文件同目录的第二个文件**，只为人读：回导前用它比对「哪些信息不会回来」。
enum InteropExportNotes {
    /// 旁注文件名：与主文件同名，扩展名换成 `kaido-export-notes.md`。
    ///
    /// `Plan.xml` → `Plan.kaido-export-notes.md`：同一份导出的两个文件在 Finder 里相邻，
    /// 复制走一个不会漏掉另一个。
    static func fileName(for exportedURL: URL) -> String {
        exportedURL.deletingPathExtension().lastPathComponent + ".kaido-export-notes.md"
    }

    /// 渲染旁注正文。
    ///
    /// - Parameters:
    ///   - projectTitle: 导出时的项目名（回导后用于确认是哪一份计划）。
    ///   - formatID: 目标格式 id（旁注里写人可读的格式名）。
    ///   - attachedFileName: 随附的主文件名。
    ///   - ledger: 导出侧有损登记（写出端合并后的那一份）。
    ///   - exportedAt: 导出时刻。
    ///   - appVersion: Kaido 版本号（写出端与界面版本同源）。
    static func markdown(
        projectTitle: String,
        formatID: String,
        attachedFileName: String,
        ledger: FidelityLedger,
        exportedAt: Date,
        appVersion: String
    ) -> String {
        var lines: [String] = []
        lines.append("# " + I18n.t("interop.notes.title", "Kaido export notes"))
        lines.append("")
        lines.append(header(projectTitle: projectTitle, formatID: formatID, attachedFileName: attachedFileName, exportedAt: exportedAt, appVersion: appVersion))
        lines.append("")
        lines.append("> " + I18n.t(
            "interop.notes.one_way",
            "This export is a one-way snapshot: re-importing the attached file will not restore the items below."
        ))
        lines.append("")
        lines.append("## " + I18n.t("interop.notes.section.lost", "What the exported file cannot carry"))
        lines.append("")
        if ledger.isEmpty {
            lines.append(I18n.t("interop.notes.empty", "Nothing was lost: every field in this project has a place in the target format."))
            lines.append("")
        } else {
            for kind in FidelityLedger.Kind.allCases {
                let entries = ledger.entries.filter { $0.kind == kind }
                guard !entries.isEmpty else { continue }
                lines.append("### " + InteropFormats.kindLabel(kind))
                lines.append("")
                for entry in entries {
                    lines.append("- **\(entry.field)** × \(entry.count) — \(entry.detail)")
                    if !entry.samples.isEmpty {
                        lines.append("  - " + I18n.t("interop.notes.samples", "Samples") + ": "
                            + entry.samples.joined(separator: ", "))
                    }
                }
                lines.append("")
            }
        }
        lines.append("## " + I18n.t("interop.notes.section.checklist", "Before re-importing"))
        lines.append("")
        lines.append("- " + I18n.t(
            "interop.notes.check.cancel_reason",
            "Cancelled tasks come back as plain tasks: their cancel reasons live only in this file."
        ))
        lines.append("- " + I18n.t(
            "interop.notes.check.baseline_color",
            "Baseline colors and names are reassigned on import; the numbers above say how many baselines were written."
        ))
        lines.append("- " + I18n.t(
            "interop.notes.check.soft_constraint",
            "Time limits exported as hard constraints will move tasks in the other tool; in Kaido they only raise violations."
        ))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func header(
        projectTitle: String,
        formatID: String,
        attachedFileName: String,
        exportedAt: Date,
        appVersion: String
    ) -> String {
        let rows = [
            I18n.t("interop.notes.header.project", "Project") + ": " + projectTitle,
            I18n.t("interop.notes.header.exported_at", "Exported at") + ": " + Display.isoDate(exportedAt) + " " + Display.time(exportedAt),
            I18n.t("interop.notes.header.kaido_version", "Kaido version") + ": " + appVersion,
            I18n.t("interop.notes.header.format", "Format") + ": " + InteropFormats.displayName(for: formatID)
                + " (" + InteropFormats.formatVersionText(formatID: formatID) + ")",
            I18n.t("interop.notes.header.attached", "Attached file") + ": " + attachedFileName,
        ]
        return rows.map { "- " + $0 }.joined(separator: "\n")
    }
}

import Foundation
import KairoInterop

/// MS Project XML（MSPDI）适配器（docs/features/13-interop-mapping.md）。
///
/// 边界（评审硬门槛）：
/// - 只 `import KairoInterop`，**不 import KairoCore**：所有「工作日 ↔ 日历天」换算在
///   `KairoBridge`，本 target 只做 XML ↔ IR；
/// - 不 import 任何别的适配器，删掉别的 target 仍能编译；
/// - 版本前置：`SaveVersion` 不在支持范围内一律拒绝。
///
/// 本阶段（P0）只有读；写（P1）落在此 target 内，届时把 `capabilities.canWrite` 打开。
public struct MSPDIAdapter: FormatAdapter {
    /// 稳定的格式标识。
    public static let formatID = "mspdi"

    public init() {}

    public var id: String { Self.formatID }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(
            canRead: true,
            canWrite: false,
            canPreflight: true,
            supportsBaselines: true,
            supportsCalendars: true,
            supportsCustomFields: true
        )
    }

    public var supportedVersions: [Int] { MSPDIReader.supportedSaveVersions }

    /// 轻量识别：只看前 4 KB 里的根元素与命名空间，不解整份文档。
    public func sniff(_ data: Data) -> Bool {
        let probe = data.prefix(4_096)
        guard let text = String(data: probe, encoding: .utf8)
            ?? String(data: probe, encoding: .isoLatin1) else { return false }
        return text.contains("<Project") && text.contains(MSPDIReader.namespace)
    }

    public func read(_ data: Data) throws -> InteropDocument {
        try MSPDIReader().read(data).document
    }

    public func write(_ document: InteropDocument) throws -> Data {
        throw InteropError.operationNotSupported("MSPDI 写出（P1 阶段实现）")
    }

    /// 预检：版本号 + 规模 + 有损清单，不产出 Kairo 项目。
    public func preflight(_ data: Data) throws -> PreflightReport {
        let (document, saveVersion) = try MSPDIReader().read(data)
        let groups = document.tasks.filter { $0.kind == .group }.count
        let milestones = document.tasks.filter { $0.kind == .milestone }.count
        let summary = "\(document.tasks.count) 任务（\(groups) 汇总 / \(milestones) 里程碑）/ "
            + "\(document.calendars.count) 日历 / \(document.baselines.count) 基线 / "
            + "\(document.assignments.count) 分配"
        return PreflightReport(
            formatID: id,
            formatVersion: "SaveVersion \(saveVersion)",
            summary: summary,
            ledger: document.ledger
        )
    }
}

import Foundation
import KairoInterop

/// OmniPlan `.oplx` 适配器（docs/features/11-interop-omniplan.md、14-interop-architecture.md）。
///
/// 边界（评审硬门槛）：
/// - 只 `import KairoInterop`：**不 import InteropMSPDI、不 import KairoCore**，
///   删掉任一通道本 target 仍能编译；
/// - 容器与 XML 解析各自持有（`ZipArchive` / `OmniPlanXML`），不向别的通道借代码；
/// - 版本前置：`file-format-version` 不是 3 一律抛 `unsupportedFormatVersion`。
///
/// 本期只实现读（P2）。写（P3）要补基线 scenario、日历、分配与最小容器落盘，
/// 在补齐之前 `canWrite == false`、`write` 明确抛 `operationNotSupported`——不假装能写。
public struct OmniPlanAdapter: FormatAdapter {
    /// 稳定的格式标识。
    public static let formatID = "omniplan"

    public init() {}

    public var id: String { Self.formatID }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(
            canRead: true,
            canWrite: false,
            canPreflight: true,
            supportsBaselines: true,
            supportsCalendars: true,
            supportsCustomFields: false
        )
    }

    public var supportedVersions: [Int] { OmniPlanReader.supportedFormatVersions }

    /// 轻量识别：只看 zip 头与中央目录里的成员名，不解压。
    ///
    /// `.oplx` 与别的 zip 的区别就在「必须同时有 __TOC.xml 与 Actual.xml」这两条成员记录，
    /// 成员名以明文存在本地头与中央目录里，扫字节即可。
    public func sniff(_ data: Data) -> Bool {
        let bytes = [UInt8](data)
        guard bytes.count >= 4, bytes[0] == 0x50, bytes[1] == 0x4B, bytes[2] == 0x03, bytes[3] == 0x04 else {
            return false
        }
        return bytes.containsASCII(OmniPlanReader.tocMember)
            && bytes.containsASCII(OmniPlanReader.defaultScenarioMember)
    }

    public func read(_ data: Data) throws -> InteropDocument {
        try OmniPlanReader().read(data).document
    }

    /// 写出：P3 才做（11 §7 已验证最小容器可行，但基线/日历/分配尚未补齐）。
    public func write(_ document: InteropDocument) throws -> Data {
        throw InteropError.operationNotSupported("OmniPlan .oplx 写（v1.2 只做读）")
    }

    /// 预检：版本号 + 规模 + 有损清单，不产出 Kairo 项目。
    public func preflight(_ data: Data) throws -> PreflightReport {
        let result = try OmniPlanReader().read(data)
        let document = result.document
        let groups = document.tasks.filter { $0.kind == .group }.count
        let milestones = document.tasks.filter { $0.kind == .milestone }.count
        let summary = "\(document.tasks.count) 任务（\(groups) 汇总 / \(milestones) 里程碑）/ "
            + "\(document.resources.count) 资源 / \(document.assignments.count) 分配 / "
            + "\(document.tasks.flatMap { $0.dependencies }.count) 相关性 / "
            + "\(document.calendars.count) 日历"
        return PreflightReport(
            formatID: id,
            formatVersion: "file-format-version \(result.formatVersion)",
            summary: summary,
            ledger: document.ledger
        )
    }
}

private extension Array where Element == UInt8 {
    /// 是否包含给定 UTF-8 字节串（朴素匹配；成员名很短，够用）。
    func containsASCII(_ needle: String) -> Bool {
        let pattern = [UInt8](needle.utf8)
        guard !pattern.isEmpty, count >= pattern.count else { return false }
        for start in 0...(count - pattern.count) where self[start] == pattern[0] {
            if self[start..<(start + pattern.count)].elementsEqual(pattern) { return true }
        }
        return false
    }
}

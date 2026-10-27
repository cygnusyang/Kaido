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
/// P1 起同时支持写出（`MSPDIWriter`）：写只在 XML ↔ IR 之间转换，日期按 IR 原样落盘。
public struct MSPDIAdapter: FormatAdapter {
    /// 稳定的格式标识。
    public static let formatID = "mspdi"

    public init() {}

    public var id: String { Self.formatID }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(
            canRead: true,
            canWrite: true,
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

    /// - Throws: 只会抛 `InteropError`（版本闸门或 `malformedDocument`）；
    ///   底层解析错误由 `InteropError.normalized` 归一，平台差异不外泄。
    public func read(_ data: Data) throws -> InteropDocument {
        try InteropError.normalized { try MSPDIReader().read(data).document }
    }

    /// 写出 IR；丢弃导出侧登记（只需要字节时用它）。
    ///
    /// 需要「哪些 Kairo 独有信息带不走」时改用 `export(_:)`，把登记渲染成导出旁注文件。
    public func write(_ document: InteropDocument) throws -> Data {
        try export(document).data
    }

    /// 写出 IR 并返回导出侧有损登记（13-mapping §5 的导出旁注来源）。
    ///
    /// - Parameter document: 供应商无关的计划文档。
    /// - Throws: 当前实现不会失败；保留 `throws` 以便与 `FormatAdapter` 契约同形。
    public func export(_ document: InteropDocument) throws -> MSPDIExport {
        MSPDIWriter().write(document)
    }

    /// 预检：版本号 + 规模 + 有损清单，不产出 Kairo 项目。
    ///
    /// 有损清单走 `PreflightReport.assembling`：IR 侧登记 + `KairoBridge` 追加的登记，
    /// 与真正导入时产出的台账同源（约束降级、自定义域丢弃都在里面）。
    public func preflight(_ data: Data) throws -> PreflightReport {
        let (document, saveVersion) = try InteropError.normalized { try MSPDIReader().read(data) }
        return PreflightReport.assembling(
            formatID: id,
            formatVersion: "SaveVersion \(saveVersion)",
            document: document
        )
    }
}

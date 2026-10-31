import Foundation
import KaidoInterop

/// OmniPlan `.oplx` 适配器（docs/features/11-interop-omniplan.md、14-interop-architecture.md）。
///
/// 边界（评审硬门槛）：
/// - 只 `import KaidoInterop`：**不 import InteropMSPDI、不 import KaidoCore**，
///   删掉任一通道本 target 仍能编译；
/// - 容器与 XML 解析各自持有（`ZipArchive` / `OmniPlanXML`），不向别的通道借代码；
/// - 版本前置：`file-format-version` 不是 3 一律抛 `unsupportedFormatVersion`。
///
/// 读写都实现（P2 读 + P3 写）：写出端是 `OmniPlanWriter`，容器按 11 §7 实测的最小必需集
/// 落盘（`__TOC.xml` + `Actual.xml`）。写不回去的 Kaido 独有信息登记在 `OmniPlanExport.ledger`。
public struct OmniPlanAdapter: FormatAdapter {
    /// 稳定的格式标识。
    public static let formatID = "omniplan"

    public init() {}

    public var id: String { Self.formatID }

    public var capabilities: AdapterCapabilities {
        AdapterCapabilities(
            canRead: true,
            canWrite: true,
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

    /// - Throws: 只会抛 `InteropError`（版本闸门或 `malformedDocument`）；
    ///   zip / XML 底层错误由 `InteropError.normalized` 归一，平台差异不外泄。
    public func read(_ data: Data) throws -> InteropDocument {
        try InteropError.normalized { try OmniPlanReader().read(data).document }
    }

    /// 写出 IR；丢弃导出侧登记（只需要字节时用它）。
    ///
    /// 需要「哪些 Kaido 独有信息带不走」时改用 `export(_:)`，把登记渲染成导出旁注文件。
    public func write(_ document: InteropDocument) throws -> Data {
        try export(document).data
    }

    /// 写出 IR 并返回导出侧有损登记（13-mapping §5 的导出旁注来源）。
    ///
    /// - Parameter document: 供应商无关的计划文档。
    /// - Throws: `InteropError.operationNotSupported`（内容超出单卷 zip 上限）。
    public func export(_ document: InteropDocument) throws -> OmniPlanExport {
        try OmniPlanWriter().write(document)
    }

    /// 预检：版本号 + 规模 + **完整**有损台账，不产出 Kaido 项目。
    ///
    /// 台账交给 `PreflightReport.assembling` 装配：适配器只看得见「来源 → IR」的损失，
    /// 桥接层追加的项（约束降级、自定义域丢弃等）只有 `KaidoBridge` 算得出来，
    /// 自己拼一份会少报（真实样本 IR 侧 2 条、桥接追加 8 条）。
    /// 版本号仍用本通道的口径（`file-format-version 3`），默认实现的「supported: 3」读不出实际版本。
    public func preflight(_ data: Data) throws -> PreflightReport {
        let result = try InteropError.normalized { try OmniPlanReader().read(data) }
        return PreflightReport.assembling(
            formatID: id,
            formatVersion: "file-format-version \(result.formatVersion)",
            document: result.document
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

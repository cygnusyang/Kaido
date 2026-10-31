import Foundation
import UniformTypeIdentifiers
import ZenoInterop
import InteropMSPDI
import InteropOmniPlan

/// 应用侧互操作格式表（14-interop-architecture §2）。
///
/// UI 只认适配器声明的 capability，不认识任何格式的解析细节：新增通道时只在这里注册一次，
/// 导入 / 导出流程本身不改。两个适配器同处应用层是「应用怎么组装通道」的选择——
/// 适配器 target 之间仍然互不 import（硬规则 1）。
enum InteropFormats {
    /// 已注册通道；数组顺序即内容识别的优先级。
    static func registry() -> AdapterRegistry {
        AdapterRegistry(adapters: [MSPDIAdapter(), OmniPlanAdapter()])
    }

    /// 格式显示名（预检标题、导出提示、旁注头都用它，不各写一份文案）。
    static func displayName(for formatID: String) -> String {
        switch formatID {
        case MSPDIAdapter.formatID:
            return I18n.t("interop.format.mspdi", "MS Project XML")
        case OmniPlanAdapter.formatID:
            return I18n.t("interop.format.omniplan", "OmniPlan")
        default:
            return formatID
        }
    }

    /// 导入面板的扩展名过滤（xml / oplx）。
    ///
    /// 扩展名只决定面板能选到哪些文件；**选哪个通道仍以内容为准**（见 `importAdapter`）——
    /// 把 .xml 改名的 .oplx 不该被当成 MSPDI 硬解一遍。
    static let importableExtensions = ["xml", "oplx"]

    /// `.oplx` 的内容类型：未注册正式 UTType，按扩展名取动态类型，取不到就按 zip 容器处理
    /// （它本来就是 zip）。导入面板与导出保存面板共用这一处，避免两处写法漂移。
    static var oplxContentType: UTType {
        UTType(filenameExtension: "oplx") ?? .zip
    }

    /// 导入面板允许的内容类型。
    static var importableContentTypes: [UTType] {
        [.xml, oplxContentType]
    }

    /// 扩展名 → 通道 id（只是提示，不是判据）。
    static func adapterID(forExtension pathExtension: String) -> String? {
        switch pathExtension.lowercased() {
        case "xml": return MSPDIAdapter.formatID
        case "oplx": return OmniPlanAdapter.formatID
        default: return nil
        }
    }

    /// 选导入通道：先按内容 sniff，再退回扩展名提示。
    ///
    /// 顺序刻意如此：内容识别成功就以内容为准（扩展名可以骗人）；只有内容认不出来时才用
    /// 扩展名收敛到一个通道，让那个通道自己的版本闸门给出**具体**错误（「不支持的文件版本 99」），
    /// 而不是笼统的「无法识别的格式」。
    static func importAdapter(
        for url: URL,
        data: Data,
        registry: AdapterRegistry
    ) throws -> any FormatAdapter {
        if let sniffed = registry.adapter(sniffing: data) { return sniffed }
        if let id = adapterID(forExtension: url.pathExtension),
           let hinted = registry.adapter(id: id) {
            return hinted
        }
        throw InteropError.malformedDocument(
            I18n.t(
                "interop.error.unknown_format",
                "Not a plan file Zeno can read: expected MS Project XML or an OmniPlan .oplx package."
            )
        )
    }

    /// 有损登记的种类标签：预检清单的分组与导出旁注的小标题共用同一份文案。
    static func kindLabel(_ kind: FidelityLedger.Kind) -> String {
        switch kind {
        case .dropped: return I18n.t("interop.kind.dropped", "dropped")
        case .degraded: return I18n.t("interop.kind.degraded", "degraded")
        case .converted: return I18n.t("interop.kind.converted", "converted")
        case .derived: return I18n.t("interop.kind.derived", "derived")
        }
    }

    /// 某通道当前能否写出（菜单置灰判据，不写死格式名）。
    static func canWrite(formatID: String, registry: AdapterRegistry = registry()) -> Bool {
        registry.adapter(id: formatID)?.capabilities.canWrite ?? false
    }

    /// 通道声明的最大受支持版本，用于旁注头写「formatVersion」。
    ///
    /// 取适配器的 `supportedVersions` 而不是另抄一个数字：格式版本属于适配器，
    /// 应用层再抄一份就多了一处会漂移的常量。版本字段名随格式不同（MSPDI 是 SaveVersion，
    /// .oplx 是 file-format-version），所以标签也在这里按通道给。
    static func formatVersionText(formatID: String, registry: AdapterRegistry = registry()) -> String {
        guard let versions = registry.adapter(id: formatID)?.supportedVersions,
              let latest = versions.max() else {
            return I18n.t("interop.format_version.unknown", "unknown")
        }
        switch formatID {
        case MSPDIAdapter.formatID: return "SaveVersion \(latest)"
        case OmniPlanAdapter.formatID: return "file-format-version \(latest)"
        default: return String(latest)
        }
    }
}

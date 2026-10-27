import Foundation

/// 适配器能力声明：UI / CLI / MCP 只认这套布尔值，不认具体格式（14 §2）。
///
/// 能力是**声明**，不是承诺：真正的判据是 `AdapterConformanceSuite`。
public struct AdapterCapabilities: Sendable, Equatable {
    /// 能否读入。
    public var canRead: Bool
    /// 能否写出。
    public var canWrite: Bool
    /// 能否在写之前做预检（版本闸门 + 有损清单）。
    public var canPreflight: Bool
    /// 是否支持基线。
    public var supportsBaselines: Bool
    /// 是否支持多个日历（含例外日）。
    public var supportsCalendars: Bool
    /// 是否支持自定义域。
    public var supportsCustomFields: Bool

    public init(
        canRead: Bool = true,
        canWrite: Bool = false,
        canPreflight: Bool = true,
        supportsBaselines: Bool = false,
        supportsCalendars: Bool = false,
        supportsCustomFields: Bool = false
    ) {
        self.canRead = canRead
        self.canWrite = canWrite
        self.canPreflight = canPreflight
        self.supportsBaselines = supportsBaselines
        self.supportsCalendars = supportsCalendars
        self.supportsCustomFields = supportsCustomFields
    }
}

/// 互操作错误：**一个适配器能失败的只有这几种**，调用方按 case 分派即可。
///
/// 原则同 `.kairo`：版本前置、不猜（硬规则 3）。读到未知版本必须明确拒绝，
/// 不允许「best-effort 解析一部分然后看起来成功」。
public enum InteropError: Error, Equatable, CustomStringConvertible {
    /// 来源格式版本不受支持；`supported` 用于在提示里列出可接受范围。
    case unsupportedFormatVersion(version: Int, supported: [Int])
    /// 文件结构不符合该格式（XML 损坏、命名空间不对、必填元素缺失等）。
    case malformedDocument(String)
    /// 适配器不支持该操作（如 P0 阶段只有读，没有写）。
    case operationNotSupported(String)

    public var description: String {
        switch self {
        case .unsupportedFormatVersion(let version, let supported):
            let range = supported.map(String.init).joined(separator: "、")
            return "不支持的文件版本 \(version)（本适配器支持：\(range)）：请用受支持的版本另存后再试"
        case .malformedDocument(let reason):
            return "文件结构不合法：\(reason)"
        case .operationNotSupported(let operation):
            return "当前版本不支持该操作：\(operation)"
        }
    }
}

/// 预检报告（13-mapping §5）：导入前给用户看的**不可跳过**清单。
///
/// 只描述「会发生什么」，不做决策；「继续 / 取消」由界面层处理。
public struct PreflightReport: Sendable, Equatable {
    /// 适配器 id。
    public var formatID: String
    /// 来源格式版本（人可读，如 `SaveVersion 14`）。
    public var formatVersion: String
    /// 一句话结论（如「可导入：187 任务 / 3 日历 / 4 基线」）。
    public var summary: String
    /// 适配器层（来源 → IR）的有损登记。
    public var irLedger: FidelityLedger
    /// 桥接层（IR → Kairo）追加的有损登记。
    public var bridgeLedger: FidelityLedger

    /// 完整有损台账：`irLedger` 与 `bridgeLedger` 的合并，**渲染清单只认这一份**。
    ///
    /// 只报 IR 侧登记会让用户看不见「硬约束降级 / 自定义域丢弃」这类只在桥接时才发生的损失
    /// （真实样本 187 任务：IR 侧 2 条、桥接追加 8 条）。需要分辨出处时用 `irLedger` / `bridgeLedger`。
    public var ledger: FidelityLedger { irLedger.merging(bridgeLedger) }

    public init(
        formatID: String,
        formatVersion: String,
        summary: String,
        irLedger: FidelityLedger,
        bridgeLedger: FidelityLedger = FidelityLedger()
    ) {
        self.formatID = formatID
        self.formatVersion = formatVersion
        self.summary = summary
        self.irLedger = irLedger
        self.bridgeLedger = bridgeLedger
    }

    /// 兼容旧调用：单份 `ledger` 按适配器层登记解释，`ledger` 的结果与传入值相同。
    ///
    /// 适配器若走 `FormatAdapter` 的默认预检或 `assembling(...)`，拿到的就是合并后的完整台账；
    /// 该入口只为「已有自己装配逻辑、只产 IR 侧登记」的适配器保留编译兼容。
    public init(formatID: String, formatVersion: String, summary: String, ledger: FidelityLedger) {
        self.init(
            formatID: formatID,
            formatVersion: formatVersion,
            summary: summary,
            irLedger: ledger
        )
    }
}

public extension PreflightReport {
    /// 由 IR 文档装配**完整**预检报告：适配器层登记 + `KairoBridge` 追加的登记。
    ///
    /// 桥接只用来算账，产出的项目随 `Result` 丢弃——预检仍不产出 Kairo 项目。
    /// 适配器自己算不出桥接层损失，所以这一步必须由本模块统一做，否则用户看到的清单会少报。
    static func assembling(
        formatID: String,
        formatVersion: String,
        document: InteropDocument
    ) -> PreflightReport {
        let groups = document.tasks.filter { $0.kind == .group }.count
        let milestones = document.tasks.filter { $0.kind == .milestone }.count
        let summary = "\(document.tasks.count) 任务（\(groups) 汇总 / \(milestones) 里程碑）/ "
            + "\(document.calendars.count) 日历 / \(document.baselines.count) 基线 / "
            + "\(document.assignments.count) 分配"
        return PreflightReport(
            formatID: formatID,
            formatVersion: formatVersion,
            summary: summary,
            irLedger: document.ledger,
            bridgeLedger: KairoBridge().makeProject(from: document).bridgeLedger
        )
    }
}

/// 格式适配器契约（硬规则 1–3）。
///
/// 实现约束（评审硬门槛）：
/// - 只允许 `import KairoInterop`，**不得** import `KairoCore` 的业务模型；
/// - 不得 import 别的适配器；
/// - `read` 必须先过版本闸门，未知版本抛 `InteropError.unsupportedFormatVersion`；
/// - 有损项一律写进 `InteropDocument.ledger`，不许静默丢弃。
public protocol FormatAdapter: Sendable {
    /// 稳定的格式标识（`mspdi` / `omniplan`）：配置文件与 UI 都按它引用。
    var id: String { get }
    /// 能力声明。
    var capabilities: AdapterCapabilities { get }
    /// 支持的格式版本号；未知版本一律拒绝。
    var supportedVersions: [Int] { get }

    /// 轻量识别：不解全文档，只判断「这像是我的格式吗」。
    func sniff(_ data: Data) -> Bool
    /// 读入为 IR；失败抛 `InteropError`。
    func read(_ data: Data) throws -> InteropDocument
    /// 写出 IR；`capabilities.canWrite == false` 时抛 `.operationNotSupported`。
    func write(_ document: InteropDocument) throws -> Data
    /// 预检：版本闸门 + 有损清单，不产出 Kairo 项目。
    func preflight(_ data: Data) throws -> PreflightReport
}

public extension FormatAdapter {
    /// 默认预检实现：读一遍 IR，用它的登记与规模生成报告。
    ///
    /// 报告里的 `ledger` 是完整台账（IR 侧 + 桥接追加），与真正导入时的登记同源。
    /// 适配器只有在「预检比读入更便宜」时才需要覆写。
    func preflight(_ data: Data) throws -> PreflightReport {
        PreflightReport.assembling(
            formatID: id,
            formatVersion: "supported: \(supportedVersions.map(String.init).joined(separator: ","))",
            document: try read(data)
        )
    }
}

/// 适配器注册表：按 id 或按内容识别挑选适配器。
///
/// 故意做成 `struct` + 值语义：测试里可随时拼一个只含目标适配器的注册表，
/// 生产侧由应用层在启动时注册（MCP/CLI 同样复用这一处）。
public struct AdapterRegistry: Sendable {
    private var adapters: [any FormatAdapter] = []

    public init(adapters: [any FormatAdapter] = []) {
        for adapter in adapters { register(adapter) }
    }

    /// 注册适配器；同 id 覆盖（后注册者优先，便于测试替换）。
    public mutating func register(_ adapter: any FormatAdapter) {
        adapters.removeAll { $0.id == adapter.id }
        adapters.append(adapter)
    }

    /// 已注册的适配器（按注册顺序）。
    public var all: [any FormatAdapter] { adapters }

    /// 按 id 取适配器。
    public func adapter(id: String) -> (any FormatAdapter)? {
        adapters.first { $0.id == id }
    }

    /// 按内容识别：返回第一个 `sniff` 为真的适配器。
    public func adapter(sniffing data: Data) -> (any FormatAdapter)? {
        adapters.first { $0.sniff(data) }
    }
}

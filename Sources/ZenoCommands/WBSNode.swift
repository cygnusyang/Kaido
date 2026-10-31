import Foundation
import ZenoCore

/// WBS 批量导入的输入节点：嵌套标题/kind/子节点树（US-E1-04）。
public struct WBSNode: Codable, Hashable, Sendable {
    public var title: String
    public var kind: TaskKind?
    public var effortHours: Double?
    public var durationDays: Double?
    public var children: [WBSNode]

    public init(
        title: String,
        kind: TaskKind? = nil,
        effortHours: Double? = nil,
        durationDays: Double? = nil,
        children: [WBSNode] = []
    ) {
        self.title = title
        self.kind = kind
        self.effortHours = effortHours
        self.durationDays = durationDays
        self.children = children
    }

    // 合成 Codable 把 children 当必填键；实际 WBS JSON 的叶子节点常省略 children。
    // 自定义解码：缺失的 children 默认 []（CLI/MCP 导入对省略键更宽容，ADR-005 同源生效）。
    private enum CodingKeys: String, CodingKey {
        case title, kind, effortHours, durationDays, children
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        title = try c.decode(String.self, forKey: .title)
        kind = try c.decodeIfPresent(TaskKind.self, forKey: .kind)
        effortHours = try c.decodeIfPresent(Double.self, forKey: .effortHours)
        durationDays = try c.decodeIfPresent(Double.self, forKey: .durationDays)
        children = try c.decodeIfPresent([WBSNode].self, forKey: .children) ?? []
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encodeIfPresent(effortHours, forKey: .effortHours)
        try c.encodeIfPresent(durationDays, forKey: .durationDays)
        try c.encode(children, forKey: .children)
    }
}

/// WBS 导入结果：顶层节点映射 + 保真统计（US-E1-04 保真报告）。
public struct WBSImportResult: Sendable {
    public var rootIDs: [UUID]
    public var idByTitle: [String: UUID]
    public var total: Int
    public var warnings: [String]

    public init(
        rootIDs: [UUID] = [],
        idByTitle: [String: UUID] = [:],
        total: Int = 0,
        warnings: [String] = []
    ) {
        self.rootIDs = rootIDs
        self.idByTitle = idByTitle
        self.total = total
        self.warnings = warnings
    }
}

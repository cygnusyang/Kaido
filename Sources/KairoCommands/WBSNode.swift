import Foundation
import KairoCore

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

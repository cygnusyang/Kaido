import Foundation

/// 资源种类（F-23-01 / glossary「资源」）：人员 / 设备 / 素材 / 群组。
public enum ResourceKind: String, Codable, CaseIterable, Sendable {
    case person
    case equipment
    case material
    case group
}

/// 资源（F-23-01 / ADR-009）：完成任务所需的人与物。
/// `units` 为可用单位（人员/设备为百分比，素材为数量）；`efficiency` 影响
/// 投入↔持续时间换算（F-22-03：duration = effort / Σ(units × efficiency)）。
public struct Resource: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var kind: ResourceKind
    /// 可用单位（默认 1.0）。
    public var units: Double
    /// 效率（默认 1.0）：1 小时工作计 1 小时投入。
    public var efficiency: Double

    public init(
        id: UUID = UUID(),
        name: String,
        kind: ResourceKind = .person,
        units: Double = 1.0,
        efficiency: Double = 1.0
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.units = units
        self.efficiency = efficiency
    }
}

/// 任务↔资源分配（F-22-08 / glossary「分配」）：资源以指定单位投入任务。
public struct TaskAssignment: Codable, Hashable, Sendable {
    public var resourceID: UUID
    /// 分配单位（默认 1.0）。
    public var units: Double

    public init(resourceID: UUID, units: Double = 1.0) {
        self.resourceID = resourceID
        self.units = units
    }
}

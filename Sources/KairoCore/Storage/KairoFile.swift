import Foundation

/// .kairo 单文件格式门面（ADR-003 本地优先 / ADR-011 兼容规则）。
///
/// 根结构：
/// ```
/// { "formatVersion": 1, "project": {...元数据}, "tasks": [...] }
/// ```
/// 读取时忽略未知字段（前向兼容）；旧版本经 `FormatMigrationPlan` 顺序迁移后解码，
/// 未来版本或迁移失败返回明确错误且不覆盖原文件（US-E6-01）。
public enum KairoFile {
    public static let currentFormatVersion = 1

    /// 编码项目为 .kairo JSON 数据（人工可读、git 友好，ADR-003）。
    public static func encode(project: Project) throws -> Data {
        let envelope = Envelope(
            formatVersion: currentFormatVersion,
            project: project.metadata,
            tasks: project.tasks,
            resources: project.resources
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(envelope)
    }

    /// 从 .kairo JSON 数据解码项目；校验 formatVersion 并按需迁移。
    ///
    /// 先探测原始 JSON 的 `formatVersion`（不做强类型解码）：
    /// - 缺失、非整数或 ≤0：`KairoFileError.malformedFormatVersion`；
    /// - 高于当前版本：`KairoFileError.unsupportedFormatVersion`，不读取内容；
    /// - 当前版本：不执行迁移；
    /// - 1 ≤ v < current：按 `plan` 升序迁移后，再走强类型解码校验。
    public static func read(
        from data: Data,
        plan: FormatMigrationPlan = .standard
    ) throws -> DecodedProject {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw KairoFileError.malformedFormatVersion("根节点不是 JSON 对象")
        }
        guard let version = FormatDocument.parseVersion(root["formatVersion"]) else {
            throw KairoFileError.malformedFormatVersion("formatVersion 缺失或不是整数")
        }
        guard version > 0 else {
            throw KairoFileError.malformedFormatVersion("formatVersion 必须为正整数（实际 \(version)）")
        }
        guard version <= currentFormatVersion else {
            throw KairoFileError.unsupportedFormatVersion(version)
        }

        var document = FormatDocument(root: root)
        if version < currentFormatVersion {
            try plan.migrate(from: version, to: currentFormatVersion, document: &document)
        }

        let decodedData: Data
        do {
            decodedData = try JSONSerialization.data(withJSONObject: document.root)
        } catch {
            if version < currentFormatVersion {
                throw KairoFileError.migrationFailed(
                    from: version,
                    to: currentFormatVersion,
                    reason: "迁移结果无法序列化：\(error.localizedDescription)"
                )
            }
            throw error
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: decodedData)
        guard envelope.formatVersion == currentFormatVersion else {
            throw KairoFileError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let project = Project()
        project.metadata = envelope.project
        project.tasks = envelope.tasks
        project.resources = envelope.resources
        return DecodedProject(project: project, sourceFormatVersion: version)
    }

    /// 从 .kairo JSON 数据解码项目；不暴露来源版本，仅返回项目。
    public static func decode(from data: Data) throws -> Project {
        try read(from: data).project
    }

    /// 保存项目到指定 URL（原子写入，避免半截文件）。
    public static func save(_ project: Project, to url: URL) throws {
        let data = try encode(project: project)
        try data.write(to: url, options: .atomic)
    }

    /// 从指定 URL 读取项目与来源格式版本；读取失败时不改动磁盘文件。
    public static func read(
        from url: URL,
        plan: FormatMigrationPlan = .standard
    ) throws -> DecodedProject {
        let data = try Data(contentsOf: url)
        return try read(from: data, plan: plan)
    }

    /// 从指定 URL 加载项目；按需迁移到当前格式。
    public static func load(
        from url: URL,
        plan: FormatMigrationPlan = .standard
    ) throws -> Project {
        try read(from: url, plan: plan).project
    }

    /// .kairo 信封：新增字段（resources）用自定义解码，缺失给默认值（ADR-011 前向兼容）。
    private struct Envelope: Codable {
        var formatVersion: Int
        var project: ProjectMetadata
        var tasks: [TaskItem]
        var resources: [Resource]

        private enum CodingKeys: String, CodingKey {
            case formatVersion, project, tasks, resources
        }

        init(formatVersion: Int, project: ProjectMetadata, tasks: [TaskItem], resources: [Resource]) {
            self.formatVersion = formatVersion
            self.project = project
            self.tasks = tasks
            self.resources = resources
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            formatVersion = try c.decode(Int.self, forKey: .formatVersion)
            project = try c.decode(ProjectMetadata.self, forKey: .project)
            tasks = try c.decode([TaskItem].self, forKey: .tasks)
            resources = try c.decodeIfPresent([Resource].self, forKey: .resources) ?? []
        }

        func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(formatVersion, forKey: .formatVersion)
            try c.encode(project, forKey: .project)
            try c.encode(tasks, forKey: .tasks)
            try c.encode(resources, forKey: .resources)
        }
    }
}

/// .kairo 读写错误（US-E6-01：不兼容版本返回明确错误且不覆盖原文件）。
public enum KairoFileError: Error, Equatable, CustomStringConvertible {
    /// 文件版本高于当前支持版本。
    case unsupportedFormatVersion(Int)
    /// `formatVersion` 缺失、不是整数或不是正数；关联值为原因说明。
    case malformedFormatVersion(String)
    /// 缺少从 `from` 到 `to` 的迁移路径（含跳版与缺步骤）。
    case noMigrationPath(from: Int, to: Int)
    /// 某个迁移步骤执行失败；`reason` 为底层错误说明。
    case migrationFailed(from: Int, to: Int, reason: String)

    public var description: String {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "不支持的 .kairo 版本 \(version)（当前支持 \(KairoFile.currentFormatVersion)）"
        case .malformedFormatVersion(let reason):
            return "无效的 .kairo 格式版本：\(reason)"
        case .noMigrationPath(let from, let to):
            return "缺少 .kairo 格式迁移路径（\(from) → \(to)）"
        case .migrationFailed(let from, let to, let reason):
            return "迁移 .kairo 格式失败（\(from) → \(to)）：\(reason)"
        }
    }
}

import Foundation

/// .kairo 单文件格式门面（ADR-003 本地优先 / ADR-011 兼容规则）。
///
/// 根结构：
/// ```
/// { "formatVersion": 1, "project": {...元数据}, "tasks": [...] }
/// ```
/// 读取时忽略未知字段（前向兼容）；`formatVersion` 不兼容时返回明确错误
/// 且不覆盖原文件（US-E6-01）。
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

    /// 从 .kairo JSON 数据解码项目；校验 formatVersion。
    public static func decode(from data: Data) throws -> Project {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let envelope = try decoder.decode(Envelope.self, from: data)
        guard envelope.formatVersion == currentFormatVersion else {
            throw KairoFileError.unsupportedFormatVersion(envelope.formatVersion)
        }
        let project = Project()
        project.metadata = envelope.project
        project.tasks = envelope.tasks
        project.resources = envelope.resources
        return project
    }

    /// 保存项目到指定 URL（原子写入，避免半截文件）。
    public static func save(_ project: Project, to url: URL) throws {
        let data = try encode(project: project)
        try data.write(to: url, options: .atomic)
    }

    /// 从指定 URL 加载项目。
    public static func load(from url: URL) throws -> Project {
        let data = try Data(contentsOf: url)
        return try decode(from: data)
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
    case unsupportedFormatVersion(Int)

    public var description: String {
        switch self {
        case .unsupportedFormatVersion(let version):
            return "不支持的 .kairo 版本 \(version)（当前支持 \(KairoFile.currentFormatVersion)）"
        }
    }
}

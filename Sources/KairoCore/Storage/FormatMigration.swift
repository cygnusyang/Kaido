import Foundation

/// 解码结果：项目数据与源文件声明的格式版本。
public struct DecodedProject {
    /// 解码后的项目。
    public var project: Project
    /// 源文件的 `formatVersion`（迁移前）；打开当前版本文件时等于 `KairoFile.currentFormatVersion`。
    public var sourceFormatVersion: Int

    public init(project: Project, sourceFormatVersion: Int) {
        self.project = project
        self.sourceFormatVersion = sourceFormatVersion
    }
}

/// 迁移步骤操作的 JSON 文档。
///
/// 保留原始根节点，迁移只需改写必要字段，未知字段得以原样保留（ADR-011）。
public struct FormatDocument {
    /// .kairo 根节点（`JSONSerialization` 解析产物）。
    public var root: [String: Any]

    public init(root: [String: Any]) {
        self.root = root
    }

    /// 根节点的 `formatVersion`。
    ///
    /// getter 在字段缺失或不是整数时返回 `0` 且不崩溃。打开路径在调用迁移前
    /// 已拒绝这类文档，因此 `0` 仅表示“不可用”，不会被当作可迁移的旧版本。
    public var formatVersion: Int {
        get { Self.parseVersion(root["formatVersion"]) ?? 0 }
        set { root["formatVersion"] = newValue }
    }

    /// 严格解析版本号：只接受非布尔、无小数部分的 JSON 数字。
    static func parseVersion(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber else { return nil }
        // JSONSerialization 用 NSNumber 表示 true/false；布尔不是合法版本号。
        guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let double = number.doubleValue
        guard double.rounded() == double,
              double >= Double(Int.min),
              double <= Double(Int.max) else { return nil }
        return Int(double)
    }
}

/// 单个格式迁移步骤：把文档从 `toVersion - 1` 升到 `toVersion`。
///
/// 约定（禁止跳版）：
/// - 步骤只处理相邻版本，调用方通过 `toVersion` 定位它；
/// - `migrate` 结束时必须把 `document.formatVersion` 设为 `toVersion`，
///   否则 `FormatMigrationPlan` 判定该步骤失败。
public protocol FormatMigration {
    /// 步骤产出的格式版本；输入版本固定为 `toVersion - 1`。
    var toVersion: Int { get }

    /// 就地迁移文档；失败时抛出任意错误，由 `FormatMigrationPlan` 包装。
    func migrate(_ document: inout FormatDocument) throws
}

/// 顺序迁移计划：按版本升序逐步执行迁移，任何缺口都视为无迁移路径。
public struct FormatMigrationPlan {
    private let steps: [any FormatMigration]

    /// 创建计划。`steps` 必须各自拥有唯一的 `toVersion`（重复即编程错误，
    /// 触发 precondition）；执行时忽略传入顺序。
    public init(_ steps: [any FormatMigration] = []) {
        let versions = steps.map { $0.toVersion }
        precondition(
            Set(versions).count == versions.count,
            ".kairo 迁移计划存在重复的 toVersion：\(versions)"
        )
        self.steps = steps
    }

    /// 标准计划：当前格式为 v1，v2 之前没有迁移步骤。
    public static let standard = FormatMigrationPlan()

    /// 把文档从 `from` 升到 `to`。
    ///
    /// - `from == to`：不做任何事。
    /// - 缺少中间步骤或 `from > to`：抛 `KairoFileError.noMigrationPath`，
    ///   其中 `from`/`to` 为缺失的那一段。
    /// - 步骤抛错或未落地到其 `toVersion`：抛 `KairoFileError.migrationFailed`。
    public func migrate(from: Int, to: Int, document: inout FormatDocument) throws {
        guard from != to else { return }
        guard from < to else {
            throw KairoFileError.noMigrationPath(from: from, to: to)
        }
        guard document.formatVersion == from else {
            throw KairoFileError.migrationFailed(
                from: from,
                to: to,
                reason: "文档版本 \(document.formatVersion) 与迁移起点 \(from) 不一致"
            )
        }
        var version = from
        while version < to {
            let target = version + 1
            guard let step = steps.first(where: { $0.toVersion == target }) else {
                // 报缺失的那一段（version → target），便于直接补步骤。
                throw KairoFileError.noMigrationPath(from: version, to: target)
            }
            do {
                try step.migrate(&document)
            } catch {
                throw KairoFileError.migrationFailed(from: version, to: target, reason: "\(error)")
            }
            guard document.formatVersion == target else {
                throw KairoFileError.migrationFailed(
                    from: version,
                    to: target,
                    reason: "迁移步骤未将 formatVersion 更新为 \(target)（实际 \(document.formatVersion)）"
                )
            }
            version = target
        }
    }
}

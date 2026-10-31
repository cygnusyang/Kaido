import Foundation

/// 解码结果：项目数据与源文件声明的格式版本。
public struct DecodedProject {
    /// 解码后的项目。
    public var project: Project
    /// 源文件的 `formatVersion`（迁移前）；打开当前版本文件时等于 `KaidoFile.currentFormatVersion`。
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
    /// .kaido 根节点（`JSONSerialization` 解析产物）。
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
        // objCType 在 Darwin 与 Linux 上都把布尔记为 'c'（整数 i/q、浮点 d），
        // 不用 CoreFoundation 的 CFGetTypeID / CFBooleanGetTypeID——Linux 没有这两个符号。
        guard String(cString: number.objCType) != "c" else { return nil }
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

/// v1 → v2 迁移（08-baselines §7.2）：纯加法，只升版本号。
///
/// `baselines` 缺失即合法（= 空），由 `Envelope` 的 `decodeIfPresent ?? []` 兜底，
/// 因此本步骤**不写任何字段**，也绝不把 `document.root` 解成强类型再写回——
/// 后者会丢掉未知键（ADR-011 只保证「读不报错」之外还有「迁移不重建根节点」）。
public struct BaselineFormatV2Migration: FormatMigration {
    public init() {}

    public var toVersion: Int { 2 }

    public func migrate(_ document: inout FormatDocument) throws {
        document.formatVersion = 2
    }
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
            ".kaido 迁移计划存在重复的 toVersion：\(versions)"
        )
        self.steps = steps
    }

    /// 标准计划：v1 → v2（08-baselines §7.2 加法迁移）。
    ///
    /// 每次升版本在此追加步骤，顺序由 `toVersion` 决定，不依赖数组顺序。
    public static let standard = FormatMigrationPlan([BaselineFormatV2Migration()])

    /// 把文档从 `from` 升到 `to`。
    ///
    /// - `from == to`：不做任何事。
    /// - 缺少中间步骤或 `from > to`：抛 `KaidoFileError.noMigrationPath`，
    ///   其中 `from`/`to` 为缺失的那一段。
    /// - 步骤抛错或未落地到其 `toVersion`：抛 `KaidoFileError.migrationFailed`。
    public func migrate(from: Int, to: Int, document: inout FormatDocument) throws {
        guard from != to else { return }
        guard from < to else {
            throw KaidoFileError.noMigrationPath(from: from, to: to)
        }
        guard document.formatVersion == from else {
            throw KaidoFileError.migrationFailed(
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
                throw KaidoFileError.noMigrationPath(from: version, to: target)
            }
            do {
                try step.migrate(&document)
            } catch {
                throw KaidoFileError.migrationFailed(from: version, to: target, reason: "\(error)")
            }
            guard document.formatVersion == target else {
                throw KaidoFileError.migrationFailed(
                    from: version,
                    to: target,
                    reason: "迁移步骤未将 formatVersion 更新为 \(target)（实际 \(document.formatVersion)）"
                )
            }
            version = target
        }
    }
}

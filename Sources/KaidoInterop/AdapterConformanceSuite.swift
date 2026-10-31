import Foundation

/// 契约测试用例：一份「输入数据 + 期望的 IR 形态」。
///
/// 由各适配器的测试 target 提供本格式的最小样本；断言逻辑不在测试里重写——
/// 新增通道只加样本、不改断言，这才是「适配器互相独立」的可验证形式（14 §2 硬规则 4）。
public struct AdapterConformanceCase: Sendable {
    /// 期望的拒绝原因。
    public enum Rejection: String, Sendable, Equatable {
        /// 格式版本未知，必须抛 `unsupportedFormatVersion`。
        case unsupportedVersion
        /// 结构不合法，必须抛 `malformedDocument`。
        case malformed
    }

    /// 期望的 IR 形态。
    public enum Expectation: Sendable, Equatable {
        /// 空计划：读入成功且零任务。
        case emptyPlan
        /// 单任务：恰好一条任务，标题与种类为普通任务。
        case singleTask(title: String)
        /// 四类相关性齐全（FS / FF / SS / SF）。
        case fourDependencyTypes
        /// 存在一条前导时间等于给定秒数的相关性。
        case lag(seconds: TimeInterval)
        /// 里程碑数量。
        case milestoneCount(Int)
        /// 存在群组且其下至少 N 个子任务。
        case groupWithChildren(minChildren: Int)
        /// 日历数量。
        case calendarCount(Int)
        /// 基线数量。
        case baselineCount(Int)
        /// 存在指定标题（中文 + emoji 原样保住）。
        case unicodeTitle(String)
        /// 必须明确拒绝，不得 best-effort 解析。
        case rejection(Rejection)
    }

    public let label: String
    public let data: Data
    public let expectation: Expectation

    public init(label: String, data: Data, expectation: Expectation) {
        self.label = label
        self.data = data
        self.expectation = expectation
    }
}

/// 适配器契约测试套件（14 §2 硬规则 4）。
///
/// 每个适配器都要跑同一套：空计划 / 单任务 / 四类依赖 / lag / 里程碑 / 群组 /
/// 多日历 / 基线 / 中文 emoji / 畸形输入。断言只看 IR，不碰具体格式。
public enum AdapterConformanceSuite {
    /// 契约测试失败：一次列出全部失败项，便于一眼看完（而不是第一个错就中断）。
    public struct Failure: Error, CustomStringConvertible, Sendable {
        public let messages: [String]

        public var description: String {
            "适配器契约测试失败 \(messages.count) 项：\n- " + messages.joined(separator: "\n- ")
        }
    }

    /// 跑完整套用例；有任何失败即抛 `Failure`。
    public static func check(_ adapter: any FormatAdapter, cases: [AdapterConformanceCase]) throws {
        let failures = failures(of: adapter, cases: cases)
        guard failures.isEmpty else { throw Failure(messages: failures) }
    }

    /// 跑完整套用例并返回失败描述（空数组 = 全绿）。
    public static func failures(
        of adapter: any FormatAdapter,
        cases: [AdapterConformanceCase]
    ) -> [String] {
        var result: [String] = []
        for testCase in cases {
            switch testCase.expectation {
            case .rejection(let expected):
                result.append(contentsOf: checkRejection(adapter, testCase, expected))
            default:
                result.append(contentsOf: checkRead(adapter, testCase))
            }
        }
        return result
    }

    // MARK: - 拒绝路径

    private static func checkRejection(
        _ adapter: any FormatAdapter,
        _ testCase: AdapterConformanceCase,
        _ expected: AdapterConformanceCase.Rejection
    ) -> [String] {
        do {
            _ = try adapter.read(testCase.data)
            return ["\(testCase.label)：应当拒绝（\(expected.rawValue)），却读入成功"]
        } catch let error as InteropError {
            switch (expected, error) {
            case (.unsupportedVersion, .unsupportedFormatVersion),
                 (.malformed, .malformedDocument):
                return []
            default:
                return ["\(testCase.label)：拒绝原因不符，期望 \(expected.rawValue)，实际 \(error)"]
            }
        } catch {
            return ["\(testCase.label)：抛出了非 InteropError 的错误：\(error)"]
        }
    }

    // MARK: - 读入路径

    private static func checkRead(
        _ adapter: any FormatAdapter,
        _ testCase: AdapterConformanceCase
    ) -> [String] {
        var failures: [String] = []
        if !adapter.sniff(testCase.data) {
            failures.append("\(testCase.label)：sniff 未识别出该格式")
        }
        let document: InteropDocument
        do {
            document = try adapter.read(testCase.data)
        } catch {
            failures.append("\(testCase.label)：读入失败 \(error)")
            return failures
        }
        failures.append(contentsOf: checkInvariants(document, testCase.label))
        failures.append(contentsOf: checkExpectation(document, testCase))
        return failures
    }

    /// 所有格式都必须满足的不变式。
    private static func checkInvariants(_ document: InteropDocument, _ label: String) -> [String] {
        var failures: [String] = []
        let ids = document.tasks.map(\.id)
        if Set(ids).count != ids.count {
            failures.append("\(label)：任务 id 不唯一")
        }
        let sequences = document.tasks.map(\.sequence)
        if sequences != sequences.sorted() {
            failures.append("\(label)：任务未按 sequence 保序")
        }
        for level in document.tasks.map(\.outlineLevel) where level < 0 {
            failures.append("\(label)：大纲层级为负（\(level)）")
            break
        }
        for task in document.tasks {
            if task.progress < 0 || task.progress > 1 {
                failures.append("\(label)：任务 \(task.id) 的完成度越界（\(task.progress)）")
                break
            }
        }
        return failures
    }

    private static func checkExpectation(
        _ document: InteropDocument,
        _ testCase: AdapterConformanceCase
    ) -> [String] {
        let label = testCase.label
        switch testCase.expectation {
        case .emptyPlan:
            return document.tasks.isEmpty ? [] : ["\(label)：空计划应零任务，实际 \(document.tasks.count)"]

        case .singleTask(let title):
            guard document.tasks.count == 1, let task = document.tasks.first else {
                return ["\(label)：应为单任务，实际 \(document.tasks.count)"]
            }
            var failures: [String] = []
            if task.title != title {
                failures.append("\(label)：标题不符，期望「\(title)」，实际「\(task.title)」")
            }
            if task.kind != .task {
                failures.append("\(label)：种类应为普通任务，实际 \(task.kind.rawValue)")
            }
            return failures

        case .fourDependencyTypes:
            let types = Set(document.tasks.flatMap { $0.dependencies.map(\.type) })
            let missing = InteropDependencyType.allCases.filter { !types.contains($0) }
            return missing.isEmpty
                ? []
                : ["\(label)：缺失相关性类型 \(missing.map(\.rawValue).joined(separator: "/"))"]

        case .lag(let seconds):
            let lags = document.tasks.flatMap { $0.dependencies.map(\.lagSeconds) }
            let hit = lags.contains { abs($0 - seconds) < 0.5 }
            return hit ? [] : ["\(label)：没有前导时间为 \(seconds) 秒的相关性（实际 \(lags)）"]

        case .milestoneCount(let expected):
            let count = document.tasks.filter { $0.kind == .milestone }.count
            return count == expected ? [] : ["\(label)：里程碑数应为 \(expected)，实际 \(count)"]

        case .groupWithChildren(let minimum):
            let groups = document.tasks.filter { $0.kind == .group }
            guard !groups.isEmpty else { return ["\(label)：没有识别出群组"] }
            let satisfied = groups.contains { group in
                document.tasks.filter { $0.parentID == group.id }.count >= minimum
            }
            return satisfied
                ? []
                : ["\(label)：群组下没有 \(minimum) 个子任务（父子关系未还原）"]

        case .calendarCount(let expected):
            return document.calendars.count == expected
                ? []
                : ["\(label)：日历数应为 \(expected)，实际 \(document.calendars.count)"]

        case .baselineCount(let expected):
            return document.baselines.count == expected
                ? []
                : ["\(label)：基线数应为 \(expected)，实际 \(document.baselines.count)"]

        case .unicodeTitle(let title):
            return document.tasks.contains { $0.title == title }
                ? []
                : ["\(label)：没有原样保住标题「\(title)」"]

        case .rejection:
            // 拒绝路径在 checkRejection 里处理，走不到这里。
            return []
        }
    }
}

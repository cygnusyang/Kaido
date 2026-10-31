import Foundation

/// 有损登记（14-interop-architecture §3）：每条「丢了什么 / 换算过什么 / 降级成什么」都带
/// 字段名、计数与原值样例。
///
/// 两个使用面同源：导入预检报告与导出旁注都从这一份渲染，不各写一套。
/// 合并规则（`merging`）：同「种类 + 字段名」的条目累加计数、样例去重后最多保留 3 条——
/// 预检报告要的是「哪一类丢了多少」，而不是逐任务流水。
public struct FidelityLedger: Sendable, Equatable {
    /// 损失的种类。区分它是为了让预检报告能分组显示，而不是把所有问题混成一句「有损」。
    public enum Kind: String, Sendable, Equatable, CaseIterable {
        /// 来源有、IR/Kaido 没有落点，直接丢弃。
        case dropped
        /// 有落点但语义变弱（硬约束 → 软约束、固定工期 → 按天排）。
        case degraded
        /// 单位或口径换算过（工作日 ↔ 日历天、十分之一分钟 → 秒）。
        case converted
        /// 来源缺字段，用默认值派生（如基线完成度缺失按 0）。
        case derived
    }

    /// 一条登记。
    public struct Entry: Identifiable, Sendable, Equatable {
        public var id: String { key }
        /// 字段名（IR 口径，如 `constraint` / `calendar.workingWeekdays`）。
        public let field: String
        public let kind: Kind
        /// 受影响的对象数（任务 / 记录 / 定义）。
        public private(set) var count: Int
        /// 原值样例（最多 3 条，去重）。
        public private(set) var samples: [String]
        /// 面向用户的一句说明：为什么丢、丢了怎么办。
        public let detail: String

        /// 聚合键：同种类同字段合并成一条。
        var key: String { "\(kind.rawValue):\(field)" }

        public init(field: String, kind: Kind, count: Int, samples: [String] = [], detail: String) {
            self.field = field
            self.kind = kind
            self.count = count
            self.samples = Array(samples.prefix(FidelityLedger.maxSamples))
            self.detail = detail
        }

        /// 累加计数（合并同字段登记时用）。
        mutating func add(count: Int) {
            self.count += count
        }

        /// 追加一条样例（去重、限量）。
        mutating func absorb(sample: String?) {
            guard let sample, !samples.contains(sample),
                  samples.count < FidelityLedger.maxSamples else { return }
            samples.append(sample)
        }
    }

    /// 每条登记保留的样例上限。
    public static let maxSamples = 3

    /// 按登记顺序保存（数组而非字典：报告顺序必须稳定，便于逐版本对比）。
    private var storage: [Entry] = []
    private var indexByKey: [String: Int] = [:]

    /// 由已有条目构造（多用于测试与合并）。
    public init(entries: [Entry]) {
        for entry in entries { record(entry) }
    }

    /// 空登记。
    public init() {}

    /// 已登记的条目（按登记顺序）。
    public var entries: [Entry] { storage }

    public var isEmpty: Bool { storage.isEmpty }

    /// 登记一次损失；同「种类 + 字段名」自动累加计数。
    ///
    /// - Parameters:
    ///   - field: 字段名（IR 口径）。
    ///   - kind: 损失种类。
    ///   - count: 本次影响的对象数（≥0；0 不登记）。
    ///   - detail: 面向用户的说明（合并时保留首次登记的说明）。
    ///   - sample: 原值样例，无则不传。
    public mutating func record(
        field: String,
        kind: Kind,
        count: Int,
        detail: String,
        sample: String? = nil
    ) {
        record(field: field, kind: kind, count: count, detail: detail, samples: sample.map { [$0] } ?? [])
    }

    /// 登记一次损失，并一次给出多条原值样例（同一次调用内的样例不会被截断掉队）。
    public mutating func record(
        field: String,
        kind: Kind,
        count: Int,
        detail: String,
        samples: [String]
    ) {
        guard count > 0 else { return }
        record(Entry(field: field, kind: kind, count: count, samples: samples, detail: detail))
    }

    /// 合并另一份登记（IR 侧 + Kaido 侧 → 预检报告）。
    public func merging(_ other: FidelityLedger) -> FidelityLedger {
        var merged = self
        for entry in other.storage { merged.record(entry) }
        return merged
    }

    /// 按字段名取条目（同字段可能有多条，不同种类）。
    public func entry(field: String) -> Entry? {
        storage.first { $0.field == field }
    }

    /// 所有条目的纯文本渲染（预检报告可复制成文本，13-mapping §5）。
    public var plainText: String {
        guard !storage.isEmpty else { return "无有损项" }
        return storage.map { entry in
            let samples = entry.samples.isEmpty ? "" : "（样例：\(entry.samples.joined(separator: "、"))）"
            return "[\(entry.kind.rawValue)] \(entry.field) × \(entry.count)：\(entry.detail)\(samples)"
        }.joined(separator: "\n")
    }

    private mutating func record(_ entry: Entry) {
        guard entry.count > 0 else { return }
        if let index = indexByKey[entry.key] {
            storage[index].add(count: entry.count)
            for sample in entry.samples { storage[index].absorb(sample: sample) }
        } else {
            indexByKey[entry.key] = storage.count
            storage.append(entry)
        }
    }
}

import Foundation

/// 基线配色分配（10-multi-baseline-gantt §4）：8 色索引 0…7 的纯函数分配器。
///
/// 三条不变量：
/// - 索引稳定：已分配的索引永不因其他基线增删而改变，故删中间一条后新建不会串色。
/// - 最小未占用：新基线取当前空缺的最小索引（0→7），而不是追加到末尾。
/// - 写路径独占：补色只发生在写路径（ensureColors）；打开只读不得调用，
///   否则会给未修改的文件平白置脏。
///
/// 本类型不含任何颜色值——颜色值在 App 层 DesignTokens，快照只存索引（ADR-013）。
public enum BaselinePalette {
    /// 调色板容量（合法索引 0 … count-1）。App 层 8 色 token 数组长度必须与之相同。
    public static let count = 8

    /// 为「即将新建」的基线选色：返回当前未被占用的最小索引。
    ///
    /// 越界值不算占用（那只是待修复的脏数据，不该挡住合法索引）。
    /// 8 色用尽时按已用数量的模数兜底——这是降级而非理想态：两个基线会共用一色，
    /// 图形上仍可区分（位置 / 名称），但颜色失去唯一性。
    public static func colorIndex(for baselines: [Baseline]) -> Int {
        let used = Set(baselines.compactMap { validIndex($0.colorIndex) })
        return smallestUnused(used)
    }

    /// 写路径补色：给缺 colorIndex 的基线按数组（创建）顺序补上最小未占用索引。
    ///
    /// 只在创建 / 改名 / 改色 / 删除这些写入口调用；已有索引一律原地保留。
    /// 幂等：补齐过的数组再次调用不产生任何变化。
    public static func ensureColors(in baselines: inout [Baseline]) {
        var used = Set(baselines.compactMap { validIndex($0.colorIndex) })
        for index in baselines.indices where baselines[index].colorIndex == nil {
            let assigned = smallestUnused(used)
            used.insert(assigned)
            baselines[index].colorIndex = assigned
        }
    }

    /// 读路径派生：把「可能缺失 / 越界 / 重复」的索引序列归一成合法且尽量唯一的序列。
    ///
    /// 用于只读展示（不改数据、不置脏）：合法且未重复的值保持不变，其余按出现顺序
    /// 取最小未占用索引；8 色用尽后同样按模兜底。返回数组与入参逐位对应。
    public static func resolve(_ indices: [Int?]) -> [Int] {
        var used = Set<Int>()
        var result: [Int] = []
        result.reserveCapacity(indices.count)
        for raw in indices {
            if let index = validIndex(raw), !used.contains(index) {
                used.insert(index)
                result.append(index)
            } else {
                let assigned = smallestUnused(used)
                used.insert(assigned)
                result.append(assigned)
            }
        }
        return result
    }

    // MARK: - 内部

    /// 0 … count-1 之外的索引视为无效（旧文件被手工改过时的兜底）。
    private static func validIndex(_ index: Int?) -> Int? {
        guard let index, (0..<count).contains(index) else { return nil }
        return index
    }

    private static func smallestUnused(_ used: Set<Int>) -> Int {
        if let free = (0..<count).first(where: { !used.contains($0) }) {
            return free
        }
        // 降级：8 色已满，按已用数量的模数给出确定性索引（不越界、不随机）。
        return used.count % count
    }
}

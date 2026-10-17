import Foundation

/// 从参数数组中抽取操作数与选项值。
struct Options {
    var items: [String]

    init(_ args: [String]) { items = args }

    /// 第 n 个非选项操作数。
    func operand(_ index: Int, name: String) throws -> String {
        let operands = items.filter { !$0.hasPrefix("--") }
        guard index < operands.count else {
            throw UsageError(message: "缺少参数：<\(name)>")
        }
        return operands[index]
    }

    /// 选项的值（--key value）。
    func value(for key: String) -> String? {
        guard let i = items.firstIndex(of: key), i + 1 < items.count else { return nil }
        return items[i + 1]
    }

    /// 选项的多个值（可重复出现）。
    func values(for key: String) -> [String] {
        var result: [String] = []
        for (i, item) in items.enumerated() where item == key {
            if i + 1 < items.count { result.append(items[i + 1]) }
        }
        return result
    }

    func double(for key: String) -> Double? {
        value(for: key).flatMap(Double.init)
    }

    /// --file 选项或默认文件名。
    func fileURL(defaultName: String) -> URL {
        URL(fileURLWithPath: value(for: "--file") ?? defaultName)
    }
}

/// 把「子命令 + 余下参数」从命令数组中拆出来。
func subcommand(_ args: [String], from command: String) -> (String, [String]) {
    guard let first = args.first else {
        return ("", [])
    }
    return (first, Array(args.dropFirst()))
}

func requireUUID(_ raw: String) throws -> UUID {
    guard let id = UUID(uuidString: raw) else {
        throw UsageError(message: "无效的任务 ID：\(raw)")
    }
    return id
}

func optionalUUID(_ raw: String?, name: String) throws -> UUID? {
    guard let raw else { return nil }
    guard let id = UUID(uuidString: raw) else {
        throw UsageError(message: "无效的 \(name)：\(raw)")
    }
    return id
}

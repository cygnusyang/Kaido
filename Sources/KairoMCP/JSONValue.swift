import Foundation

/// 零第三方依赖的任意 JSON 值（MCP 参数 / 结果载体）。
/// 自实现最小 JSON-RPC 传输（ADR-010）需要在不引入 Codable Any 的情况下
/// 表示任意嵌套结构。
enum JSONValue: Equatable, Sendable {
    case object([String: JSONValue])
    case array([JSONValue])
    case string(String)
    case number(Double)
    case bool(Bool)
    case null

    // MARK: - 便捷取值

    var stringValue: String? {
        if case .string(let s) = self { return s }
        return nil
    }

    var doubleValue: Double? {
        if case .number(let n) = self { return n }
        return nil
    }

    var boolValue: Bool? {
        if case .bool(let b) = self { return b }
        return nil
    }

    var objectValue: [String: JSONValue]? {
        if case .object(let o) = self { return o }
        return nil
    }

    var arrayValue: [JSONValue]? {
        if case .array(let a) = self { return a }
        return nil
    }

    /// 把任意 Codable 值编码为 JSONValue（工具输出用；日期按 ISO 8601）。
    static func json(_ value: some Encodable) throws -> JSONValue {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(value)
        return try JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// 把 JSONValue 解码为具体 Codable 类型（wbs_import 参数用）。
    static func decode<T: Decodable>(_ type: T.Type, from value: JSONValue) throws -> T {
        let data = try JSONEncoder().encode(value)
        return try JSONDecoder().decode(type, from: data)
    }
}

// MARK: - Codable

private struct DynamicKey: CodingKey {
    let stringValue: String
    let intValue: Int?
    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
    init?(intValue: Int) {
        self.stringValue = "\(intValue)"
        self.intValue = intValue
    }
}

extension JSONValue: Codable {
    init(from decoder: Decoder) throws {
        if let keyed = try? decoder.container(keyedBy: DynamicKey.self) {
            var dict: [String: JSONValue] = [:]
            for key in keyed.allKeys {
                dict[key.stringValue] = try keyed.decode(JSONValue.self, forKey: key)
            }
            self = .object(dict)
        } else if var unkeyed = try? decoder.unkeyedContainer() {
            var items: [JSONValue] = []
            while !unkeyed.isAtEnd {
                items.append(try unkeyed.decode(JSONValue.self))
            }
            self = .array(items)
        } else {
            let single = try decoder.singleValueContainer()
            if single.decodeNil() {
                self = .null
            } else if let b = try? single.decode(Bool.self) {
                self = .bool(b)
            } else if let n = try? single.decode(Double.self) {
                self = .number(n)
            } else if let s = try? single.decode(String.self) {
                self = .string(s)
            } else {
                throw DecodingError.dataCorruptedError(
                    in: single,
                    debugDescription: "无法解码为 JSONValue"
                )
            }
        }
    }

    func encode(to encoder: Encoder) throws {
        switch self {
        case .object(let dict):
            var keyed = encoder.container(keyedBy: DynamicKey.self)
            for (key, value) in dict {
                guard let k = DynamicKey(stringValue: key) else { continue }
                try keyed.encode(value, forKey: k)
            }
        case .array(let items):
            var unkeyed = encoder.unkeyedContainer()
            for item in items {
                try unkeyed.encode(item)
            }
        case .string(let s):
            var single = encoder.singleValueContainer()
            try single.encode(s)
        case .number(let n):
            var single = encoder.singleValueContainer()
            try single.encode(n)
        case .bool(let b):
            var single = encoder.singleValueContainer()
            try single.encode(b)
        case .null:
            var single = encoder.singleValueContainer()
            try single.encodeNil()
        }
    }
}

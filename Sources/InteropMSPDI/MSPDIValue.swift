import Foundation

/// MSPDI 的标量口径：日期、时长、十分之一分钟、星期编号。
///
/// 全部集中在一处，避免解析器里散落 `Double(text) ?? 0` 这类「错了也看不出来」的写法。
enum MSPDIValue {
    /// 星期编号：`DayType` 1 = 周日 … 7 = 周六，与 `Calendar` / Kairo 同口径。
    static func isValidWeekday(_ dayType: Int) -> Bool {
        (1...7).contains(dayType)
    }

    /// 解析 ISO 8601 时长（MSPDI 的 `Duration` / `Work` / `LinkLagFormat` 的口径）。
    ///
    /// 支持 `PT2696H0M0S`、`PT954H34M48S`、`P1DT2H`、`-PT8H`、`P3W`；
    /// 不支持月（`M` 在 `T` 之前）—— MSPDI 的工期不会用月表达，遇到即视为不合法。
    static func seconds(fromISODuration text: String) -> TimeInterval? {
        var value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        var sign: Double = 1
        if value.hasPrefix("-") {
            sign = -1
            value.removeFirst()
        }
        guard value.hasPrefix("P") else { return nil }

        var total: Double = 0
        var buffer = ""
        var inTime = false
        for character in value.dropFirst() {
            switch character {
            case "T":
                inTime = true
                buffer = ""
            case "0"..."9", ".", "-", "+":
                buffer.append(character)
            case "W", "D", "H", "M", "S":
                guard let amount = Double(buffer) else { return nil }
                switch character {
                case "W": total += amount * 604_800
                case "D": total += amount * 86_400
                case "H": total += amount * 3_600
                case "M":
                    // T 之前的 M 是「月」，不在 MSPDI 工期口径内。
                    guard inTime else { return nil }
                    total += amount * 60
                default: total += amount
                }
                buffer = ""
            default:
                return nil
            }
        }
        guard buffer.isEmpty else { return nil }
        return sign * total
    }

    /// MSPDI 的 `LinkLag` 单位是十分之一分钟（13-mapping §3.5）：1 天（8h）= 4800。
    static func seconds(fromTenthsOfMinutes value: Double) -> TimeInterval {
        value * 6
    }

    /// 解析 `HH:mm:ss` 为「当日第几秒」。
    static func secondsOfDay(_ text: String) -> TimeInterval? {
        let parts = text.split(separator: ":").map(String.init)
        guard parts.count >= 2,
              let hour = Double(parts[0]),
              let minute = Double(parts[1]) else { return nil }
        let second = parts.count > 2 ? Double(parts[2]) ?? 0 : 0
        return hour * 3_600 + minute * 60 + second
    }
}

/// MSPDI 日期解析器。
///
/// 实例自带 `DateFormatter`（创建代价高，一次解析复用一份）；不跨线程共享。
struct MSPDIDateParser {
    private let plain: DateFormatter
    private let fractional: DateFormatter
    private let iso: ISO8601DateFormatter

    init(timeZone: TimeZone = .current) {
        plain = MSPDIDateParser.makeFormatter("yyyy-MM-dd'T'HH:mm:ss", timeZone: timeZone)
        fractional = MSPDIDateParser.makeFormatter("yyyy-MM-dd'T'HH:mm:ss.SSS", timeZone: timeZone)
        iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    }

    private static func makeFormatter(_ format: String, timeZone: TimeZone) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        return formatter
    }

    /// 解析节点文本；空或缺失返回 nil。
    func date(_ node: XMLNode?) -> Date? {
        guard let node else { return nil }
        return date(node.text)
    }

    func date(_ text: String) -> Date? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if value.hasSuffix("Z") || value.contains("+") {
            if let parsed = iso.date(from: value) { return parsed }
        }
        return plain.date(from: value) ?? fractional.date(from: value)
    }
}

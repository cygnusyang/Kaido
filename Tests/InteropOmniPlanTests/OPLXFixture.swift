import Foundation

/// OmniPlan \`.oplx\` 测试样本。
///
/// 两个来源：
/// - **合成样本**：本文件用「stored zip」在内存里拼容器（不引第三方库、不落二进制），
///   用来覆盖空计划、单任务、四型依赖、里程碑、日历例外、未知版本、畸形输入；
/// - **真实样本**：\`Fixtures/omniplan-four-dependencies.oplx\` 是 OmniPlan 4.10.3 自己写出的
///   deflate 容器（四型依赖 + 前导时间），专门用来压解压路径。
enum OPLXFixture {
    static let namespace = "http://www.omnigroup.com/namespace/OmniPlan/v2"

    // MARK: - XML 片段

    /// \`__TOC.xml\`：文档外壳（版本号、duration-format、scenario 清单）。
    static func toc(
        fileFormatVersion: Int = 3,
        hoursPerDay: Double? = 8,
        scenarios: [(name: String, filename: String)] = [("Actual", "Actual.xml")],
        extraProject: String = ""
    ) -> String {
        let durationFormat = hoursPerDay.map { hours in
            "<duration-format hours-per-day=\"\(number(hours))\" hours-per-week=\"40\" hours-per-month=\"160\" hours-per-year=\"1920\"/>"
        } ?? ""
        let scenarioList = scenarios
            .map { "<scenario id=\"sc-\($0.name)\" name=\"\($0.name)\" filename=\"\($0.filename)\"/>" }
            .joined()
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <omniplan xmlns="\(namespace)" file-format-version="\(fileFormatVersion)">
          <project>
            <next-task-id>100</next-task-id>
            <next-resource-id>100</next-resource-id>
            \(scenarioList)
            \(durationFormat)
            \(extraProject)
          </project>
        </omniplan>
        """
    }

    /// \`Actual.xml\`：场景（\`tasks\` / \`resources\` 由调用方拼好）。
    static func scenario(
        tasks: String,
        resources: String = "",
        topTaskID: String = "t-1",
        startDate: String = "2026-01-05T00:00:00.000Z"
    ) -> String {
        """
        <?xml version="1.0" encoding="UTF-8"?>
        <scenario xmlns="\(namespace)" id="sc-actual">
          <start-date>\(startDate)</start-date>
          <granularity>days</granularity>
          <prototype-task>
            <task id="t-2"><title>原型任务</title><effort>28800</effort></task>
          </prototype-task>
          <top-resource idref="r-1"/>
          \(resources)
          <top-task idref="\(topTaskID)"/>
          \(tasks)
          <critical-path root="-1" enabled="false" resources="false"/>
        </scenario>
        """
    }

    /// 项目资源（\`top-resource\` 指向它，日历从它的 schedule 读）。
    static func projectResource(
        schedule: String = "<schedule><schedule-day day-of-week=\"monday\"><time-span start-time=\"28800\" end-time=\"57600\"/></schedule-day></schedule>"
    ) -> String {
        """
        <resource id="r-1">
          <name>项目</name>
          <type>Project</type>
          \(schedule)
        </resource>
        """
    }

    static func member(_ name: String, _ content: String) -> (name: String, content: String) {
        (name, content)
    }

    // MARK: - 容器

    /// 由成员拼一个 stored（不压缩）zip：CRC/尺寸都写对，任何标准 zip 工具都能打开。
    static func archive(_ members: [(name: String, content: String)]) -> Data {
        var output = Data()
        var directory = Data()

        for entry in members {
            let nameBytes = Array(entry.name.utf8)
            let payload = Array(entry.content.utf8)
            let crc = crc32(payload)
            let localOffset = output.count

            output.append(uint32: 0x0403_4B50)
            output.append(uint16: 20)                 // version needed
            output.append(uint16: 0)                  // flags
            output.append(uint16: 0)                  // method = stored
            output.append(uint16: 0)                  // mod time
            output.append(uint16: 0x0021)             // mod date = 1980-01-01
            output.append(uint32: crc)
            output.append(uint32: UInt32(payload.count))
            output.append(uint32: UInt32(payload.count))
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)                  // extra length
            output.append(contentsOf: nameBytes)
            output.append(contentsOf: payload)

            directory.append(uint32: 0x0201_4B50)
            directory.append(uint16: 20)              // version made by
            directory.append(uint16: 20)              // version needed
            directory.append(uint16: 0)               // flags
            directory.append(uint16: 0)               // method
            directory.append(uint16: 0)               // mod time
            directory.append(uint16: 0x0021)          // mod date
            directory.append(uint32: crc)
            directory.append(uint32: UInt32(payload.count))
            directory.append(uint32: UInt32(payload.count))
            directory.append(uint16: UInt16(nameBytes.count))
            directory.append(uint16: 0)               // extra
            directory.append(uint16: 0)               // comment
            directory.append(uint16: 0)               // disk
            directory.append(uint16: 0)               // internal attributes
            directory.append(uint32: 0)               // external attributes
            directory.append(uint32: UInt32(localOffset))
            directory.append(contentsOf: nameBytes)
        }

        let directoryOffset = output.count
        output.append(directory)
        output.append(uint32: 0x0605_4B50)
        output.append(uint16: 0)                      // this disk
        output.append(uint16: 0)                      // disk with directory
        output.append(uint16: UInt16(members.count))
        output.append(uint16: UInt16(members.count))
        output.append(uint32: UInt32(directory.count))
        output.append(uint32: UInt32(directoryOffset))
        output.append(uint16: 0)                      // comment length
        return output
    }

    /// 完整容器：\`__TOC.xml\` + \`Actual.xml\`。
    static func archive(toc tocXML: String, scenario scenarioXML: String) -> Data {
        archive([
            (name: "__TOC.xml", content: tocXML),
            (name: "Actual.xml", content: scenarioXML)
        ])
    }

    // MARK: - 仓库内样本

    /// 仓库内 `Tests/Fixtures/` 下的真实样本（OmniPlan 自己写出的 deflate 容器）。
    ///
    /// 与 `mcp-errors-v085.json` 同一处置方式：`Fixtures` 不在测试 target 的资源声明内，
    /// 按源码路径读取（Package.swift 不为此加 `resources:`）。
    static func committed(_ name: String) throws -> Data {
        let directory = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
        return try Data(contentsOf: directory.appendingPathComponent(name))
    }

    static func number(_ value: Double) -> String {
        value == value.rounded() ? String(Int(value)) : String(value)
    }

    // MARK: - CRC32（zip 成员校验字段）

    private static let crcTable: [UInt32] = (0..<256).map { index in
        var value = UInt32(index)
        for _ in 0..<8 {
            value = (value & 1) == 1 ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
        }
        return value
    }

    private static func crc32(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc = crcTable[Int((crc ^ UInt32(byte)) & 0xFF)] ^ (crc >> 8)
        }
        return crc ^ 0xFFFF_FFFF
    }
}

private extension Data {
    mutating func append(uint16 value: UInt16) {
        append(contentsOf: [UInt8(value & 0xFF), UInt8((value >> 8) & 0xFF)])
    }

    mutating func append(uint32 value: UInt32) {
        append(contentsOf: [
            UInt8(value & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 24) & 0xFF)
        ])
    }
}

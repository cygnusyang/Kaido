import Foundation
import Compression

/// 最小 zip 写出器（\`.oplx\` 的容器层，与 \`ZipArchive\` 成对）。
///
/// 只做单卷 zip：deflate（Compression 的 raw deflate，与读取端 \`Compression\` 解码对称），
/// 压不小就退回 stored；时间戳固定 1980-01-01，保证**同一份 IR 写两次字节完全相同**
/// （与 MSPDI 写出端同一条纪律：输出只由输入决定）。
///
/// 超出单卷 zip 上限（4 GB 偏移/长度、65535 个成员）即报错，不写坏容器。
struct ZipArchiveWriter {
    /// 一个待写成员。
    struct Member {
        let name: String
        let data: Data

        init(_ name: String, _ content: String) {
            self.name = name
            self.data = Data(content.utf8)
        }
    }

    /// 容器超出单卷 zip 的表达范围。
    enum ZipWriteError: Error, CustomStringConvertible {
        case tooLarge(String)

        var description: String {
            switch self {
            case .tooLarge(let reason):
                return "zip 容器超出单卷上限：\(reason)"
            }
        }
    }

    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    /// DOS 日期 1980-01-01：固定值，让产物可复现。
    private static let fixedDOSTime: UInt16 = 0
    private static let fixedDOSDate: UInt16 = 0x0021
    /// deflate 压缩方法号。
    private static let deflateMethod: UInt16 = 8

    /// 打包成可被 \`ZipArchive\`（以及 OmniPlan）读取的单卷 zip。
    static func archive(_ members: [Member]) throws -> Data {
        guard members.count < Int(UInt16.max) else {
            throw ZipWriteError.tooLarge("成员数 \(members.count) 超过 65535")
        }

        var output = Data()
        var directory = Data()

        for member in members {
            let nameBytes = [UInt8](member.name.utf8)
            let payload = [UInt8](member.data)
            let localOffset = output.count
            let (method, body) = encoded(payload)
            let crc = crc32(payload)
            guard body.count <= Int(UInt32.max), payload.count <= Int(UInt32.max) else {
                throw ZipWriteError.tooLarge("成员「\(member.name)」超过 4 GB")
            }

            output.append(uint32: Self.localHeaderSignature)
            output.append(uint16: 20)                     // version needed
            output.append(uint16: 0)                      // flags
            output.append(uint16: method)
            output.append(uint16: Self.fixedDOSTime)
            output.append(uint16: Self.fixedDOSDate)
            output.append(uint32: crc)
            output.append(uint32: UInt32(body.count))
            output.append(uint32: UInt32(payload.count))
            output.append(uint16: UInt16(nameBytes.count))
            output.append(uint16: 0)                      // extra length
            output.append(contentsOf: nameBytes)
            output.append(contentsOf: body)

            directory.append(uint32: Self.centralDirectorySignature)
            directory.append(uint16: 20)                  // version made by
            directory.append(uint16: 20)                  // version needed
            directory.append(uint16: 0)                   // flags
            directory.append(uint16: method)
            directory.append(uint16: Self.fixedDOSTime)
            directory.append(uint16: Self.fixedDOSDate)
            directory.append(uint32: crc)
            directory.append(uint32: UInt32(body.count))
            directory.append(uint32: UInt32(payload.count))
            directory.append(uint16: UInt16(nameBytes.count))
            directory.append(uint16: 0)                   // extra
            directory.append(uint16: 0)                   // comment
            directory.append(uint16: 0)                   // disk
            directory.append(uint16: 0)                   // internal attributes
            directory.append(uint32: 0)                   // external attributes
            directory.append(uint32: UInt32(localOffset))
            directory.append(contentsOf: nameBytes)
        }

        let directoryOffset = output.count
        guard directoryOffset <= Int(UInt32.max), directory.count <= Int(UInt32.max) else {
            throw ZipWriteError.tooLarge("中央目录偏移超过 4 GB")
        }
        output.append(directory)
        output.append(uint32: Self.endOfCentralDirectorySignature)
        output.append(uint16: 0)                          // this disk
        output.append(uint16: 0)                          // disk with directory
        output.append(uint16: UInt16(members.count))
        output.append(uint16: UInt16(members.count))
        output.append(uint32: UInt32(directory.count))
        output.append(uint32: UInt32(directoryOffset))
        output.append(uint16: 0)                          // comment length
        return output
    }

    // MARK: - 压缩

    /// 压缩方法与数据：deflate 压不小就退回 stored（两者都是合法 zip）。
    private static func encoded(_ payload: [UInt8]) -> (UInt16, [UInt8]) {
        guard let compressed = deflate(payload), compressed.count < payload.count else {
            return (0, payload)
        }
        return (deflateMethod, compressed)
    }

    private static func deflate(_ payload: [UInt8]) -> [UInt8]? {
        guard !payload.isEmpty else { return nil }
        // 压缩后的长度上界留足余量：压不下就返回 nil，由调用方走 stored。
        var destination = [UInt8](repeating: 0, count: payload.count + payload.count / 4 + 64)
        let written = destination.withUnsafeMutableBufferPointer { output in
            payload.withUnsafeBufferPointer { input in
                compression_encode_buffer(
                    output.baseAddress!, output.count,
                    input.baseAddress!, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written > 0 else { return nil }
        return Array(destination[0..<written])
    }

    // MARK: - CRC32

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

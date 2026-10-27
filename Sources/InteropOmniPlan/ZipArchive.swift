import Foundation
import Compression

/// 最小 zip 读取器（`.oplx` 的容器层，docs/features/11-interop-omniplan.md §2）。
///
/// 为什么自写而不引三方包：本条通道只需要「读两个成员」这一点能力，引入 ZIPFoundation
/// 之类的通用库会让一条格式通道背上第三方依赖与许可证/维护风险（14 §1 零依赖原则）。
///
/// 支持范围刻意收窄、超出即报错，不做 best-effort：
/// - 单卷、**不支持 ZIP64**；
/// - 压缩方法只认 stored(0) 与 deflate(8)（OmniPlan 一律 deflate）；
/// - 不校验 CRC（内容正确性由 XML 解析与字段断言负责）；不处理加密。
struct ZipArchive {
    /// 中央目录里的一条成员记录。
    struct Entry {
        let name: String
        let method: UInt16
        let compressedSize: Int
        let uncompressedSize: Int
        /// 该成员本地头在整包中的偏移。
        let localHeaderOffset: Int
    }

    /// zip 结构错误：由调用方翻译成 `InteropError.malformedDocument`。
    enum ZipError: Error, CustomStringConvertible {
        /// 不是 zip（找不到中央目录结束记录）。
        case notArchive
        /// 结构可识别但超出支持范围（ZIP64、未知压缩方法）。
        case unsupported(String)
        /// 结构损坏（偏移越界、长度不符）。
        case corrupt(String)

        var description: String {
            switch self {
            case .notArchive:
                return "不是 zip 容器：找不到中央目录结束记录（EOCD）"
            case .unsupported(let reason):
                return "zip 容器超出支持范围：\(reason)"
            case .corrupt(let reason):
                return "zip 容器结构损坏：\(reason)"
            }
        }
    }

    private static let endOfCentralDirectorySignature: UInt32 = 0x0605_4B50
    private static let centralDirectorySignature: UInt32 = 0x0201_4B50
    private static let localHeaderSignature: UInt32 = 0x0403_4B50
    /// EOCD 定长部分 22 字节 + 最多 64 KB 注释。
    private static let maxCommentLength = 65_535

    private let bytes: [UInt8]
    private let entries: [Entry]

    init(data: Data) throws {
        let bytes = [UInt8](data)
        self.bytes = bytes
        self.entries = try Self.readCentralDirectory(bytes)
    }

    /// 成员名（按中央目录顺序）。
    var entryNames: [String] { entries.map(\.name) }

    /// 按名字取成员；不存在返回 nil（是否算错误由调用方决定）。
    func entry(named name: String) -> Entry? {
        entries.first { $0.name == name }
    }

    /// 取成员内容（stored 直读 / deflate 解压）。
    func data(of entry: Entry) throws -> Data {
        guard entry.localHeaderOffset >= 0,
              entry.localHeaderOffset + 30 <= bytes.count,
              bytes.u32(at: entry.localHeaderOffset) == Self.localHeaderSignature else {
            throw ZipError.corrupt("成员「\(entry.name)」的本地头偏移无效")
        }
        let nameLength = bytes.u16(at: entry.localHeaderOffset + 26)
        let extraLength = bytes.u16(at: entry.localHeaderOffset + 28)
        let payloadStart = entry.localHeaderOffset + 30 + nameLength + extraLength
        guard payloadStart <= bytes.count,
              entry.compressedSize <= bytes.count - payloadStart else {
            throw ZipError.corrupt("成员「\(entry.name)」的数据超出容器尾部")
        }
        let payload = Array(bytes[payloadStart..<(payloadStart + entry.compressedSize)])
        switch entry.method {
        case 0:
            guard payload.count == entry.uncompressedSize else {
                throw ZipError.corrupt("成员「\(entry.name)」的 stored 长度与头记录不符")
            }
            return Data(payload)
        case 8:
            return try Self.inflate(payload, expectedSize: entry.uncompressedSize, name: entry.name)
        default:
            throw ZipError.unsupported("成员「\(entry.name)」使用压缩方法 \(entry.method)，只支持 stored(0) 与 deflate(8)")
        }
    }

    /// 取成员内容；缺失即报结构错误（`.oplx` 的必需成员用这个）。
    func requiredData(named name: String) throws -> Data {
        guard let entry = entry(named: name) else {
            throw ZipError.corrupt("缺少必需成员「\(name)」")
        }
        return try data(of: entry)
    }

    // MARK: - 中央目录

    private static func readCentralDirectory(_ bytes: [UInt8]) throws -> [Entry] {
        let eocd = try findEndOfCentralDirectory(bytes)
        let entryCount = Int(bytes.u16(at: eocd + 10))
        let directorySize = Int(bytes.u32(at: eocd + 12))
        let directoryOffset = Int(bytes.u32(at: eocd + 16))
        if entryCount == 0xFFFF || directorySize == 0xFFFF_FFFF || directoryOffset == 0xFFFF_FFFF {
            throw ZipError.unsupported("ZIP64 中央目录（单文件超过 4 GB 或多于 65535 个成员）")
        }
        guard directoryOffset >= 0, directoryOffset <= bytes.count,
              directorySize <= bytes.count - directoryOffset else {
            throw ZipError.corrupt("中央目录偏移越界")
        }

        var entries: [Entry] = []
        entries.reserveCapacity(entryCount)
        var cursor = directoryOffset
        for index in 0..<entryCount {
            guard cursor + 46 <= bytes.count, bytes.u32(at: cursor) == centralDirectorySignature else {
                throw ZipError.corrupt("第 \(index + 1) 条中央目录记录签名无效")
            }
            let method = UInt16(bytes.u16(at: cursor + 10))
            let compressedSize = Int(bytes.u32(at: cursor + 20))
            let uncompressedSize = Int(bytes.u32(at: cursor + 24))
            let nameLength = Int(bytes.u16(at: cursor + 28))
            let extraLength = Int(bytes.u16(at: cursor + 30))
            let commentLength = Int(bytes.u16(at: cursor + 32))
            let localHeaderOffset = Int(bytes.u32(at: cursor + 42))
            let nameStart = cursor + 46
            guard nameStart + nameLength <= bytes.count else {
                throw ZipError.corrupt("第 \(index + 1) 条中央目录记录的名字越界")
            }
            let name = String(decoding: bytes[nameStart..<(nameStart + nameLength)], as: UTF8.self)
            entries.append(
                Entry(
                    name: name,
                    method: method,
                    compressedSize: compressedSize,
                    uncompressedSize: uncompressedSize,
                    localHeaderOffset: localHeaderOffset
                )
            )
            cursor = nameStart + nameLength + extraLength + commentLength
        }
        return entries
    }

    /// 从尾部往前找 EOCD（zip 允许尾部最多 64 KB 注释）。
    private static func findEndOfCentralDirectory(_ bytes: [UInt8]) throws -> Int {
        guard bytes.count >= 22 else { throw ZipError.notArchive }
        let earliest = max(0, bytes.count - 22 - maxCommentLength)
        var cursor = bytes.count - 22
        while cursor >= earliest {
            if bytes.u32(at: cursor) == endOfCentralDirectorySignature { return cursor }
            cursor -= 1
        }
        throw ZipError.notArchive
    }

    // MARK: - deflate

    /// 用 Compression framework 解 raw deflate（RFC 1951，与 zlib 头无关）。
    private static func inflate(_ source: [UInt8], expectedSize: Int, name: String) throws -> Data {
        if expectedSize == 0 { return Data() }
        guard !source.isEmpty else {
            throw ZipError.corrupt("成员「\(name)」压缩数据为空但声明的长度是 \(expectedSize)")
        }
        var destination = [UInt8](repeating: 0, count: expectedSize)
        let written = destination.withUnsafeMutableBufferPointer { output in
            source.withUnsafeBufferPointer { input in
                compression_decode_buffer(
                    output.baseAddress!, output.count,
                    input.baseAddress!, input.count,
                    nil,
                    COMPRESSION_ZLIB
                )
            }
        }
        guard written == expectedSize else {
            throw ZipError.corrupt("成员「\(name)」解压长度不符（期望 \(expectedSize) 字节，实际 \(written)）")
        }
        return Data(destination)
    }
}

private extension Array where Element == UInt8 {
    /// 小端读取；调用方保证偏移有界。
    func u16(at offset: Int) -> Int {
        Int(self[offset]) | Int(self[offset + 1]) << 8
    }

    func u32(at offset: Int) -> UInt32 {
        UInt32(self[offset])
            | UInt32(self[offset + 1]) << 8
            | UInt32(self[offset + 2]) << 16
            | UInt32(self[offset + 3]) << 24
    }
}

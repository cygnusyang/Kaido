import Foundation
import Testing
import KairoInterop

/// `InteropError.normalized` 的契约测试：适配器读入口只允许把 `InteropError` 递给调用方。
///
/// 这条契约是跨平台的：同一份坏文件，macOS 与 Linux 的 FoundationXML / zip 实现抛的错误
/// 类型与错误码都不同（v1.3.0 Linux 作业即栽在截断 XML 被 recover 成「空计划」上）。
@Suite("互操作错误归一")
struct InteropErrorNormalizationTests {
    @Test("非 InteropError 归一到 malformedDocument，并保留原因")
    func mapsForeignError() throws {
        let underlying = NSError(
            domain: "NSXMLParserErrorDomain",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "第 1 行第 70 列：Premature end of data"]
        )
        do {
            _ = try InteropError.normalized { throw underlying }
            Issue.record("底层错误应当被归一，不能直接外泄")
        } catch let error as InteropError {
            guard case .malformedDocument(let reason) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(reason == "第 1 行第 70 列：Premature end of data")
        }
    }

    @Test("InteropError 原样透传：版本闸门的语义不被吞掉")
    func passesThroughInteropError() throws {
        let expected = InteropError.unsupportedFormatVersion(version: 99, supported: [12, 13, 14])
        do {
            _ = try InteropError.normalized { throw expected }
            Issue.record("应当抛错")
        } catch let error as InteropError {
            #expect(error == expected)
        }
    }

    @Test("正常返回值原样返回")
    func returnsValue() throws {
        let value = try InteropError.normalized { 42 }
        #expect(value == 42)
    }
}

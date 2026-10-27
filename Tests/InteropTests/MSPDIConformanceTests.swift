import Foundation
import Testing
import KairoInterop
import InteropMSPDI

/// MSPDI 适配器契约测试（14-interop-architecture §2 硬规则 4）。
///
/// 断言全部由 `AdapterConformanceSuite` 提供：本文件只负责「给样本」。
/// 新增一个格式通道时换样本即可，断言一行不改。
@Suite("MSPDI 适配器契约")
struct MSPDIConformanceTests {
    private let adapter = MSPDIAdapter()

    @Test("读入路径的契约用例全部达标")
    func conformanceSuite() throws {
        let cases = MSPDIFixtures.all.filter { testCase in
            if case .rejection = testCase.expectation { return false }
            return true
        }
        #expect(!cases.isEmpty)
        try AdapterConformanceSuite.check(adapter, cases: cases)
    }

    @Test("未知 SaveVersion 明确拒绝")
    func rejectsUnknownVersion() throws {
        let data = MSPDIFixtures.document("", saveVersion: 99)
        #expect(adapter.sniff(data))
        do {
            _ = try adapter.read(data)
            Issue.record("SaveVersion 99 应当被拒绝")
        } catch let error as InteropError {
            guard case .unsupportedFormatVersion(let version, let supported) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(version == 99)
            #expect(supported == [12, 13, 14])
        }
    }

    @Test("畸形输入统一抛 malformedDocument")
    func rejectsMalformed() throws {
        let cases = MSPDIFixtures.all.filter { testCase in
            if case .rejection(.malformed) = testCase.expectation { return true }
            return false
        }
        #expect(!cases.isEmpty)
        for testCase in cases {
            do {
                _ = try adapter.read(testCase.data)
                Issue.record("\(testCase.label) 应当被拒绝")
            } catch let error as InteropError {
                guard case .malformedDocument = error else {
                    Issue.record("\(testCase.label)：错误类型不对 \(error)")
                    continue
                }
            }
        }
    }

    @Test("能力声明与版本范围")
    func capabilities() {
        #expect(adapter.id == "mspdi")
        #expect(adapter.capabilities.canRead)
        #expect(!adapter.capabilities.canWrite)
        #expect(adapter.supportedVersions == [12, 13, 14])
    }

    @Test("写出未实现时给出明确错误，不静默成功")
    func writeNotSupported() {
        do {
            _ = try adapter.write(InteropDocument())
            Issue.record("P0 阶段写出应当抛 operationNotSupported")
        } catch let error as InteropError {
            guard case .operationNotSupported = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        } catch {
            Issue.record("抛出了非 InteropError：\(error)")
        }
    }

    @Test("预检报告带规模与版本")
    func preflight() throws {
        let data = try #require(MSPDIFixtures.all.first { $0.label.hasPrefix("群组") }?.data)
        let report = try adapter.preflight(data)
        #expect(report.formatID == "mspdi")
        #expect(report.formatVersion == "SaveVersion 14")
        #expect(report.summary.contains("3 任务"))
        #expect(report.summary.contains("1 汇总"))
    }

    @Test("注册表按 id 与内容都能选中适配器")
    func registry() {
        let registry = AdapterRegistry(adapters: [MSPDIAdapter()])
        #expect(registry.adapter(id: "mspdi") != nil)
        let data = MSPDIFixtures.document("")
        #expect(registry.adapter(sniffing: data)?.id == "mspdi")
        #expect(registry.adapter(sniffing: Data("hello".utf8)) == nil)
        #expect(registry.adapter(id: "omniplan") == nil)
    }
}

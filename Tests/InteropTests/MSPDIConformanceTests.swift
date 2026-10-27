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
        #expect(adapter.capabilities.canWrite)
        #expect(adapter.supportedVersions == [12, 13, 14])
    }

    @Test("写出后能被自己读回（契约级往返）")
    func writeRoundTrip() throws {
        for testCase in MSPDIFixtures.all {
            if case .rejection = testCase.expectation { continue }
            let document = try adapter.read(testCase.data)
            let reread = try adapter.read(try adapter.write(document))
            #expect(
                reread.tasks.count == document.tasks.count,
                "\(testCase.label)：任务数往返后从 \(document.tasks.count) 变成 \(reread.tasks.count)"
            )
            #expect(
                reread.tasks.map(\.title) == document.tasks.map(\.title),
                "\(testCase.label)：任务标题往返后不一致"
            )
            #expect(
                reread.tasks.map(\.kind) == document.tasks.map(\.kind),
                "\(testCase.label)：任务种类往返后不一致"
            )
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

    /// `preflight()` 是「拿清单的人」唯一入口，清单不能只有 IR 侧登记：
    /// 约束降级、任务 id 丢失这些只在 IR → Kairo 阶段发生，必须由装配处补齐。
    @Test("预检台账 = IR 登记 + 桥接追加，不重不漏")
    func preflightLedgerIsComplete() throws {
        let data = try #require(MSPDIFixtures.all.first { $0.label.hasPrefix("群组") }?.data)
        let document = try adapter.read(data)
        let report = try adapter.preflight(data)
        let bridged = KairoBridge().makeProject(from: document)

        // 两份来源各自的出处不变：IR 侧就是文档登记，桥接层就是桥接追加。
        #expect(report.irLedger == document.ledger)
        #expect(report.bridgeLedger == bridged.bridgeLedger)
        #expect(report.ledger == bridged.ledger)
        // 桥接层确实往台账里加了东西（任务 id 无法保留只在 IR → Kairo 阶段发生）。
        #expect(report.irLedger.entry(field: "taskID") == nil)
        #expect(report.ledger.entry(field: "taskID")?.count == 3)

        // 不重不漏：键集合是两份来源的并集，每条的计数是两份之和。
        let irIDs = Set(report.irLedger.entries.map(\.id))
        let bridgeIDs = Set(report.bridgeLedger.entries.map(\.id))
        #expect(Set(report.ledger.entries.map(\.id)) == irIDs.union(bridgeIDs))
        #expect(report.ledger.entries.count == irIDs.union(bridgeIDs).count)
        for entry in report.ledger.entries {
            let irCount = report.irLedger.entries.first { $0.id == entry.id }?.count ?? 0
            let bridgeCount = report.bridgeLedger.entries.first { $0.id == entry.id }?.count ?? 0
            #expect(entry.count == irCount + bridgeCount, "\(entry.id) 计数与两份来源之和不符")
        }
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

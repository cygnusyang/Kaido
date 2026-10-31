import Foundation
import Testing
import KaidoInterop
import InteropOmniPlan

/// OmniPlan 适配器契约测试（14-interop-architecture §2 硬规则 4）。
///
/// 断言全部来自 \`AdapterConformanceSuite\`：本文件只负责「给样本」。
/// 与 MSPDI 通道用的是同一套用例与同一个套件，只是样本换成 \`.oplx\`——
/// 这就是「两条通道互相独立、各自达标」的可验证形式。
@Suite("OmniPlan 适配器契约")
struct OmniPlanConformanceTests {
    private let adapter = OmniPlanAdapter()

    /// 契约用例：合成容器覆盖空计划/单任务/群组/里程碑/中文 emoji/日历/拒绝路径，
    /// 四型依赖与前导时间用 OmniPlan 自己写出的真实容器。
    private func cases() throws -> [AdapterConformanceCase] {
        let fourDependencies = try OPLXFixture.committed("omniplan-four-dependencies.oplx")
        return [
            AdapterConformanceCase(
                label: "空计划",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(),
                    scenario: OPLXFixture.scenario(
                        tasks: "<task id=\"t-1\"><type>group</type></task>",
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .emptyPlan
            ),
            AdapterConformanceCase(
                label: "单任务",
                // 大纲根就是那一支任务：\`top-task\` 指向叶节点在结构上合法，
                // 这样才能只用一个任务压「单任务」这条契约。
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(),
                    scenario: OPLXFixture.scenario(
                        tasks: "<task id=\"t1\"><title>设计</title><effort>28800</effort></task>",
                        resources: OPLXFixture.projectResource(),
                        topTaskID: "t1"
                    )
                ),
                expectation: .singleTask(title: "设计")
            ),
            AdapterConformanceCase(
                label: "四类依赖",
                data: fourDependencies,
                expectation: .fourDependencyTypes
            ),
            AdapterConformanceCase(
                label: "前导时间 3600 秒",
                data: fourDependencies,
                expectation: .lag(seconds: 3600)
            ),
            AdapterConformanceCase(
                label: "里程碑",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(),
                    scenario: OPLXFixture.scenario(
                        tasks: """
                        <task id="t-1"><type>group</type><child-task idref="t1"/></task>
                        <task id="t1"><title>回样</title><type>milestone</type></task>
                        """,
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .milestoneCount(1)
            ),
            AdapterConformanceCase(
                label: "群组与子任务",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(),
                    scenario: OPLXFixture.scenario(
                        tasks: """
                        <task id="t-1"><type>group</type><child-task idref="t1"/><child-task idref="t2"/></task>
                        <task id="t1"><title>甲</title><effort>28800</effort></task>
                        <task id="t2"><title>乙</title><effort>28800</effort></task>
                        """,
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .groupWithChildren(minChildren: 2)
            ),
            AdapterConformanceCase(
                label: "项目日历",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(hoursPerDay: 16),
                    scenario: OPLXFixture.scenario(
                        tasks: "<task id=\"t-1\"><type>group</type></task>",
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .calendarCount(1)
            ),
            AdapterConformanceCase(
                label: "基线不导入（只有 Actual 场景进 IR）",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(
                        scenarios: [("Actual", "Actual.xml"), ("Initial Baseline", "base.xml")]
                    ),
                    scenario: OPLXFixture.scenario(
                        tasks: "<task id=\"t-1\"><type>group</type></task>",
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .baselineCount(0)
            ),
            AdapterConformanceCase(
                label: "中文与 emoji 标题",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(),
                    scenario: OPLXFixture.scenario(
                        tasks: """
                        <task id="t-1"><type>group</type><child-task idref="t1"/></task>
                        <task id="t1"><title>设计评审 🚀</title><effort>7200</effort></task>
                        """,
                        resources: OPLXFixture.projectResource()
                    )
                ),
                expectation: .unicodeTitle("设计评审 🚀")
            ),
            AdapterConformanceCase(
                label: "未知文件版本",
                data: OPLXFixture.archive(
                    toc: OPLXFixture.toc(fileFormatVersion: 4),
                    scenario: OPLXFixture.scenario(tasks: "<task id=\"t-1\"/>")
                ),
                expectation: .rejection(.unsupportedVersion)
            ),
            AdapterConformanceCase(
                label: "缺少 __TOC.xml",
                data: OPLXFixture.archive([(name: "Actual.xml", content: OPLXFixture.scenario(tasks: ""))]),
                expectation: .rejection(.malformed)
            )
        ]
    }

    @Test("读入路径的契约用例全部达标")
    func conformanceSuite() throws {
        let readCases = try cases().filter { testCase in
            if case .rejection = testCase.expectation { return false }
            return true
        }
        #expect(!readCases.isEmpty)
        try AdapterConformanceSuite.check(adapter, cases: readCases)
    }

    @Test("拒绝路径：未知版本与畸形输入")
    func rejectionCases() throws {
        let rejected = try cases().filter { testCase in
            if case .rejection = testCase.expectation { return true }
            return false
        }
        #expect(rejected.count == 2)
        try AdapterConformanceSuite.check(adapter, cases: rejected)
    }

    @Test("未知 file-format-version 明确拒绝，并给出支持范围")
    func rejectsUnknownVersion() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(fileFormatVersion: 4),
            scenario: OPLXFixture.scenario(tasks: "<task id=\"t-1\"/>")
        )
        #expect(adapter.sniff(data))
        do {
            _ = try adapter.read(data)
            Issue.record("file-format-version 4 应当被拒绝")
        } catch let error as InteropError {
            guard case .unsupportedFormatVersion(let version, let supported) = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
            #expect(version == 4)
            #expect(supported == [3])
        }
    }

    @Test("版本闸门先于场景解析：场景坏掉也必须先报版本")
    func versionGateBeforeScenarioParsing() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(fileFormatVersion: 5),
            scenario: "<scenario><task id=\"t1\">这不是合法结构"
        )
        do {
            _ = try adapter.read(data)
            Issue.record("应当先报版本不支持")
        } catch let error as InteropError {
            guard case .unsupportedFormatVersion = error else {
                Issue.record("应先报版本，实际：\(error)")
                return
            }
        }
    }

    @Test("垃圾字节（非 zip）抛 malformedDocument，不把底层解压错误漏给调用方")
    func rejectsGarbageBytes() throws {
        // 随机字节：没有 zip 本地头，容器层就该拒绝，进不到 XML 解析。
        let data = Data([0x00, 0xFF, 0x13, 0x37, 0x41, 0x7F, 0x80, 0x0A, 0xFE, 0x01])
        #expect(!adapter.sniff(data))
        do {
            _ = try adapter.read(data)
            Issue.record("垃圾字节应当被拒绝")
        } catch let error as InteropError {
            guard case .malformedDocument = error else {
                Issue.record("错误类型不对：\(error)")
                return
            }
        }
    }

    @Test("能力声明：可读写、支持日历与基线、版本只有 3")
    func capabilities() {
        #expect(adapter.id == "omniplan")
        #expect(adapter.capabilities.canRead)
        #expect(adapter.capabilities.canWrite)
        #expect(adapter.capabilities.supportsCalendars)
        #expect(adapter.capabilities.supportsBaselines)
        #expect(adapter.supportedVersions == [3])
    }

    @Test("能力声明与行为一致：canWrite 为真时写出的容器能被自己读回")
    func writeProducesReadableContainer() throws {
        let document = try adapter.read(
            OPLXFixture.archive(
                toc: OPLXFixture.toc(),
                scenario: OPLXFixture.scenario(
                    tasks: """
                    <task id="t-1"><type>group</type><child-task idref="t1"/></task>
                    <task id="t1"><title>设计</title><effort>28800</effort></task>
                    """,
                    resources: OPLXFixture.projectResource()
                )
            )
        )
        let data = try adapter.write(document)
        #expect(adapter.sniff(data))
        let reread = try adapter.read(data)
        #expect(reread.tasks.map(\.title) == document.tasks.map(\.title))
        #expect(reread.tasks.map(\.outlineLevel) == document.tasks.map(\.outlineLevel))
    }

    @Test("预检报告带版本、规模与完整有损台账（适配器层 + 桥接追加）")
    func preflight() throws {
        let data = try OPLXFixture.committed("omniplan-four-dependencies.oplx")
        let report = try adapter.preflight(data)
        #expect(report.formatID == "omniplan")
        #expect(report.formatVersion == "file-format-version 3")
        #expect(report.summary.contains("7 任务"))
        #expect(report.summary.contains("2 汇总"))
        #expect(report.irLedger.entry(field: "task.duration") != nil)

        // 台账必须包含桥接层追加项：只报 IR 侧会让用户看不见导入时才发生的损失。
        let document = try adapter.read(data)
        #expect(report.irLedger == document.ledger)
        #expect(report.ledger.entries.count >= document.ledger.entries.count)
        #expect(report.bridgeLedger.entries.isEmpty == false)
        #expect(report.ledger.entry(field: "constraint") != nil)
    }

    @Test("注册表按 id 与内容都能选中适配器，别的 zip 不误判")
    func registry() throws {
        let registry = AdapterRegistry(adapters: [OmniPlanAdapter()])
        #expect(registry.adapter(id: "omniplan") != nil)

        let data = try OPLXFixture.committed("omniplan-four-dependencies.oplx")
        #expect(registry.adapter(sniffing: data)?.id == "omniplan")
        #expect(registry.adapter(id: "mspdi") == nil)

        // 普通 zip（成员名不含 __TOC.xml / Actual.xml）不能被认成 .oplx。
        let plainZip = OPLXFixture.archive([(name: "readme.txt", content: "hello")])
        #expect(adapter.sniff(plainZip) == false)
        #expect(adapter.sniff(Data("<?xml version=\"1.0\"?><Project/>".utf8)) == false)
    }
}

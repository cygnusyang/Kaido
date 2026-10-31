import Foundation
import Testing
import KaidoInterop
import InteropOmniPlan

/// OmniPlan 读入细节：四型依赖与前导秒、日历例外、工时换算、基线登记。
///
/// 契约套件只管「形状」；这个文件管「值对不对」——每个断言都对应
/// docs/features/11-interop-omniplan.md 的一条实测结论。
@Suite("OmniPlan 读入细节")
struct OmniPlanReadTests {
    private let adapter = OmniPlanAdapter()
    private let epoch2001 = Date(timeIntervalSince1970: 978_307_200)

    @Test("四型依赖与 lead 秒：SS 3600 / FF 7200 / SF 0 / FS 1800")
    func dependencyKindsAndLead() throws {
        // 这份容器由 OmniPlan 4.10.3 自己写出（deflate），不是手搓的 XML。
        let document = try adapter.read(try OPLXFixture.committed("omniplan-four-dependencies.oplx"))
        let edges = document.tasks.flatMap { task in
            task.dependencies.map { (task.title, $0) }
        }
        #expect(edges.count == 4)

        func edge(_ title: String) throws -> InteropDependency {
            try #require(edges.first { $0.0 == title }?.1)
        }

        let ss = try edge("B")
        #expect(ss.type == .startToStart)
        #expect(ss.predecessorID == "t2")
        #expect(abs(ss.lagSeconds - 3600) < 0.5)

        let ff = try edge("C")
        #expect(ff.type == .finishToFinish)
        #expect(abs(ff.lagSeconds - 7200) < 0.5)

        let sf = try edge("D")
        #expect(sf.type == .startToFinish)
        #expect(sf.lagSeconds == 0)

        // kind 缺省 = FS（OmniPlan 原生写法省略 kind），lead 仍是 1800 秒。
        let fs = try edge("G")
        #expect(fs.type == .finishToStart)
        #expect(abs(fs.lagSeconds - 1800) < 0.5)
    }

    @Test("负 lead 即 lag：按秒原样进 IR，不在适配器里换算成天")
    func negativeLead() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(),
            scenario: OPLXFixture.scenario(
                tasks: """
                <task id="t-1"><type>group</type><child-task idref="t1"/><child-task idref="t2"/></task>
                <task id="t1"><title>前置</title><effort>28800</effort></task>
                <task id="t2"><title>后继</title><effort>28800</effort>
                  <prerequisite-task idref="t1"><lead-time is-percentage="false">-5400</lead-time></prerequisite-task>
                </task>
                """,
                resources: OPLXFixture.projectResource()
            )
        )
        let document = try adapter.read(data)
        let dependency = try #require(document.tasks.flatMap { $0.dependencies }.first)
        #expect(dependency.type == .finishToStart)
        #expect(dependency.lagSeconds == -5400)
    }

    @Test("工时换算：hours-per-day 从 duration-format 读，不写死 8")
    func hoursPerDayConversion() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(hoursPerDay: 16),
            scenario: OPLXFixture.scenario(
                tasks: """
                <task id="t-1"><type>group</type><child-task idref="t1"/></task>
                <task id="t1"><title>开题</title><effort>1008000</effort></task>
                """,
                resources: OPLXFixture.projectResource()
            )
        )
        let document = try adapter.read(data)
        let calendar = try #require(document.calendars.first)
        #expect(calendar.hoursPerDay == 16)

        // effort 秒 → IR 只做「秒 → 小时」，人日换算留给 KaidoBridge。
        let task = try #require(document.tasks.first { $0.id == "t1" })
        #expect(task.durationSeconds == 1_008_000)
        #expect(task.effortHours == 280)

        let entry = try #require(document.ledger.entry(field: "calendar.hoursPerDay"))
        #expect(entry.kind == .converted)
        #expect(entry.samples.contains { $0.contains("16") })

        let duration = try #require(document.ledger.entry(field: "task.duration"))
        #expect(duration.kind == .converted)
        #expect(duration.count == 1)
    }

    @Test("日历例外：Time Off 停工整天、Overtime 加班整天，半天事件降级登记")
    func calendarExceptions() throws {
        let schedule = """
        <schedule>
          <schedule-day day-of-week="monday"><time-span start-time="28800" end-time="86400"/></schedule-day>
          <schedule-day day-of-week="tuesday"><time-span start-time="28800" end-time="86400"/></schedule-day>
          <calendar name="Time Off" editable="yes" overtime="no">
            <event sd="9189" st="0" ed="9189" et="86400"/>
            <event sd="9200" st="28800" ed="9200" et="43200"/>
          </calendar>
          <calendar name="Overtime" editable="yes" overtime="yes">
            <event sd="9210" st="0" ed="9210" et="86400"/>
            <event sd="9211" st="64800" ed="9211" et="75600"/>
          </calendar>
        </schedule>
        """
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(),
            scenario: OPLXFixture.scenario(
                tasks: "<task id=\"t-1\"><type>group</type></task>",
                resources: OPLXFixture.projectResource(schedule: schedule)
            )
        )
        let document = try adapter.read(data)
        let calendar = try #require(document.calendars.first)
        #expect(calendar.workingWeekdays == Set([2, 3]))
        #expect(calendar.exceptions.count == 3)

        func day(_ offset: Int) -> Date {
            epoch2001.addingTimeInterval(Double(offset) * 86_400)
        }
        #expect(calendar.exceptions[0].date == day(9189))
        #expect(calendar.exceptions[0].isWorking == false)
        #expect(calendar.exceptions[1].date == day(9200))
        #expect(calendar.exceptions[1].isWorking == false)
        #expect(calendar.exceptions[2].date == day(9210))
        #expect(calendar.exceptions[2].isWorking == true)

        let converted = try #require(document.ledger.entry(field: "calendar.exception"))
        #expect(converted.kind == .converted)
        #expect(converted.count == 3)

        // 半天请假与半天加班都无法落成整天例外。
        let partial = try #require(document.ledger.entry(field: "calendar.exception.partial"))
        #expect(partial.kind == .degraded)
        #expect(partial.count == 2)
    }

    @Test("基线 scenario 不导入，但必须登记")
    func baselineScenariosAreRegistered() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(
                scenarios: [
                    ("Actual", "Actual.xml"),
                    ("Initial Baseline", "base1.xml"),
                    ("2026-10 冻结", "base2.xml")
                ]
            ),
            scenario: OPLXFixture.scenario(
                tasks: "<task id=\"t-1\"><type>group</type></task>",
                resources: OPLXFixture.projectResource()
            )
        )
        let document = try adapter.read(data)
        #expect(document.baselines.isEmpty)
        let entry = try #require(document.ledger.entry(field: "baseline"))
        #expect(entry.kind == .dropped)
        #expect(entry.count == 2)
        #expect(entry.samples.contains("Initial Baseline"))
    }

    @Test("层级与顺序：depth-first 展开，父节点在子节点之前")
    func outlineOrder() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(),
            scenario: OPLXFixture.scenario(
                tasks: """
                <task id="t-1"><type>group</type><child-task idref="t1"/><child-task idref="t4"/></task>
                <task id="t1"><title>阶段</title><type>group</type><child-task idref="t2"/><child-task idref="t3"/></task>
                <task id="t2"><title>甲</title><effort>28800</effort></task>
                <task id="t3"><title>乙</title><effort>28800</effort></task>
                <task id="t4"><title>丙</title><effort>28800</effort></task>
                """,
                resources: OPLXFixture.projectResource()
            )
        )
        let document = try adapter.read(data)
        #expect(document.tasks.map(\.title) == ["", "阶段", "甲", "乙", "丙"])
        #expect(document.tasks.map(\.outlineLevel) == [0, 1, 2, 2, 1])
        #expect(document.tasks.map(\.sequence) == [0, 1, 2, 3, 4])
        #expect(document.tasks[2].parentID == "t1")
        #expect(document.tasks[4].parentID == "t-1")
    }

    @Test("不在大纲树上的任务登记丢弃，不静默消失")
    func orphanTask() throws {
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(),
            scenario: OPLXFixture.scenario(
                tasks: """
                <task id="t-1"><type>group</type><child-task idref="t1"/></task>
                <task id="t1"><title>在树上</title><effort>3600</effort></task>
                <task id="t9"><title>孤儿</title><effort>3600</effort></task>
                """,
                resources: OPLXFixture.projectResource()
            )
        )
        let document = try adapter.read(data)
        #expect(document.tasks.count == 2)
        let entry = try #require(document.ledger.entry(field: "task.orphan"))
        #expect(entry.count == 1)
        #expect(entry.samples == ["孤儿"])
    }

    @Test("分配：units 缺省为 1，指向不存在的资源登记丢弃")
    func assignments() throws {
        let resources = OPLXFixture.projectResource() + """
        <resource id="r2"><name>张三</name><type>Staff</type></resource>
        """
        let data = OPLXFixture.archive(
            toc: OPLXFixture.toc(),
            scenario: OPLXFixture.scenario(
                tasks: """
                <task id="t-1"><type>group</type><child-task idref="t1"/><child-task idref="t2"/></task>
                <task id="t1"><title>甲</title><effort>28800</effort><assignment idref="r2" units="0.5"/></task>
                <task id="t2"><title>乙</title><effort>28800</effort><assignment idref="r99"/></task>
                """,
                resources: resources
            )
        )
        let document = try adapter.read(data)
        #expect(document.assignments.count == 1)
        #expect(document.assignments.first?.resourceID == "r2")
        #expect(document.assignments.first?.units == 0.5)
        #expect(document.ledger.entry(field: "assignment")?.count == 1)
    }
}

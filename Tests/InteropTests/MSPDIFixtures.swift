import Foundation
import KairoInterop
import InteropMSPDI

/// MSPDI 契约测试样本（手写最小 XML）。
///
/// P0 阶段只验证「读得对、拒绝得明确」；P1 的写出往返由 MSPDIWriteTests 用同一批样本
/// 再跑一遍（MSPDIConformanceTests.writeRoundTrip），样本不必另写。
/// 写法上只保留判据需要的元素，避免样本一改就要跟着改断言。
enum MSPDIFixtures {
    static let all: [AdapterConformanceCase] = [
        AdapterConformanceCase(
            label: "空计划",
            data: document(""),
            expectation: .emptyPlan
        ),
        AdapterConformanceCase(
            label: "单任务",
            data: document(tasksBlock([task(uid: 1, name: "唯一任务")])),
            expectation: .singleTask(title: "唯一任务")
        ),
        AdapterConformanceCase(
            label: "四类依赖",
            data: document(tasksBlock(fourDependencyTasks)),
            expectation: .fourDependencyTypes
        ),
        AdapterConformanceCase(
            label: "lag（1 天 = 8h = 4800 个十分之一分钟）",
            data: document(tasksBlock([
                task(uid: 1, name: "前驱"),
                task(uid: 2, name: "后继", extra: """
                    <PredecessorLink>
                        <PredecessorUID>1</PredecessorUID>
                        <Type>1</Type>
                        <LinkLag>4800</LinkLag>
                    </PredecessorLink>
                    """)
            ])),
            expectation: .lag(seconds: 28_800)
        ),
        AdapterConformanceCase(
            label: "里程碑",
            data: document(tasksBlock([task(uid: 1, name: "评审通过", milestone: true)])),
            expectation: .milestoneCount(1)
        ),
        AdapterConformanceCase(
            label: "群组（汇总任务 + 两个子任务）",
            data: document(tasksBlock([
                task(uid: 1, name: "阶段一", outlineLevel: 1, summary: true),
                task(uid: 2, name: "子任务 A", outlineLevel: 2),
                task(uid: 3, name: "子任务 B", outlineLevel: 2)
            ])),
            expectation: .groupWithChildren(minChildren: 2)
        ),
        AdapterConformanceCase(
            label: "多日历",
            data: document(calendarsBlock([(1, "标准", [2, 3, 4, 5, 6]), (2, "全周", [1, 2, 3, 4, 5, 6, 7])])
                + tasksBlock([task(uid: 1, name: "任务")])),
            expectation: .calendarCount(2)
        ),
        AdapterConformanceCase(
            label: "基线",
            data: document(tasksBlock([task(uid: 1, name: "任务", extra: baseline(number: 0))])),
            expectation: .baselineCount(1)
        ),
        AdapterConformanceCase(
            label: "中文与 emoji",
            data: document(tasksBlock([task(uid: 1, name: "中文标题 🎯 emoji")])),
            expectation: .unicodeTitle("中文标题 🎯 emoji")
        ),
        AdapterConformanceCase(
            label: "未知版本（SaveVersion 99）",
            data: document("", saveVersion: 99),
            expectation: .rejection(.unsupportedVersion)
        ),
        AdapterConformanceCase(
            label: "畸形 XML（截断）",
            data: Data("<Project xmlns=\"http://schemas.microsoft.com/project\"><SaveVersion>14".utf8),
            expectation: .rejection(.malformed)
        ),
        AdapterConformanceCase(
            label: "命名空间不对",
            data: Data("""
                <?xml version="1.0" encoding="UTF-8"?>
                <Project xmlns="http://example.com/not-project"><SaveVersion>14</SaveVersion></Project>
                """.utf8),
            expectation: .rejection(.malformed)
        )
    ]

    // MARK: - 组装

    /// 拼一份最小 MSPDI 文档。
    static func document(_ body: String, saveVersion: Int = 14) -> Data {
        let xml = """
            <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
            <Project xmlns="http://schemas.microsoft.com/project">
                <SaveVersion>\(saveVersion)</SaveVersion>
                <Name>fixture</Name>
                <Title>契约样本</Title>
                <CreationDate>2026-01-01T09:00:00</CreationDate>
                <LastSaved>2026-01-02T09:00:00</LastSaved>
                <ScheduleFromStart>1</ScheduleFromStart>
                <StartDate>2026-01-05T08:00:00</StartDate>
                <FinishDate>2026-01-30T17:00:00</FinishDate>
                <CalendarUID>1</CalendarUID>
                <MinutesPerDay>480</MinutesPerDay>
                <MinutesPerWeek>2400</MinutesPerWeek>
            \(body)
            </Project>
            """
        return Data(xml.utf8)
    }

    static func calendarsBlock(_ calendars: [(uid: Int, name: String, workingDays: [Int])]) -> String {
        let items = calendars.map { calendar -> String in
            let weekdays = (1...7).map { day -> String in
                let working = calendar.workingDays.contains(day)
                let times = working
                    ? """
                      <WorkingTimes>
                                  <WorkingTime><FromTime>08:00:00</FromTime><ToTime>12:00:00</ToTime></WorkingTime>
                                  <WorkingTime><FromTime>13:00:00</FromTime><ToTime>17:00:00</ToTime></WorkingTime>
                              </WorkingTimes>
                      """
                    : ""
                return """
                    <WeekDay>
                            <DayType>\(day)</DayType>
                            <DayWorking>\(working ? 1 : 0)</DayWorking>
                            \(times)
                        </WeekDay>
                    """
            }.joined(separator: "\n")
            return """
                <Calendar>
                        <UID>\(calendar.uid)</UID>
                        <Name>\(calendar.name)</Name>
                        <IsBaseCalendar>1</IsBaseCalendar>
                        <WeekDays>
                    \(weekdays)
                        </WeekDays>
                    </Calendar>
                """
        }.joined(separator: "\n")
        return "<Calendars>\n\(items)\n</Calendars>"
    }

    static func tasksBlock(_ tasks: [String]) -> String {
        "<Tasks>\n" + tasks.joined(separator: "\n") + "\n</Tasks>"
    }

    static func task(
        uid: Int,
        name: String,
        outlineLevel: Int = 1,
        summary: Bool = false,
        milestone: Bool = false,
        extra: String = ""
    ) -> String {
        """
        <Task>
                <UID>\(uid)</UID>
                <ID>\(uid)</ID>
                <Name>\(name)</Name>
                <OutlineLevel>\(outlineLevel)</OutlineLevel>
                <Summary>\(summary ? 1 : 0)</Summary>
                <Milestone>\(milestone ? 1 : 0)</Milestone>
                <IsNull>0</IsNull>
                <Start>2026-01-05T08:00:00</Start>
                <Finish>2026-01-06T17:00:00</Finish>
                <Duration>PT16H0M0S</Duration>
                <PercentComplete>\(milestone ? 0 : 40)</PercentComplete>
                <ConstraintType>0</ConstraintType>
                <CalendarUID>-1</CalendarUID>
                \(extra)
            </Task>
        """
    }

    static func baseline(number: Int) -> String {
        """
        <Baseline>
                <Number>\(number)</Number>
                <Start>2026-01-05T08:00:00</Start>
                <Finish>2026-01-06T17:00:00</Finish>
            </Baseline>
        """
    }

    /// 四个前驱、四种类型（0=FF / 1=FS / 2=SF / 3=SS）。
    private static var fourDependencyTasks: [String] {
        [
            task(uid: 1, name: "前驱 A"),
            task(uid: 2, name: "前驱 B"),
            task(uid: 3, name: "前驱 C"),
            task(uid: 4, name: "前驱 D"),
            task(uid: 5, name: "后继", extra: """
                <PredecessorLink><PredecessorUID>1</PredecessorUID><Type>0</Type><LinkLag>0</LinkLag></PredecessorLink>
                        <PredecessorLink><PredecessorUID>2</PredecessorUID><Type>1</Type><LinkLag>0</LinkLag></PredecessorLink>
                        <PredecessorLink><PredecessorUID>3</PredecessorUID><Type>2</Type><LinkLag>0</LinkLag></PredecessorLink>
                        <PredecessorLink><PredecessorUID>4</PredecessorUID><Type>3</Type><LinkLag>0</LinkLag></PredecessorLink>
                """)
        ]
    }
}

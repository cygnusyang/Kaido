import Foundation
import Testing
import KairoCore
import KairoCommands

/// 示例数据在「启动窗口 = [今天, 今天+7)」下的**可见性**契约。
///
/// 判据数的是「排期结果经布局后的可见条」，不是任务字段。上一轮就是拿 dueDate 数出
/// 8/10，而 bar 的判据是半开区间 `finish > windowStart && start < windowEnd`：
/// 无前驱任务按 ASAP 从项目起点起排，dueDate 根本不参与条的位置。所以这里走真实会话
/// 排期（`KairoSession.scheduleOrCompute`），再用 `GanttLayoutEngine` 取条，
/// 判据与用户看到的画面同源，不会再和真实排期脱钩。
@Suite("示例数据在启动窗口内的可见性")
struct StartupWindowSeedVisibilityTests {
    /// 与 store 同源的日历：格里高利历 + 本机时区。
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar
    }

    /// 启动窗口口径：7 天、画布 518pt（日宽 = 518 / 7）。
    private enum StartupWindow {
        static let days = 7
        static let canvasWidth: Double = 518
    }

    /// 真实会话 + 真实排期：示例项目灌进会话后取排期结果。
    private func scheduledSeed() throws -> (tasks: [TaskItem], schedule: ScheduleResult) {
        let project = SeedData.makeProject()
        let session = KairoSession()
        _ = try session.createProject(title: project.metadata.title)
        try session.restore(
            ProjectState(
                metadata: project.metadata,
                tasks: project.tasks,
                resources: project.resources
            )
        )
        let schedule = try session.scheduleOrCompute()
        return (project.tasks, schedule)
    }

    private func startupLayout(
        tasks: [TaskItem],
        schedule: ScheduleResult,
        now: Date
    ) -> GanttLayout {
        let today = calendar.startOfDay(for: now)
        return GanttLayoutEngine.make(
            tasks: tasks,
            schedule: schedule,
            calendar: calendar,
            locale: Locale(identifier: "zh_CN"),
            zoom: .week,
            viewWidth: StartupWindow.canvasWidth,
            windowStart: today,
            dayWidthOverride: StartupWindow.canvasWidth / Double(StartupWindow.days),
            today: today
        )
    }

    /// 首屏不能近乎空白：示例里大多数任务应落在启动窗口内。
    ///
    /// 断言用「至少 6 条」而不是精确条数：示例的日期是相对 `now` 的偏移，示例调整时
    /// 不该因为多一条少一条就红；真正会红的场景是又回到「首屏只有两三条」。
    @Test func firstScreenShowsMostSampleTasks() throws {
        let now = Date()
        let (tasks, schedule) = try scheduledSeed()
        let layout = startupLayout(tasks: tasks, schedule: schedule, now: now)

        #expect(
            layout.bars.count >= 6,
            "启动窗口内可见条数掉到 \(layout.bars.count)/\(tasks.count)：示例又漂到窗口外了"
        )
        #expect(layout.bars.count <= tasks.count, "条数不可能超过任务数")
        // 半开窗口：跨度 7 天（允许跨夏令时的亚秒级误差）。
        let span = layout.windowEnd.timeIntervalSince(layout.windowStart)
        #expect(abs(span - Double(StartupWindow.days) * 86_400) < 1, "窗口跨度应为 7 天")
    }

    /// 可见性契约的正面表述：每条画出来的条都必须真的与窗口重叠。
    ///
    /// 防止的是「布局把窗口外的条也吐出来」这类回归——那时视图会画到画布外。
    @Test func everyVisibleBarOverlapsTheWindow() throws {
        let now = Date()
        let (tasks, schedule) = try scheduledSeed()
        let layout = startupLayout(tasks: tasks, schedule: schedule, now: now)
        let byID = Dictionary(uniqueKeysWithValues: schedule.tasks.map { ($0.taskID, $0) })

        #expect(!layout.bars.isEmpty, "前置条件：至少有一条可见条")
        for bar in layout.bars {
            let scheduled = try #require(byID[bar.taskID])
            #expect(scheduled.scheduledFinish > layout.windowStart, "条的结束必须晚于窗口起点（半开区间）")
            #expect(scheduled.scheduledStart < layout.windowEnd, "条的开始必须早于窗口终点（半开区间）")
        }
    }

    /// 窗口外要有内容，否则「逾期 / 远期」两条演示路径没有样本。
    ///
    /// 这两条是示例数据的产品契约：一条逾期（演示逾期与时限违例）、一条远期（演示窗口外），
    /// 它们必须**不**出现在首屏条里。示例调整时若把这两条也拉进窗口，用例会立刻红。
    @Test func overdueAndFarFutureSamplesStayOutOfTheWindow() throws {
        let now = Date()
        let today = calendar.startOfDay(for: now)
        let (tasks, schedule) = try scheduledSeed()
        let layout = startupLayout(tasks: tasks, schedule: schedule, now: now)
        let barIDs = Set(layout.bars.map(\.taskID))

        let overdue = schedule.tasks.filter { $0.scheduledFinish <= today }
        let farFuture = schedule.tasks.filter { $0.scheduledStart >= layout.windowEnd }
        #expect(!overdue.isEmpty, "示例应保留至少一条逾期任务作为演示样本")
        #expect(!farFuture.isEmpty, "示例应保留至少一条远期任务作为演示样本")
        for entry in overdue {
            #expect(!barIDs.contains(entry.taskID), "逾期任务不应出现在启动窗口内")
        }
        for entry in farFuture {
            #expect(!barIDs.contains(entry.taskID), "远期任务不应出现在启动窗口内")
        }
        #expect(overdue.count + farFuture.count + layout.bars.count <= tasks.count + 1)
    }
}

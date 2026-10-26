import Foundation
import Testing
import KairoCommands
import KairoCore
import KairoPresentation
@testable import KairoMacApp

/// 项目设置 / 工作日历的应用层行为（F-22-06）。
///
/// 覆盖三件事：草稿模型的折算规则（模板 / 例外日 / 全默认 ⇒ 不落键）、
/// 写入是否进撤销栈且一步可回退、以及顺延留痕的文案组装。
@MainActor
@Suite("项目设置 / 工作日历")
struct ProjectSettingsTests {

    private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current
        return calendar.date(from: DateComponents(year: year, month: month, day: dayOfMonth)) ?? Date()
    }

    private func makeStore() -> WorkspaceStore {
        let suite = "kairo.apptests.calendar.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite) ?? .standard
        defaults.removePersistentDomain(forName: suite)
        return WorkspaceStore(
            defaults: defaults,
            seedsDemoData: true,
            projectLoader: { try KairoFile.read(from: $0) }
        )
    }

    // MARK: - 草稿模型

    @Test func draftDerivesTemplateFromStoredWeekdays() {
        #expect(WorkCalendarDraft(calendar: nil).template == .sevenDays)
        #expect(WorkCalendarDraft(calendar: WorkCalendar()).template == .sevenDays)
        #expect(
            WorkCalendarDraft(calendar: WorkCalendar(workingWeekdays: [2, 3, 4, 5, 6])).template
                == .fiveDays
        )
        #expect(
            WorkCalendarDraft(calendar: WorkCalendar(workingWeekdays: [2, 3, 4, 5, 6, 7])).template
                == .sixDays
        )
        #expect(
            WorkCalendarDraft(calendar: WorkCalendar(workingWeekdays: [2, 4, 6])).template
                == .custom
        )
    }

    @Test func selectingPresetReplacesWeekdays() {
        var draft = WorkCalendarDraft(calendar: nil)
        draft.select(.fiveDays)
        #expect(draft.weekdays == WorkCalendar.mondayToFriday)
        draft.select(.custom)
        #expect(draft.weekdays == WorkCalendar.mondayToFriday, "自定义不改动已选上班日")
        draft.toggle(7)
        #expect(draft.weekdays == [2, 3, 4, 5, 6, 7])
        #expect(draft.template == .sixDays)
    }

    @Test func lastWorkingDayCannotBeTurnedOff() {
        var draft = WorkCalendarDraft(calendar: WorkCalendar(workingWeekdays: [2]))
        draft.toggle(2)
        #expect(draft.weekdays == [2], "空工作周会被引擎退化成全周，界面必须挡住")
        draft.toggle(3)
        draft.toggle(2)
        #expect(draft.weekdays == [3])
    }

    @Test func sameDayExceptionReplacesThePreviousEntry() {
        var draft = WorkCalendarDraft(calendar: nil)
        draft.addException(date: day(2026, 10, 1), isWorking: false, note: "  国庆  ")
        #expect(draft.exceptions.count == 1)
        #expect(draft.exceptions[0].note == "国庆", "备注应去首尾空白")

        draft.addException(date: day(2026, 10, 1), isWorking: true, note: nil)
        #expect(draft.exceptions.count == 1, "同一天只保留一条（后写覆盖先写）")
        #expect(draft.exceptions[0].isWorking)

        draft.addException(date: day(2026, 10, 2), isWorking: false, note: "   ")
        #expect(draft.exceptions.count == 2)
        #expect(draft.exceptions.map(\.date) == [day(2026, 10, 1), day(2026, 10, 2)], "按日期升序")
        #expect(draft.exceptions[1].note == nil, "空白备注等价于没写")

        draft.removeException(at: 0)
        #expect(draft.exceptions.count == 1)
        #expect(draft.exceptions[0].date == day(2026, 10, 2))
        draft.removeException(at: 9)
        #expect(draft.exceptions.count == 1, "越界删除不改变状态")
    }

    @Test func defaultDraftStoresNoCalendar() {
        #expect(WorkCalendarDraft(calendar: nil).storedCalendar == nil, "全默认不落键")
        #expect(WorkCalendarDraft(calendar: WorkCalendar()).storedCalendar == nil)

        var fiveDay = WorkCalendarDraft(calendar: nil)
        fiveDay.select(.fiveDays)
        #expect(fiveDay.storedCalendar?.workingWeekdays == WorkCalendar.mondayToFriday)
        #expect(fiveDay.isDefault == false)
    }

    @Test func nonPositiveHoursFallBackToDefault() {
        var draft = WorkCalendarDraft(calendar: nil)
        draft.setHoursPerDay(0)
        #expect(draft.hoursPerDay == WorkCalendarDraft.defaultHoursPerDay)
        draft.setHoursPerDay(-3)
        #expect(draft.hoursPerDay == WorkCalendarDraft.defaultHoursPerDay)
        draft.setHoursPerDay(7.5)
        #expect(draft.hoursPerDay == 7.5)
        #expect(draft.storedCalendar?.hoursPerDay == 7.5)
    }

    // MARK: - 会话写入

    @Test func settingFiveDayWeekShadesWeekend() {
        let store = makeStore()
        #expect(store.workCalendar == nil)
        #expect(store.snapshot.gantt.bands.isEmpty, "无日历 ⇒ 不铺灰")

        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))

        #expect(store.workCalendar?.workingWeekdays == WorkCalendar.mondayToFriday)
        #expect(!store.snapshot.gantt.bands.isEmpty, "切到 5 天模板后应出现周末阴影")
        #expect(store.hasUnsavedChanges, "改日历属于项目数据，必须置脏")
    }

    @Test func undoRestoresPreviousCalendarInOneStep() {
        let store = makeStore()
        let depthBefore = store.undoDepthForTesting
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))
        #expect(store.undoDepthForTesting == depthBefore + 1)

        store.dispatch(.undo)
        #expect(store.workCalendar == nil, "一步撤销应回到「没有日历」")
        #expect(store.snapshot.gantt.bands.isEmpty)

        store.dispatch(.redo)
        #expect(store.workCalendar?.workingWeekdays == WorkCalendar.mondayToFriday)
    }

    @Test func repeatingTheSameCalendarDoesNotPushUndo() {
        let store = makeStore()
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))
        let depth = store.undoDepthForTesting
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))
        #expect(store.undoDepthForTesting == depth, "值没变就留空撤销步是污染")
    }

    @Test func clearingTheCalendarRestoresDefaultRendering() {
        let store = makeStore()
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: WorkCalendar.mondayToFriday)))
        store.dispatch(.setWorkCalendar(nil))
        #expect(store.workCalendar == nil)
        #expect(store.snapshot.gantt.bands.isEmpty, "恢复默认（全周 7 天）后不再有阴影")
    }

    /// 端到端：应用内排期必须吃项目日历（会话把 `Project.calendar` 传进 `ScheduleEngine`）。
    ///
    /// 判据不挑任务数据：把上班日压到「只周一」，整份排期必然比全周更晚结束；
    /// 若哪天会话又忘了传日历，这条会先红，而不是等用户发现「改了工作周条子不动」。
    @Test func scheduleStretchesWithANarrowerWorkingWeek() throws {
        let store = makeStore()
        // 比「最晚任务结束」而不是 projectEnd：示例数据里的 projectEnd 是显式值，不随排期伸缩。
        let before = try #require(
            store.sessionForTesting.lastSchedule?.tasks.map(\.scheduledFinish).max()
        )
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: [2])))
        let after = try #require(
            store.sessionForTesting.lastSchedule?.tasks.map(\.scheduledFinish).max()
        )
        #expect(after > before, "每周只上一天班，最晚任务结束必须推后")
    }

    /// 应用层断言「改工作周 → 任务条位置变化」（team-lead 的判据）：按「第几天」比较，
    /// 不看点宽——日历一换，甘特内容范围与自适应日宽都会变，比 x 会得出假差异。
    @Test func taskBarsShiftWhenTheWorkingWeekNarrows() throws {
        let store = makeStore()
        let before = dayOffsets(of: store.snapshot.gantt)
        store.dispatch(.setWorkCalendar(WorkCalendar(workingWeekdays: [2])))
        let after = dayOffsets(of: store.snapshot.gantt)

        let movedRight = before.keys.filter { id in
            guard let old = before[id], let new = after[id] else { return false }
            return new > old
        }
        #expect(!movedRight.isEmpty, "每周只上一天班时应有任务条整体右移")
    }

    /// 甘特条起点换算成「距离窗口第几天」（与 Presenter 的尺子同源）。
    private func dayOffsets(of gantt: GanttSnapshot) -> [UUID: Int] {
        guard gantt.dayWidth > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: gantt.bars.map { bar in
            (bar.taskID, Int((bar.x / gantt.dayWidth).rounded()))
        })
    }

    @Test func settingsPanelOpensAndCloses() {
        let store = makeStore()
        #expect(store.isProjectSettingsPresented == false)
        store.presentProjectSettings()
        #expect(store.isProjectSettingsPresented)
        store.dismissProjectSettings()
        #expect(store.isProjectSettingsPresented == false)
    }

    // MARK: - 顺延留痕文案

    @Test func adjustmentTextListsBothDatesAndReason() {
        let row = CalendarAdjustmentRow(
            kind: .nonWorkingDay,
            requested: day(2026, 10, 1),
            adjusted: day(2026, 10, 9)
        )
        #expect(
            CalendarAdjustmentText.message(row) == "Moved from 2026-10-01 to 2026-10-09 (non-working day)"
        )
    }

    @Test func adjustmentTextNamesTheDegradedCalendar() {
        let row = CalendarAdjustmentRow(
            kind: .invalidWeekdays,
            requested: day(2026, 10, 1),
            adjusted: day(2026, 10, 1)
        )
        #expect(
            CalendarAdjustmentText.message(row)
                == "Moved from 2026-10-01 to 2026-10-01 (working week unavailable)"
        )
    }
}

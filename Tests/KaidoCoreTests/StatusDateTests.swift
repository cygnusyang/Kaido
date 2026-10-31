import Foundation
import Testing
@testable import KaidoCore

// EVM 数据日期（17-evm-status-date §2 / §3）：字段层。
// 纪律：时刻一律由字面日期构造，不读墙钟；期望值写死字面日期，不用被测函数现算。
//
// 计算口径（PV / SPI）与 UI 不在本用例范围，只锁「存取 / 归一 / 不进基线」四件事。

// MARK: - 夹具

private var utc: Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}

private func day(_ year: Int, _ month: Int, _ dayOfMonth: Int, hour: Int = 0) -> Date {
    utc.date(from: DateComponents(year: year, month: month, day: dayOfMonth, hour: hour))!
}

/// 生产侧（statusDate 赋值与 CalendarDayMath）默认用当前时区的公历。
private func localStartOfDay(_ date: Date) -> Date {
    CalendarDayMath.startOfDay(date, calendar: Calendar(identifier: .gregorian))
}

private func scheduled(_ taskID: UUID, start: Date, finish: Date) -> ScheduledTask {
    ScheduledTask(
        taskID: taskID,
        durationDays: 0,
        earliestStart: start,
        earliestFinish: finish,
        latestStart: start,
        latestFinish: finish,
        scheduledStart: start,
        scheduledFinish: finish,
        totalSlackDays: 0,
        freeSlackDays: 0
    )
}

/// 从编码结果里取 JSON 对象（用于断言「键是否存在」，而不只是解码后是否为 nil）。
private func jsonObject(_ data: Data) throws -> [String: Any] {
    try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
}

// MARK: - 往返存取

struct StatusDateStorageTests {
    @Test func statusDateRoundTripsThroughJSON() throws {
        var metadata = ProjectMetadata(title: "数据日期")
        metadata.setStatusDate(day(2026, 10, 20), calendar: utc)

        let encoded = try JSONEncoder().encode(metadata)
        let decoded = try JSONDecoder().decode(ProjectMetadata.self, from: encoded)

        #expect(decoded.statusDate == day(2026, 10, 20))
        #expect(decoded.normalizedStatusDate(calendar: utc) == day(2026, 10, 20))
    }

    @Test func nilStatusDateRoundTripsWithoutWritingTheKey() throws {
        let metadata = ProjectMetadata(title: "未固定")

        let encoded = try JSONEncoder().encode(metadata)
        let object = try jsonObject(encoded)

        // nil 不落键（与 calendar / anchor 同策略）：缺键 = 「今天」。
        #expect(object["statusDate"] == nil)
        let decoded = try JSONDecoder().decode(ProjectMetadata.self, from: encoded)
        #expect(decoded.statusDate == nil)
    }

    @Test func legacyMetadataWithoutStatusDateDecodesAsNil() throws {
        var object = try jsonObject(try JSONEncoder().encode(ProjectMetadata(title: "旧文件")))
        #expect(object.removeValue(forKey: "statusDate") == nil)

        let legacy = try JSONSerialization.data(withJSONObject: object)
        let decoded = try JSONDecoder().decode(ProjectMetadata.self, from: legacy)

        #expect(decoded.statusDate == nil)
        #expect(decoded.title == "旧文件")
    }

    @Test func fileRoundTripKeepsStatusDateAndFormatVersion() throws {
        let project = Project(metadata: ProjectMetadata(title: "版本"))
        project.metadata.setStatusDate(day(2026, 10, 27), calendar: utc)

        let data = try KaidoFile.encode(project: project)
        let root = try jsonObject(data)

        // 加法字段不升版本：仍是 v2，旧客户端靠「忽略未知键」前向兼容。
        #expect(root["formatVersion"] as? Int == 2)
        let projectObject = try #require(root["project"] as? [String: Any])
        #expect(projectObject["statusDate"] != nil)

        let reopened = try KaidoFile.decode(from: data)
        #expect(reopened.metadata.statusDate == day(2026, 10, 27))
    }
}

// MARK: - 归一化（同一天不同时分必须相等）

struct StatusDateNormalizationTests {
    @Test func sameDayDifferentTimesNormalizeToTheSameInstant() {
        var morning = ProjectMetadata(title: "上午")
        var evening = ProjectMetadata(title: "傍晚")
        morning.setStatusDate(day(2026, 10, 27, hour: 9), calendar: utc)
        evening.setStatusDate(day(2026, 10, 27, hour: 18), calendar: utc)

        #expect(morning.statusDate == evening.statusDate)
        #expect(morning.statusDate == day(2026, 10, 27))
    }

    @Test func directAssignmentAlsoNormalizesToStartOfDay() {
        let raw = Date(timeIntervalSince1970: 1_800_000_000)   // 带时分，非零点
        var metadata = ProjectMetadata(title: "直接赋值")

        metadata.statusDate = raw

        #expect(metadata.statusDate == localStartOfDay(raw))
        #expect(metadata.statusDate != raw)
    }

    @Test func clearingStatusDateFallsBackToUnfixed() {
        var metadata = ProjectMetadata(title: "清除")
        metadata.setStatusDate(day(2026, 10, 20), calendar: utc)

        metadata.setStatusDate(nil)

        #expect(metadata.statusDate == nil)
        #expect(metadata.normalizedStatusDate() == nil)
    }

    @Test func statusDateIsNotClampedToProjectTimeline() {
        // §3：早于开始 / 晚于结束都接受（PV 与 SPI 的判定留给计算层），字段层不吸附、不裁剪。
        var metadata = ProjectMetadata(
            title: "越界",
            projectStart: day(2026, 10, 1),
            projectEnd: day(2026, 10, 31)
        )
        metadata.setStatusDate(day(2026, 9, 15), calendar: utc)
        #expect(metadata.statusDate == day(2026, 9, 15))

        metadata.setStatusDate(day(2026, 12, 24), calendar: utc)
        #expect(metadata.statusDate == day(2026, 12, 24))
    }
}

// MARK: - 不进基线快照

struct StatusDateBaselineTests {
    @Test func baselineSnapshotDoesNotCarryStatusDate() throws {
        let project = Project(metadata: ProjectMetadata(title: "基线项目"))
        project.metadata.setStatusDate(day(2026, 10, 20), calendar: utc)
        let task = TaskItem(title: "任务 A", durationDays: 1)
        project.add(task)

        let baseline = BaselineEngine.snapshot(
            tasks: project.tasks,
            schedules: [task.id: scheduled(task.id, start: day(2026, 10, 21), finish: day(2026, 10, 22))],
            name: "基线 1 · 2026-10-20",
            anchor: day(2026, 10, 20),
            now: day(2026, 10, 20)
        )

        let encoded = try JSONEncoder().encode(baseline)
        let text = String(decoding: encoded, as: UTF8.self)

        // 数据日期是报告参数：快照里出现它就意味着报告口径污染了计划事实。
        #expect(!text.contains("statusDate"))
        #expect(try jsonObject(encoded)["statusDate"] == nil)
        #expect(baseline.entries.count == 1)
    }

    @Test func snapshotIsIdenticalWhetherStatusDateIsSetOrNot() {
        let task = TaskItem(title: "任务 A", durationDays: 1)
        let schedules = [task.id: scheduled(task.id, start: day(2026, 10, 21), finish: day(2026, 10, 22))]
        let anchor = day(2026, 10, 20)
        let now = day(2026, 10, 20)

        let withoutDate = BaselineEngine.snapshot(
            tasks: [task], schedules: schedules, name: "基线 1", anchor: anchor, now: now
        )

        var metadata = ProjectMetadata(title: "基线与数据日期")
        metadata.setStatusDate(day(2026, 10, 20), calendar: utc)
        let withDate = BaselineEngine.snapshot(
            tasks: [task], schedules: schedules, name: "基线 1", anchor: anchor, now: now
        )

        #expect(metadata.statusDate != nil)
        #expect(withDate.entries == withoutDate.entries)
    }
}

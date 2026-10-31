import Foundation
import Testing

@testable import ZenoCore

// MARK: - 体积 / 耗时实测（08-baselines §6 方案 A + 09-baseline-version-plan §2 闸门）
//
// 口径：NFR 是「5,000 任务 ≤ 1 s 读写」。本文件在 **debug** 构建下测端到端
// encode / decode（含基线条目）与一次完整偏差计算，断言只设宽松上限（防 O(n²) 回归），
// 精确数字由用例打印，并抄进 CHANGELOG 的判据与证据段。
//
// 两个用例分别对应两条门禁：
// - 3 基线：09 §2 的体积闸门（5,000 任务 × 3 基线）；
// - 5 基线：08 §6 的方案 A 体积估算校验（180 B/条目、4.5 MB 口径）。

private let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    return calendar
}()

private let taskCount = 5_000

/// 体积上限（粗粒度护栏，防「时间没变但文件膨胀」的回归）。
///
/// 取值 = 实测值 × ~2.2 倍；不求精确，只为在「条目悄悄变胖」（例如把 title/outlineNumber
/// 塞进条目、或改成一条基线一个文件块）时立刻变红。prettyPrinted 换行差异不会碰到这档余量。
private let threeBaselineMegabyteCap = 12.0
private let fiveBaselineMegabyteCap = 15.0

private struct Measurement {
    var encodeSeconds: Double
    var decodeSeconds: Double
    var varianceSeconds: Double
    var fileBytes: Int
    var bareBytes: Int

    var baselineBytes: Int { fileBytes - bareBytes }

    func bytesPerEntry(baselineCount: Int) -> Double {
        Double(baselineBytes) / Double(taskCount * baselineCount)
    }

    var summary: String {
        String(
            format: "encode %.3f s，decode %.3f s，variance %.3f s，文件 %.2f MB"
                + "（无基线 %.2f MB，基线净增 %.2f MB）",
            encodeSeconds,
            decodeSeconds,
            varianceSeconds,
            Double(fileBytes) / 1_048_576,
            Double(bareBytes) / 1_048_576,
            Double(baselineBytes) / 1_048_576
        )
    }
}

private func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

private func makeLargeProject(baselineCount: Int) -> Project {
    let project = Project()
    project.metadata.title = "体量实测项目"
    let origin = utc.date(from: DateComponents(year: 2026, month: 1, day: 1))!
    var tasks: [TaskItem] = []
    tasks.reserveCapacity(taskCount)
    for index in 0..<taskCount {
        tasks.append(TaskItem(
            title: "任务 \(index)",
            durationDays: Double(index % 7 + 1),
            progress: Double(index % 4) / 4
        ))
    }
    project.tasks = tasks

    let schedule = ScheduleEngine.compute(
        tasks: tasks,
        projectStart: origin,
        calendar: utc,
        createdAt: origin
    )
    let schedules = BaselineEngine.scheduleIndex(from: schedule)
    project.baselines = (1...max(baselineCount, 1)).prefix(baselineCount).map { index in
        BaselineEngine.snapshot(
            tasks: tasks,
            schedules: schedules,
            name: "基线 \(index) · 2026-01-\(String(format: "%02d", index))",
            anchor: origin,
            now: origin
        )
    }
    return project
}

private func measure(baselineCount: Int) throws -> Measurement {
    let project = makeLargeProject(baselineCount: baselineCount)
    let clock = ContinuousClock()

    let encodeStart = clock.now
    let data = try ZenoFile.encode(project: project)
    let encodeSeconds = seconds(clock.now - encodeStart)

    let decodeStart = clock.now
    let decoded = try ZenoFile.decode(from: data)
    let decodeSeconds = seconds(clock.now - decodeStart)

    let varianceStart = clock.now
    let reopenedSchedule = ScheduleEngine.compute(
        tasks: decoded.tasks,
        projectStart: nil,
        calendar: utc,
        createdAt: decoded.metadata.createdAt
    )
    let report = BaselineEngine.variance(
        baseline: project.baselines[baselineCount - 1],
        tasks: decoded.tasks,
        schedules: BaselineEngine.scheduleIndex(from: reopenedSchedule),
        now: decoded.metadata.createdAt,
        calendar: utc
    )
    let varianceSeconds = seconds(clock.now - varianceStart)

    // 拆出基线自身体积：另编一份没有基线的同任务项目。
    let withoutBaselines = Project(metadata: project.metadata)
    withoutBaselines.tasks = project.tasks
    withoutBaselines.resources = project.resources
    let bareBytes = try ZenoFile.encode(project: withoutBaselines).count

    #expect(decoded.baselines.count == baselineCount)
    #expect(decoded.tasks.count == taskCount)
    #expect(report.tasks.count == taskCount)
    #expect(report.orphans.isEmpty)

    return Measurement(
        encodeSeconds: encodeSeconds,
        decodeSeconds: decodeSeconds,
        varianceSeconds: varianceSeconds,
        fileBytes: data.count,
        bareBytes: bareBytes
    )
}

// MARK: - 09 §2 体积闸门：5,000 任务 × 3 基线

@Test func fiveThousandTasksWithThreeBaselinesMeetSizeGate() throws {
    let result = try measure(baselineCount: 3)
    print(String(
        format: "[baseline-perf] 5,000 任务 × 3 基线：%@，%.0f B/条目",
        result.summary,
        result.bytesPerEntry(baselineCount: 3)
    ))

    // 宽松护栏：debug 构建下远超 1 s 即说明引入了二次复杂度，不是机器慢。
    #expect(result.encodeSeconds < 30, "encode 耗时异常：\(result.encodeSeconds) s")
    #expect(result.decodeSeconds < 30, "decode 耗时异常：\(result.decodeSeconds) s")
    #expect(result.varianceSeconds < 30, "variance 耗时异常：\(result.varianceSeconds) s")
    // 体积回归护栏（08 §6：单文件承诺的前提是体积可接受，实测 5.10 MB）。
    let megabytes = Double(result.fileBytes) / 1_048_576
    #expect(megabytes < threeBaselineMegabyteCap, "5,000 × 3 基线体积超限：\(megabytes) MB")
}

// MARK: - 08 §6 方案 A 估算校验：5,000 任务 × 5 基线

@Test func fiveThousandTasksWithFiveBaselinesStayWithinReadWriteBudget() throws {
    let result = try measure(baselineCount: 5)
    print(String(
        format: "[baseline-perf] 5,000 任务 × 5 基线：%@，%.0f B/条目",
        result.summary,
        result.bytesPerEntry(baselineCount: 5)
    ))

    #expect(result.encodeSeconds < 30, "encode 耗时异常：\(result.encodeSeconds) s")
    #expect(result.decodeSeconds < 30, "decode 耗时异常：\(result.decodeSeconds) s")
    // 体积回归护栏（08 §6 估算校验；实测 7.31 MB）。
    let megabytes = Double(result.fileBytes) / 1_048_576
    #expect(megabytes < fiveBaselineMegabyteCap, "5,000 × 5 基线体积超限：\(megabytes) MB")
}

# 16 · 工作日历（F-22-06）设计：把「日历天」换成「工作日」

> 2026-10-27。前置：`15-mpp-sample-analysis.md`（真实 Project 文件是周一至周六 6 天工作周）。
> 目标：让 Kairo 能表达「周末/节假日不工作」，同时**不改变任何现有项目的行为**。

## 1. 核心决策（三条，其余都是实现细节）

**D1｜工期单位改为「工作日」，默认 7 天工作周 = 与现在完全等价。**
`durationDays` 的含义从「日历天」改为「工作日」。默认 `workingWeekdays = 全部 7 天` 时，工作日 == 日历天，**现有 1343 个用例与所有既有文件行为不变**。这是兼容性的唯一保证，也是验收红线。

**D2｜日历挂在 Project 上，是可选加法字段，不升 formatVersion。**
`Project.calendar: WorkCalendar?`（缺失 = 全周 7 天）。`.kairo` 仍是 formatVersion 2，旧文件照常读、旧版本读新文件不受影响（多一个未知键）。

**D3｜日期一律吸附到工作日，且「吸附」不是「拒绝」。**
约束/开始日期落在非工作日时，向后滚到下一个工作日并继续排期；同时产出一条 info 级违例「已从 X 顺延到 Y」，不阻断、不静默。

## 2. 数据模型

```swift
public struct WorkCalendar: Codable, Equatable {
    /// Calendar 的 weekday 编号（1=周日 … 7=周六），与 GanttLayout.nonWorkingWeekdays 同一口径
    public var workingWeekdays: Set<Int>      // 默认 [1,2,3,4,5,6,7]
    public var exceptions: [CalendarException] // 默认 []
    public var hoursPerDay: Double            // 默认 8，用于 effort ÷ (hoursPerDay × units) → duration

    public func isWorkingDay(_ date: Date, calendar: Calendar) -> Bool
    public func nextWorkingDay(onOrAfter: Date, calendar: Calendar) -> Date
    public func addingWorkDays(_ n: Double, to: Date, calendar: Calendar) -> Date
}

public struct CalendarException: Codable, Equatable {
    public var date: Date        // 当天 00:00（项目时区）
    public var isWorking: Bool   // false = 节假日；true = 调休上班（周六补班）
    public var note: String?     // 「国庆」「春节调休」
}
```

## 3. 引擎改动点（全部在 ScheduleEngine）

| 位置 | 现状 | 改法 |
| --- | --- | --- |
| `addDays(_:_:in:)` 及所有调用点 | 日历天直接加 | 换成 `calendar.addingWorkDays`；**只改这一层**，上层不感知 |
| `forwardStartLowerBound` / `backwardPass` | 用日历天推进 | 同上 |
| 工期默认值 | `effort/8` | `effort / (hoursPerDay × Σ units)` |
| 约束 / startDate 下限 | 直接用日期 | 先吸附到下一个工作日，违例记 info |
| 群组窗口聚合 | 子树 min/max | 不用改（仍取子树端点） |
| 关键路径 / 宽延 | 基于窗口差 | 单位随工期改为工作日；展示文案同步 |
| 甘特 | `nonWorkingWeekdays` 默认为空 | 由 `Project.calendar` 派生填充（只看不排） |

## 4. 必须覆盖的用例

| # | 用例 | 期望 |
| --- | --- | --- |
| 1 | **回归**：无日历（默认 7 天）时全量 1343 例不变 | 一条断言都不改仍绿 |
| 2 | 5 天工作周：周五开始、工期 5 天的任务 | 跨周末，下周周四收尾 |
| 3 | 5 天工作周的 FS 链（A→B→C 各 3 天） | 每跨一次周末整体右移 2 天 |
| 4 | 节假日：7 天工作周 + 3 天假期，任务 5 天跨假期 | 顺延 3 天，且产出一条 info 违例 |
| 5 | 调休：周六补班（isWorking=true） | 该周六参与工作 |
| 6 | 里程碑落在周六（5 天周） | 吸附到周一，不被跳过 |
| 7 | ALAP + 5 天周 | 最晚窗口同样按工作日回推，工作量为负时不越界 |
| 8 | 群组聚合跨非工作日 | 窗口 = 子树最早/最晚，跨度按工作日计 |
| 9 | 往返：带日历的文件存读一致；无日历旧文件读入 = 全周 | 字段级相等 |
| 10 | 边界：`workingWeekdays` 为空（脏数据） | 明确拒绝或退化为 7 天并在违例里说明，**不得死循环** |

## 5. 不做（本项范围外）

- 资源级日历（每人不同作息）、一天多段工作时段、按小时排期 —— 全部留到后续。
- 项目时区切换：仍用本机时区，`CalendarException.date` 按项目时区归一化存储。
- MSPDI / `.oplx` 的日历映射：属于 v1.1 互操作任务，本项只保证模型与引擎能表达。

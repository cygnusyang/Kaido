# 07 实际开始 / 实际结束（Actual Dates）

> 需求原话：「当前任务有开始时间也有结束时间，实际上我们还有实际开始，实际结束时间。」
> 角色：设计（dev-architect）。实现由 dev-coder-core / dev-coder-ui 按本文契约落地。

## 1. 目标

在已有**计划**时间（`startDate` 意图起点 / 排期 `scheduledStart`、`scheduledFinish`、`dueDate` 时限）之外，
记录**实际**发生的两个时刻：实际开始、实际结束。默认由状态/进度变化自动记录，允许人工修正，可在检查器与大纲查看。

## 2. 字段与语义

| 概念 | 字段 | 类型 | 是否可编辑 | 说明 |
| --- | --- | --- | --- | --- |
| 计划开始 | `startDate` | `Date?` | 是 | 用户意图起点，参与排期 |
| 计划结束 | 排期 `scheduledFinish` / `dueDate` | `Date?` | 是 | 计划口径，参与排期与违例 |
| **实际开始** | `actualStart`（新增） | `Date?` | 是 | 首次真正开工时刻 |
| **实际结束** | `completedAt`（复用，不改名） | `Date?` | 是 | 语义即实际结束 |

**结论：实际结束复用 `completedAt`，不新增 `actualFinish`、不做标识符重命名。**

- 备选 A（采纳）：复用 `completedAt`。磁盘键与 MCP 字段（`completedAt`）已对外，语义本就等于「完成的那一刻」。
- 备选 B（否决）：新增 `actualFinish`，与 `completedAt` 并存 → 两个时间戳必然漂移，还要写同步逻辑。
- 备选 C（否决）：字段改名 `actualFinish` + CodingKeys 映射到旧键 `completedAt` → 代码名与 JSON/磁盘名不一致，
  且机械重命名扩散到 10+ 文件与测试，收益只是命名美观。
- 命名代价的消解：`TaskItem.completedAt` 的文档注释与 UI 标签统一写「实际结束」，本文即命名裁决依据。

群组（`kind == .group`）两字段恒为 `nil`（与 `startDate` 同口径：群组行只表达子任务聚合的排期，不表达实际）。

## 3. 自动记录（确定结论，不留选项）

唯一触发点：`KaidoSession.applyStatus(status:progress:now:to:)`（状态/进度的统一回写入口）。

| 场景 | 行为 |
| --- | --- |
| status 置 `.inProgress` 且 `actualStart == nil` | 写入 `actualStart = now` |
| progress 写入 > 0（< 1）且 `actualStart == nil` | 写入 `actualStart = now`，**不改 status**（避免隐式状态跳变） |
| status 已 `.inProgress` 再次回写 | **不覆盖**（仅 `nil` 时写，首次为准） |
| status 置 `.done`（含 progress 达 1 → 转 done） | `progress = 1`、`completedAt = now`（沿用现有行为），此时若 `actualStart == nil` 也不补 |
| 离开 `.done`（→ pending/inProgress/blocked） | 清空 `completedAt`（沿用现有行为） |
| 回退 `.inProgress → .pending/.blocked` | **保留** `actualStart`（已发生的开工是历史事实，不因状态回退消失） |
| `progress = 1` | **等同 done**：status → done、progress 1、记 `completedAt`（现有行为，明确保留） |
| 从 pending/blocked 直接置 `.done` | 不补 `actualStart`（不臆造未观测到的开工时刻；人工可补） |

自动记录值与人工值的非对称：`completedAt` 与 `done` 状态强耦合（现有语义），`actualStart` 只增不清（除人工清除）。
这是有意的——前者表达「当前完成断言」，后者表达「历史事件」。

时钟来源：`now` 由调用方注入（默认 `Date()`），禁止在测试里读墙钟。

## 4. 手工编辑

- 入口：检查器「实际」分区两个日期字段（`DateFieldRow`，均可清除）；大纲实际列**只读**。
- `setActualStart(date:)`：`nil` = 清除；非 `nil` 且任务为 `.pending` → 顺带置 `.inProgress`（有实际开始即已开工）；
  `.done`/`.blocked` 不改状态（不因补录历史而重开任务）。
- `setActualFinish(date:)`：`nil` = 清除，**不改状态**；非 `nil` → 置 `.done` + `progress = 1`（与 done 同语义）。
- 顺序校验：`actualStart > actualFinish` 或 `actualFinish < actualStart` → 抛
  `SessionError(code: .invalidArgument, reason: .actualDateOrderInvalid, …)`，不写库。
- 手工值与自动值同源（同一个字段），人工写入后自动逻辑因「非 nil 不覆盖」而自然不再改动；
  清除后再进入 in_progress 会重新自动记录。
- 撤销：走 Store 的 `update(id:mergeKey:)` 包装，一次编辑 = 一步撤销（`actual-start-<id>` / `actual-finish-<id>`）。

## 5. 展示

**检查器**：`inspector.section.actual`「实际」，紧随 Schedule 分区之后，两行 `DateFieldRow`：
实际开始（可清除）、实际结束（可清除）。群组行整段不显示。显示到日（`Display.date`），存储保留完整时间戳。

**大纲**：新增两个**可选列** `actualStart` / `actualFinish`（列名「实际开始」/「实际结束」，宽 78×scale，只读文本，无值显示 `—`）。
默认隐藏，用户经列显隐菜单打开。**默认隐藏的实现方式**：`OutlineColumn.visibleColumns(outlineWidth:)` 不产出这两列，
另设 `OutlineColumnPreferences.optional` + 显式启用集合（见 §6 契约），而不是把默认值塞进 `hiddenOutlineColumns`——
后者对「曾保存过偏好的旧用户」无法区分「没隐藏」与「新列尚未存在」，会导致升级后凭空多出两列。

**日期口径**：大纲与检查器都按系统日历显示到日；时间戳精度保留在模型里（供排序与将来的时长统计）。

## 6. 接口契约（core ↔ ui 分界）

```swift
// KaidoCore — Model
public var actualStart: Date?                          // TaskItem 新增，CodingKey "actualStart"
public init(…, assignments: [TaskAssignment] = [], actualStart: Date? = nil)  // 参数追加在末尾

// KaidoCore — Diagnostics
case actualDateOrderInvalid = "model_actual_date_order_invalid"   // 只增不改，追加到 model 组

// KaidoCommands — KaidoSession（唯一的写入口）
@discardableResult
public func statusUpdate(id: UUID, status: TaskStatus? = nil, progress: Double? = nil,
                         now: Date = Date()) throws -> TaskItem
@discardableResult
public func setActualStart(id: UUID, date: Date?) throws -> TaskItem
@discardableResult
public func setActualFinish(id: UUID, date: Date?) throws -> TaskItem
private static func applyStatus(status: TaskStatus?, progress: Double?, now: Date, to task: inout TaskItem)

// KaidoPresentation — 快照
public struct PlanRow { public var actualStart: Date?; public var actualFinish: Date? }   // init 末尾追加，默认 nil
public struct TaskInspector { public var actualStart: Date? }                            // completedAt 保持原字段名
public enum OutlineColumn { case actualStart, actualFinish }                             // width = 78 * scale
public static let optional: Set<OutlineColumn> = [.actualStart, .actualFinish]           // OutlineColumnPreferences
public static func visibleColumns(outlineWidth: Double, hidden: Set<OutlineColumn>, focused: Bool,
                                  shownOptional: Set<OutlineColumn> = []) -> [OutlineColumn]
public struct WorkspaceViewState { public var visibleOptionalColumns: Set<String> = [] } // 键 = OutlineColumn.rawValue

// KaidoPresentation — 动作
case setActualStart(UUID, Date?)
case setActualFinish(UUID, Date?)
```

列序规则：启用后可选项按 `[.actualStart, .actualFinish]` 顺序插入——基准列含 `.finish` 时紧随其后，否则追加到末尾。

## 7. 存储与向后兼容

- JSON 键：新增 `actualStart`（ISO8601，同 `startDate` 写法）；实际结束继续写 `completedAt`。
- 旧文件可读：`decodeIfPresent` → `nil`，**不升 `KaidoFile.currentFormatVersion`**（仍为 1），不做迁移。
- 新文件被旧版本读：Codable 忽略未知键，不报错。
- ADR-011 前向兼容口径不变；无需 `FormatMigration` 改动。

## 8. CLI / MCP 输出

- `kaido task get <id>`：新增两行「实际开始」「实际结束」（`CLIStrings` 新增 `actualStart(_:)` / `actualFinish(_:)`；
  `kaido status update` 现有 `completedAt` 输出行的标签一并改为「实际结束」，方法名可保留或改名，行为不变）。
- MCP：**无代码改动**——`task_get` / `task_list` 走 `JSONValue.json(task)` 的 Codable 直出，
  自动多出 `actualStart` 键，实际结束仍是 `completedAt`。
- 写入口不扩：CLI/MCP 本期不提供写实际时间的参数（见§10 非目标），避免绕过 §4 的顺序校验与状态耦合。

## 9. 判据清单

1. pending → in_progress 首次写入 `actualStart == now`；再次 `.inProgress` 不覆盖（值保持首次）。
2. progress 0.4（status 仍 pending）→ 写入 `actualStart`，status 不变。
3. 置 done → `completedAt == now`、progress 1；离开 done → `completedAt == nil`、`actualStart` 保留。
4. progress = 1 → status done + `completedAt`（等同 done）。
5. in_progress → pending 回退：`actualStart` 不清空。
6. pending → done 直跳：`actualStart` 仍为 `nil`。
7. `setActualStart(nil)` 清空；对 pending 任务写非 nil → status 变 `.inProgress`；对 done 任务写 → status 不变。
8. `setActualFinish(nil)` 只清 `completedAt`，status 保持 done；非 nil → done + progress 1。
9. `actualStart > actualFinish` → 抛 `model_actual_date_order_invalid`，任务不被修改、不产生撤销点。
10. 旧 .kaido（无 `actualStart` 键）打开 → 字段 `nil`、`formatVersion` 仍为 1；保存后可被旧版本读回。
11. 大纲两列默认不出现；开启后位置在 `.finish` 之后、只读、无值显示 `—`；列宽可拖、可再隐藏。
12. 群组行：`PlanRow.actualStart/actualFinish` 与 `TaskInspector.actualStart` 均为 `nil`，检查器无「实际」分区。
13. `kaido task get` 输出两行实际时间；`task_get` 的 JSON 含 `actualStart`。
14. 时间注入：`statusUpdate(…, now:)` 让上述断言不依赖墙钟。

## 10. 非目标

- 实际工期/工时统计、报表、导出。
- 实际时间回灌排期（`actualStart`/`completedAt` 不参与 CPM、关键路径与违例判定）。
- 计时器/时间跟踪（start/stop 计时、分段记录）。
- 群组实际时间聚合（不取子任务 min/max）。
- CLI/MCP 写实际时间、批量导入实际时间。
- 实际时间偏差告警/通知（计划 vs 实际的差值提示）。

## 11. 改动清单与并行分组

| 组 | 文件（互斥范围） | 前置 |
| --- | --- | --- |
| **A core** | `Sources/KaidoCore/Model/TaskItem.swift`、`Sources/KaidoCore/Diagnostics/KaidoErrorCode.swift`、`Tests/KaidoCoreTests/TaskItemActualDatesTests.swift`（新建） | — |
| **B cmds** | `Sources/KaidoCommands/KaidoSession.swift`、`Tests/KaidoCoreTests/SessionActualDatesTests.swift`（新建） | A |
| **C pres** | `Sources/KaidoPresentation/Snapshots.swift`、`OutlineColumnPreferences.swift`、`InspectorSnapshots.swift`、`WorkspaceAction.swift`、`ViewState.swift`、`Presenter.swift`、`Tests/KaidoPresentationTests/ActualDatesPresentationTests.swift`（新建） | A |
| **D cli** | `Sources/KaidoCLI/CLIRouter.swift`、`Sources/KaidoCLI/CLIStrings.swift` | A |
| **E app** | `Apps/macos/Sources/WorkspaceStore.swift`、`Workspace/WorkspaceView.swift`、`Workspace/Outline/OutlineTable.swift`、`Workspace/Display.swift`、`Workspace/Inspector/InspectorView.swift`、`Apps/macos/Resources/Localizable.xcstrings` | B + C |

- 波次 1：A（唯一地基，必须先落）。
- 波次 2：**B / C / D 并行**——B、C、D 文件范围两两不重叠，测试文件也各自独立。
- 波次 3：E（需要 B 的会话方法与 C 的快照字段，串行）。
- 不可并行：E 与 B/C；A 与任何其它组。
- 需同步的既有测试：`Tests/KaidoPresentationTests/OutlineColumnPreferencesTests.swift` 对 `visibleColumns` 的精确数组断言
  在签名加默认值后仍应通过（默认 `shownOptional: []`）；若新增 `optional` 集合断言，归 C 组。

# 实际开始 / 实际结束（v0.12）验收用例与判据

> 依据：[07-actual-dates.md](./07-actual-dates.md) §9（14 条判据）与 §3 / §4 / §7 / §10 的派生语义。
> 本文件是**测试前置**产物：先于实现落盘，实现完成后逐条转绿。
> 自动化文件：`Tests/KairoCoreTests/ActualDatesAcceptanceTests.swift`（core + commands，24 例）、`Tests/InterfaceTests/ActualDatesInterfaceTests.swift`（cli，3 例）；
> 另由各层实现方补齐：`Tests/KairoPresentationTests/ActualDatesPresentationTests.swift`（pres，12 例）、`Tests/AppTests/ActualDatesWorkspaceTests.swift`（app，13 例）。

## 0. 口径

**L1 层级**：`core` = KairoCore（模型 / 存储）｜`commands` = KairoCommands.KairoSession（唯一写入口）｜`pres` = KairoPresentation（快照 / 列策略）｜`app` = Apps/macos（Store / 视图）｜`cli` = KairoCLI + KairoMCP。

**L2 「实际结束」只有一个名字**：模型侧是 `TaskItem.completedAt`（07 §2 裁决），**不存在** `actualFinish` 字段。断言必须落在 `completedAt`；「实际结束」只作为 UI 标签与快照字段名出现。把两者写成两个字段的实现一律判红。

**L3 时间注入**：所有断言的时间由 `statusUpdate(…, now:)` 注入的固定值给出，用例内不得出现 `Date()`（判据 14）。首次记录用 `==` 比对注入值，不接受「非 nil 即可」。

**L4 自动化列取值**：`✅ <用例名>` = 已在 `ActualDatesAcceptanceTests.swift` 落盘；`待补（层 / 归属文件）` = 该层用例尚未落盘，明确写明归属，不虚报已覆盖。

---

## 1. §9 判据 1-14 → 用例

| ID | 判据（07 §9） | 用例名 | 输入 / 前置 | 预期 | 层 | 自动化 |
|---|---|---|---|---|---|---|
| A-01 | 1. pending → in_progress 首次写 `actualStart == now`；再次 `.inProgress` 不覆盖 | `firstWritebackToInProgressRecordsActualStart`、`repeatedInProgressWritebackKeepsFirstActualStart` | pending 任务；先 `statusUpdate(status: .inProgress, now: t0)`，再 `(status: .inProgress, now: t1)` | 第一次后 `actualStart == t0`、`completedAt == nil`；第二次后 `actualStart` 仍 `== t0` | commands | ✅ 两例 |
| A-02 | 2. progress 0.4（status 仍 pending）→ 写 `actualStart`，status 不变 | `progressBelowOneRecordsActualStartWithoutChangingStatus` | pending 任务；`statusUpdate(progress: 0.4, now: t0)` | `actualStart == t0`、`status == .pending`、`progress == 0.4` | commands | ✅ |
| A-03 | 3. 置 done → `completedAt == now`、progress 1；离开 done → `completedAt == nil`、`actualStart` 保留 | `markingDoneStampsCompletedAtAndLeavingDoneKeepsActualStart` | in_progress@t0 → done@t1 → pending@t2 | done 后 `completedAt == t1`、`progress == 1`；回退后 `completedAt == nil` 且 `actualStart == t0` | commands | ✅ |
| A-04 | 4. progress = 1 → status done + `completedAt`（等同 done） | `progressOneCompletesTaskLikeDone` | pending 任务；`statusUpdate(progress: 1, now: t1)` | `status == .done`、`progress == 1`、`completedAt == t1` | commands | ✅ |
| A-05 | 5. in_progress → pending 回退：`actualStart` 不清空 | `rollbackFromInProgressKeepsActualStart` | in_progress@t0 → pending@t1 | `actualStart == t0`、`completedAt == nil`、`status == .pending` | commands | ✅ |
| A-06 | 6. pending → done 直跳：`actualStart` 仍为 `nil` | `directJumpFromPendingToDoneLeavesActualStartEmpty` | 两条路径各一次：`(status: .done, now: t1)` 与 `(progress: 1, now: t1)` | 两路径 `actualStart == nil`（不臆造开工时刻）；后者 `completedAt == t1` | commands | ✅ |
| A-07 | 7. `setActualStart(nil)` 清空；pending 写非 nil → `.inProgress`；done 写 → status 不变 | `clearingActualStartKeepsStatus`、`manualActualStartPromotesPendingTask`、`manualActualStartDoesNotReopenDoneOrBlockedTask` | ① in_progress 后 `setActualStart(nil)`；② pending 后 `setActualStart(t0)`；③ done（completedAt=t1）与 blocked 后各写 t0 | ① `actualStart == nil` 且 `status` 仍 inProgress；② `status == .inProgress`、`actualStart == t0`；③ done 仍 done 且 `completedAt == t1`，blocked 仍 blocked | commands | ✅ 三例 |
| A-08 | 8. `setActualFinish(nil)` 只清 `completedAt`、status 保持 done；非 nil → done + progress 1 | `clearingActualFinishOnlyClearsCompletedAt`、`manualActualFinishCompletesTask` | ① done@t1 后 `setActualFinish(nil)`；② in_progress@t0 后 `setActualFinish(t1)` | ① `completedAt == nil`、`status == .done`；② `status == .done`、`progress == 1`、`completedAt == t1`、`actualStart` 不变 | commands | ✅ 两例 |
| A-09 | 9. `actualStart > actualFinish` → 抛 `model_actual_date_order_invalid`，任务不被修改、不产生撤销点 | `actualStartAfterActualFinishIsRejectedWithoutMutation`、`actualFinishBeforeExistingActualStartIsRejectedWithoutMutation`；撤销点见 C-07 | ① 先 `setActualFinish(t1)` 再 `setActualStart(t2)`；② 先 `setActualStart(t1)` 再 `setActualFinish(t0)` | 两方向均 `code == .invalidArgument` + `reason == .actualDateOrderInvalid`；抛错后 `getTask` 与抛错前逐字段相等 | commands（撤销点：app） | ✅ 两例（撤销点待补） |
| A-10 | 10. 旧 .kairo（无 `actualStart` 键）打开 → 字段 `nil`、`formatVersion` 仍为 1；保存后可被旧版本读回 | `legacyFileWithoutActualStartDecodesNilAndKeepsFormatVersion`、`encodedTaskAddsOnlyActualStartKey` | ① 含 `actualStart` 的编码去掉该键后 `KairoFile.decode`；② 检查编码后任务对象的键集合 | ① `actualStart == nil`、标题等其余字段不变、`formatVersion == 1` 且 `KairoFile.currentFormatVersion == 1`；② 新增键**恰好** `{actualStart}`（不出现 `actualFinish` 等），`nil` 时不写该键 | core | ✅ 两例 |
| A-11 | 11. 大纲两列默认不出现；开启后位置在 `.finish` 之后、只读、无值显示 `—`；列宽可拖、可再隐藏 | pres：`defaultVisibilityIsIndependentOfHiddenSet`、`enabledOptionalColumnsFollowFinishInCanonicalOrder`、`enablingSingleOptionalColumnDoesNotRevealTheOther`、`optionalColumnsAppendWhenFinishAbsent`、`explicitlyEnabledOptionalColumnsIgnoreWidthThreshold`、`optionalColumnWidthMatchesDateColumns`、`toggleableCoversConfigurableAndOptional`、`viewStateHasNoOptionalColumnsByDefault`；app：`optionalColumnsAreHiddenByDefault`、`togglingOptionalColumnShowsItAfterFinish`、`togglingOptionalColumnAgainHidesIt`、`missingActualDateRendersPlaceholder`、`optionalColumnPreferencePersists` | A-11a：`OutlineColumnPreferences.visibleColumns(outlineWidth:hidden:focused:shownOptional:)`，默认 `shownOptional: []`，再传 `[.actualStart, .actualFinish]`（`outlineWidth` 取 ≥510 与 <376 两组）；A-11b：无值行渲染 | A-11a：默认两列均不出现；启用后按 `[.actualStart, .actualFinish]` 紧随 `.finish`（基准不含 `.finish` 时追加到末尾）；`OutlineColumnPreferences.optional == [.actualStart, .actualFinish]`；宽度 `78 × scale`（13pt 时 78）、`isResizable == true`；A-11b：单元格文本 `—`、无编辑入口 | pres + app | ✅ 已自动化（见用例名列）；`missingActualDateRendersPlaceholder` 覆盖无值 `—`，只读由 `WorkspaceAction` 无内联编辑动作保证 |
| A-12 | 12. 群组行：`PlanRow.actualStart/actualFinish` 与 `TaskInspector.actualStart` 均 `nil`，检查器无「实际」分区 | pres：`groupSnapshotsSuppressDirtyActualDates`；app：`groupRowNeverCarriesActualDates`（先对 groupID 写脏数据、再断言父行两字段 + 检查器 `actualStart`/`completedAt` 皆空、子任务保留） | 群组（`kind == .group`）行，且**故意**给群组任务写入 `actualStart`/`completedAt`（构造脏数据） | `PlanRow.actualStart == nil`、`PlanRow.actualFinish == nil`、`TaskInspector.actualStart == nil`、`TaskInspector.completedAt == nil`（抑制在快照层，与 `startDate: isGroup ? nil` 同口径）；「检查器无『实际』分区」由 `isAggregate` + 两字段 `nil` 表达。**视图条件行（`if !task.isAggregate`）不单独断言的裁决（2026-10-25，tester 定案）**：① 整屏像素差不可归因——群组行与叶子行本有十余处字段差异，diff 非零无法区分是不是分区渲染；② 给 `TaskInspector` 加 `showsActualSection = !isAggregate` 再接缝断言属同源比较（断言与被测表达式同一表达式），是 D-009 同类的恒真断言，且新增一个无独立语义的公共 API。故此处按「条件输入已被断言覆盖、渲染行不单独锁」处理；**若将来出现 `isAggregate` 之外的独立显隐规则（例如无实际时间时折叠），该分支才具备独立语义，届时再加接缝并写真断言** | pres + app | ✅ 已自动化：两条用例都先证明模型已脏（`group.actualStart != nil`），再断言快照抑制；变异验证见 B-03 |
| A-13 | 13. `kairo task get` 输出两行实际时间；`task_get` 的 JSON 含 `actualStart` | A-13a `taskGetPrintsActualStartAndActualFinishLines`、`statusUpdateCompletionLineIsLabelledActualFinish`；A-13b `taskJsonCarriesActualStartAndKeepsCompletedAt` | 临时 .kairo，任务含 `actualStart` 与 `completedAt` | A-13a：stdout 含「实际开始」「实际结束」两行，日期为 ISO8601（与现有 `formatDate` 一致）；`kairo status update` 的完成行标签为「实际结束」；A-13b：MCP `task_get` 结果含 `actualStart` 键，实际结束仍为 `completedAt`（**不新增** `actualFinish` 键） | cli | ✅ 已自动化（`Tests/InterfaceTests/ActualDatesInterfaceTests.swift`，沿用 `captureStdout` + `KAIRO_LANG=zh-Hans`） |
| A-14 | 14. 时间注入：`statusUpdate(…, now:)` 让断言不依赖墙钟 | 全部 commands 用例 | 固定 `t0/t1/t2`（`1970000000` 起算的整日偏移） | 断言全部与注入值比对；用例内无墙钟读取 | commands | ✅ 全部 commands 例 |

---

## 2. 边界补充（lead 指定 3 条）

| ID | 边界 | 用例名 | 输入 / 前置 | 预期 | 层 | 自动化 |
|---|---|---|---|---|---|---|
| B-01 | 重复回写不覆盖（含进度路径） | `repeatedInProgressWritebackKeepsFirstActualStart`、`repeatedProgressWritebackKeepsFirstActualStart` | ① `.inProgress`@t0 后 `.inProgress`@t1；② `progress: 0.2`@t0 后 `progress: 0.8`@t1 | `actualStart` 恒为首次（`t0`）；第二次只更新 `progress` | commands | ✅ 两例 |
| B-02 | pending → done 直跳不补 `actualStart`（含 blocked 直跳） | `directJumpFromPendingToDoneLeavesActualStartEmpty`、`directJumpFromBlockedToDoneLeavesActualStartEmpty` | pending / blocked 直接置 `.done`（以及 `progress: 1` 路径） | `actualStart == nil`、`completedAt == now` | commands | ✅ 两例 |
| B-03 | 群组恒 `nil` | pres：`groupSnapshotsSuppressDirtyActualDates`；app：`groupRowNeverCarriesActualDates` | 两条途径都构造脏数据：pres 直构 `kind: .group` 且带 `actualStart/completedAt` 的 `TaskItem`；app 对 groupID 直接 `dispatch(.setActualStart/.setActualFinish)` | 先断言模型确实脏（`group.actualStart != nil`），再断言 `PlanRow.actualStart/actualFinish`、`TaskInspector.actualStart/completedAt` 全 `nil`，子任务不继承、保留自身值 | pres / app | ✅ **非恒真，已变异验证**：去掉 `Presenter` 里 `actualStart` 的 `isGroup ? nil` 后两例均红（pres `row.actualStart → 2025-10-18`、app `groupRow.actualStart → 2025-11-03`），还原后绿。变异由 dev-coder-ui 执行；core/commands 层不拦截群组写入（与 `startDate` 同口径），抑制只在呈现层 |

---

## 3. 派生补充（非 §9 原文，来自 §3 / §4 / §10 语义）

| ID | 依据 | 用例名 | 输入 / 前置 | 预期 | 层 | 自动化 |
|---|---|---|---|---|---|---|
| C-01 | §3「progress 写入 > 0」 | `zeroProgressWritebackDoesNotRecordActualStart` | pending 任务，`statusUpdate(progress: 0, now: t0)` | `actualStart == nil`（0 进度不算开工）、`status == .pending` | commands | ✅ |
| C-02 | 既有写入口一致性 | `manualActualDatesOnMissingTaskAreRejected` | 不存在 id，写 `setActualStart` / `setActualFinish` | `code == .taskNotFound` + `reason == .taskNotFound`，不静默成功 | commands | ✅ |
| C-03 | §4 末段「同源」 | `manualActualStartIsNotOverwrittenByLaterWriteback`、`clearedActualStartIsRecordedAgainOnNextStart` | ① 人工写 t0 后 `.inProgress`@t1；② 自动写 t0 → 清除 → 回 pending → `.inProgress`@t2 | ① 仍 `t0`（非 nil 不覆盖）；② 重新记录 `t2` | commands | ✅ 两例 |
| C-04 | §9-9 反证边界 | `equalActualDatesAreAccepted` | `setActualStart(t0)` 后 `setActualFinish(t0)` | 不抛错；`actualStart == completedAt == t0`（判据只禁 `>` / `<`） | commands | ✅ |
| C-05 | §7「旧版本能读回」 | `encodedTaskAddsOnlyActualStartKey` | 编码后的任务对象键集合 vs v0.11 冻结键集合 | 差集**恰好**为 `{actualStart}`；`nil` 时不写键 | core | ✅ |
| C-06 | §10「不回灌排期」 | `actualDatesDoNotFeedBackIntoTheSchedule` | 固定 `projectStart`、`durationDays: 2`；写入实际开始/结束后重算排期 | `scheduledStart` / `scheduledFinish` 序列与写入前逐一相等 | commands | ✅ |
| C-07 | §4「一次编辑 = 一步撤销」 | app：`eachActualEditIsOneUndoStep`、`outOfOrderActualDatesAreRejectedWithoutUndoPoint` | Store 层 `.setActualStart/.setActualFinish` | 每次编辑 +1 撤销步（mergeKey `actual-start-<id>` / `actual-finish-<id>`）；A-09 抛错时 alert 有值、`undoDepthForTesting` 不变、数据未改 | app | ✅ 已自动化 |

---

## 4. 覆盖情况（如实）

| 层 | §9 判据 | 状态 |
|---|---|---|
| commands | 1-9、14 | ✅ 全部自动化（`ActualDatesAcceptanceTests.swift`，24 例） |
| core | 10 | ✅ 自动化（含编码键形状 C-05） |
| pres | 11、12、B-03 | ✅ 全覆盖（`ActualDatesPresentationTests.swift` 13 例，含群组脏数据抑制） |
| app | 11（渲染/持久化）、12（分区 + 撤销点）、C-07 | ✅ 自动化（`ActualDatesWorkspaceTests.swift` 13 例，群组用例先写脏数据再断言） |
| cli | 13 | ✅ 自动化（`ActualDatesInterfaceTests.swift` 3 例） |

**已知缺口：无。** 判据 12 / B-03 曾被记为恒真断言（群组从未被写入实际时间），已于 2026-10-25 由 pres + app 两条脏数据用例补齐，并以变异验证确认可证伪（见 B-03 行）。命令层按设计不拦截群组写入（与 `startDate` 同口径），抑制只落在呈现层，故这类断言必须带脏数据前置。

---

## 5. 先红后绿

**红**（落盘时已实证）：`actualStart`、`setActualStart/setActualFinish`、`statusUpdate(…, now:)`、`KairoErrorCode.actualDateOrderInvalid` 均不存在时，本文件编译失败即「先红」——不得为了变绿去改生产代码。

**绿**（A/B/C/D/E 组落地后实测）：2026-10-25 全量 `swift test` **937 tests / 93 suites 全绿**（含本文件 24 例 + `ActualDatesInterfaceTests` 3 例）。

```bash
# 单层筛选（日常）
swift test --disable-sandbox --filter ActualDatesAcceptanceTests
swift test --disable-sandbox --filter ActualDatesInterfaceTests

# 全量门禁（版本末一次；通过数随并行开发变动，以实测输出为准，不写死）
swift test --disable-sandbox
```

判绿口径：用例全部通过**且**失败输出为空；任一条红先归因（用例判据错 → 改本文件；生产契约不含该语义 → 改实现或回到 07 §9 复议），不得删断言求绿。

**已知 flake（非本版引入，登记备查）**：`AppTests/RecentProjectsTests.launchOpensTheMostRecentProject` 在全量并行负载下偶发超时（`waitUntil` 3s 轮询 `projectURL`），单独跑 5/5 通过、全量重跑亦通过。根因是异步打开 + 真实时钟轮询，属 v0.10.0 既有用例，与本版实际时间无关。

---

## 6. 与 A/B 组单测的分工

- A 组 `Tests/KairoCoreTests/TaskItemActualDatesTests.swift`：模型层单测（初始化、Codable 往返、CodingKeys 逐个键）。
- B 组 `Tests/KairoCoreTests/SessionActualDatesTests.swift`：`applyStatus` 的分支单测。
- 本文件：**判据级验收**——每条用例对一条 `07 §9` 判据，只断言可观察的对外语义（状态 / 进度 / 两个时间戳 / 错误码 / 编码形状 / 排期不变），不拆内部函数、不锁参数实现。三份文件重叠是刻意的：验收红了要能指着 §9 某一条说话。

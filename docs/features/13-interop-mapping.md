# 13 · 互操作映射：Kairo ↔ OmniPlan / MS Project（MSPDI）

> 调研稿，基线 v1.0.1（bc6ce10）。只记录两侧模型事实与可逆性判断，不含实现方案。
> 仓库现状：已有的机器通道只有**基线偏差 CSV 导出**（11 列，带 taskID UUID，`Sources/KairoCommands/BaselineVarianceCSV.swift:23-30`）；**没有任何计划级导入/导出**，本文是首个互操作规格。
> 结论先行：`.oplx` / `.mpp` 都是版本绑定的私有封装，唯一稳定通道是 **MSPDI（MS Project XML）**——OmniPlan 与 MS Project 双向读写它；CSV 只作降级备份（无层级、无依赖）。
> 判定记号：**A** 直接映射 ｜ **B** 需换算或有损 ｜ **C** 只能丢 ｜ **↔** 对方有而 Kairo 没有

## 1. Kairo 侧事实（口径来源）

- 任务字段 21 个：`TaskItem.swift:22-57`（title/notes/startDate/dueDate/priority/status/tags/assignee/kind/parentID/effortHours/durationDays/dependencies/progress/constraint/schedulingPolicy/completedAt/actualStart/assignments/cancelReason + id）。
- 状态 5 值 pending/in_progress/done/blocked/cancelled（`TaskItem.swift:9-13`）；cancelled 完全退出排期、不进关键路径（`ScheduleEngine.swift:33-36`），cancelReason 必填留痕（`TaskItem.swift:55-57`）。
- 种类 3 值 task/group/milestone（`TaskDependency.swift:3-8`）。**group = 阶段门**：自身不排期，窗口 = 子树 min(start)/max(finish)（`ScheduleEngine.swift:408-454`），群组依赖下推到子树全部叶子（同文件 `:124-145`、`:197-216`）。
- 工期：milestone 恒 0；`durationDays` 优先；否则 `effort/8/Σ(units×efficiency)`；无值默认 1 天（`ScheduleEngine.swift:104-112`）。
- 相关性：FS/SS/FF/SF + `lagDays`（天，可正可负、可为小数）（`TaskDependency.swift:13-34`）；四条传播不等式见 `ScheduleEngine.swift:17-21`。
- 日历：**日历天，一周 7 天**（`ScheduleEngine.swift:10-12`；`GanttLayout.swift:166-168` 的 `nonWorkingWeekdays` 默认空）。无节假日 / 工作时段 / 资源日历；工作日历 F-22-06 明确排在 1.x 之后（`docs/release-1.0-scope.md:97`）。
- 约束：4 种单向（start|end × noEarlier|noLater）（`SchedulingConstraint.swift:6-10`），且是**软约束**：冲突只产生违例，不拒绝排期（`Violation.swift:24-52`）。
- `dueDate` **不参与排期**（`ScheduleAnchor.swift:32`；仅逾期展示与违例窄窗判据 `ViolationEngine.swift:142-150`）——它不是 deadline。
- 策略 asap/alap（`SchedulingConstraint.swift:40-43`），在最早/最晚窗口间选定（`ScheduleEngine.swift:382-394`），产出总宽延/自由宽延。
- 资源：4 类 person/equipment/material/group + units + efficiency（`Resource.swift:17-21`）；分配只有 (resourceID, units)（`:39-47`）。**无费率、无成本、无资源日历、无资源平衡**。
- 基线：条数不设硬上限（`08-baselines.md:304`），同屏最多 3 条（`10-multi-baseline-gantt.md:45`），8 色（`BaselinePalette.swift:18-19`）；条目五元组 `(taskID,start,finish,progress,isMilestone)`，finish 为排他端点，**无 work/cost 基线**（`Baseline.swift:5-30`）。
- 实际：actualStart / completedAt 不进 CPM，只做基线偏差（`BaselineEngine.swift:216-241`）。

## 2. 双向映射表

| Kairo | OmniPlan | MSPDI 元素 | 判定 |
| --- | --- | --- | --- |
| `title` | Task Title | `Task/Name` | A |
| `notes` | Task Note | `Task/Notes` | A |
| `kind = milestone` | Milestone | `Task/Milestone=1` + `Duration=PT0H0M0S` | A |
| `kind = group` | Summary（滚动汇总） | `Task/Summary=1` | A（依赖语义见 §3.2） |
| `parentID` + 大纲序 | Outline Level | `OutlineLevel` / `OutlineNumber` | A（须保序写出） |
| `effortHours` | Effort | `Task/Work`（ISO8601 时长） | A |
| `actualStart` | Actual Start | `Task/ActualStart` | A |
| `completedAt` | Actual Finish | `Task/ActualFinish` | A |
| `startDate` | Start（可手工钉住） | `Task/Start` 或 `ConstraintType=4/5` | B：输入意图 vs 计算结果 |
| `durationDays` | Duration | `Task/Duration` + `DurationFormat` | B：日历天 → 工作日 |
| `dependencies.type` | Finish→Start 等 4 型 | `PredecessorLink/Type`（0=FF,1=FS,2=SF,3=SS） | B：枚举顺序不同 |
| `dependencies.lagDays` | Lead / Lag（天） | `PredecessorLink/LinkLag`（**十分之一分钟**）+ `LagFormat` | B：单位换算 + 小数截断 |
| `constraint`（4 型） | 同名 4 型（另有 Must Start/Finish On） | `ConstraintType` 4=SNET 5=SNLT 6=FNET 7=FNLT（0=ASAP 1=ALAP 2=MSO 3=MFO） | B：软 → 硬 |
| `schedulingPolicy` | 项目级排期方向 | `ConstraintType` 0/1 | B：任务级 → 项目级 |
| `progress`（0…1 小数） | % Complete | `PercentComplete`（0-100 整数） | B：丢小数位 |
| `status` | 完成度 + 状态标记 | `PercentComplete` + `Active` | B：blocked/cancelled 无对应 |
| `assignments`（units） | Assignment Units（%） | `Assignment/Units`（1 = 100%） | B：无 assignment 工作/成本 |
| `priority`（4 档） | 无原生字段 | `Task/Priority`（0-1000） | B：OmniPlan 侧需借 Note/Tag |
| `tags` | 无原生字段 | 自定义 `ExtendedAttribute`（Text1…） | B：需键位约定 |
| `assignee`（自由文本） | Staff 资源名 | `Resource/Name` | B：须先建资源再挂分配 |
| `resources`（units/efficiency） | 资源 + 日历 + 费率 | `Resource/MaxUnits`、`StandardRate`、`CalendarUID` | B：只带走 units |
| `baselines`（任意条，5 元组） | 文档级快照：仅 Planned Start/End + 两个 Variance | `Task/Baseline/BaselineNumber`（0…10，共 11 槽） | B：超 11 条必丢；无 work/cost 基线 |
| `metadata.projectStart/projectEnd` | Project Start/End | `Project/StartDate`、`FinishDate` | B：finishDate 是推算值 |
| `metadata.direction` | Schedule from Start/End | `Project/ScheduleFromStart` | A |
| `cancelReason` | 无 | 无 | C：只能写进 Notes 尾部（污染原 note） |
| `id`（UUID） | 无 | `Task/UID`（整数） | C：需旁路文件保 UUID，否则回传全丢 |
| ↔ 工作日历 / 例外日 | Project & Resource Calendar | `Calendar/WeekDays/StandardRate…Exceptions` | ↔ 无 |
| ↔ 资源日历、资源平衡 | Resource Calendar + Leveling | `Resource/CalendarUID`、`LevelingDelay` | ↔ 无 |
| ↔ `Deadline` | Deadline | `Task/Deadline` | ↔ 无（dueDate 不等价，见 §3.4） |
| ↔ 成本 / 固定成本 / 挣值 | Cost | `FixedCost`、`Cost`、`BCWS/BCWP` | ↔ 无 |
| ↔ 任务类型（固定工期/工时/单位） | Task Type | `Task/Type`（0/1/2） | ↔ 无（Kairo 固定按 durationDays 优先） |
| ↔ 日历例外、循环任务、子项目 | Repeats / Subproject | `Recurring`、`IsSubproject` | ↔ 无 |

**比例**：21 个任务字段里 A = 7（title/notes/kind 两值/parentID/effortHours/actualStart/completedAt），**33%**；B = 12（57%）；C = 2（id/cancelReason，10%）。

## 3. 语义鸿沟（按后果排序）

1. **日历天 ↔ 工作日（最大鸿沟）**：Kairo 5 天 = 跨 5 个自然日；对方 5 天 = 跨 7 个自然日的 40 工时。导入对方 5 天任务，Kairo 会连周末一起排，整条 FS 链右移约 2 天/周；反向导出则 Kairo 的 7 天任务被压缩成 5 个工作日。**偏差随链长线性放大**，且没有任何字段能表达「这 2 天是周末而非工作量」。
2. **阶段门 vs 汇总任务**：Kairo 的群组依赖会**下推到子树全部叶子**（`ScheduleEngine.swift:197-216`）；MSPDI 的 Summary 任务依赖只落在汇总行上，导入后若只还原成「群组→任务」单边，下游只顺延一部分（正是 issue #16 的症状）。
3. **软约束 ↔ 硬约束**：Kairo 的 noLater/endNoLater 冲突只出违例、仍照常排期；对方（尤其 MSP 的 SNLT/FNLT 与 Must … On）会**移动任务或报冲突**。导入后「原本能打开的计划」在对方那里打不开，导出后「原本的违例行」被静默改期。
4. **dueDate ≠ Deadline**：把 Kairo `dueDate` 写成对方 `Deadline` 会让对方开始按截止日反向施压；把对方 `Deadline` 读成 `dueDate` 则**排期效果消失**（Kairo 里它只影响逾期色）。两侧都「看起来导成功了」，实际含义已换。
5. **lag 单位与小数**：MSPDI `LinkLag` 以十分之一分钟计（8h/日口径下 1 天 = 480000），且受对方 `MinutesPerDay/DaysPerWeek` 影响；Kairo lag 是可直接取小数的天。往返一次小数位被截断，关键路径判定可能翻转。
6. **无资源日历 / 无资源平衡**：对方能做「张三周一二不在 + 负载 200% 时自动顺延」；Kairo 只有 `units×efficiency` 的静态换算，导入后资源冲突信息（`OverAllocated`、`LevelingDelay`）**无处安放**，只能丢弃或落备注。
7. **成本 / 挣值整体蒸发**：对方基线含 BCWS/BCWP、任务含 FixedCost；Kairo 基线只有时间与完成度，成本类字段 100% 丢失，且丢失无痕迹。
8. **多基线**：Kairo 不限条数、8 色、可同屏 3 条；MSPDI 只有 `BaselineNumber` 0…10 共 11 槽，OmniPlan 止于 Planned Start/End 加两个 Variance（无工期偏差列，见 `BaselineEngine.swift:31-35`）。**第 12 条起必丢**，颜色索引（Kairo 独有）也无落点。
9. **取消语义**：对方没有 cancelled；Kairo 取消任务不占工期、不进关键路径。导出时只能删除（丢审计）或标记为 0% 完成（**污染排期与进度分母**）。cancelReason 是 Kairo 唯一的「为什么不做了」记录，导出后不可恢复。
10. **单位口径 8h/日 vs 项目 MinutesPerDay**：Kairo 硬编码 8 小时/日（`ScheduleEngine.swift:109`）；对方项目可设 `MinutesPerDay=450`。同一份 effort 往返后工期差 11%。

## 4. 导入保真度分级（用于决定「能不能导」）

**A｜完全可逆**（往返后逐字段相等，可默认接受）
title、notes、kind（task/milestone/group）、大纲层级与顺序、effortHours（小时制）、actualStart、completedAt、projectStart、direction、FS 型依赖且 lag 为整数天、MSPDI `Priority`。

> 注：A 级仍要求「双方日历口径一致」——导入前若确认对方为 7 天工作日历，A 级才成立。

**B｜有损但可预期**（必须预检提示 + 落日志，允许导入）
durationDays（工作日→日历天换算）、lag 小数、progress 小数位、constraint（软硬语义）、schedulingPolicy（项目级降级为逐任务）、assignments（只保 units）、assignee（文本→资源）、tags（借自定义字段）、priority（OmniPlan 侧落备注）、baselines（≤11 槽、仅时间/完成度）、status（blocked→pending、cancelled→按策略）。

**C｜不建议导入**（宁可拒绝并说明，也不静默降级）
工作日历/例外日（会把「周末不计」偷换成「周末计」）、资源日历与资源平衡结果、成本与挣值（BCWS/BCWP/固定成本/费率）、`Deadline`（无等价字段，硬塞进 constraint 会改排期）、Must Start On / Must Finish On（Kairo 无钉住型约束）、循环任务、子项目、`Task/Type`（固定工时/单位/工期三态）、`id`（UUID 无法保存，回传必断链）。

**判定原则**：一条计划若含 C 级字段，默认**拒绝整单导入**并列出清单；用户显式勾选「我接受丢失」后才走 B 级通道。C 级字段不得以「写进 notes」的方式假装保留。

## 5. UI 侧硬要求

**导入前必须有预检报告（不可跳过、不可默认折叠）**，逐项列出：
1. **将丢失的字段**：按任务计数（如「成本：48/48 条丢失；Deadline：6 条丢弃；工作日历：整体丢弃」），给出「继续 / 取消」两个按钮，默认焦点在取消。
2. **日历换算方式与偏差预估**：明确写「对方按 5 天/周（周工作 40h），Kairo 按 7 天/周排期；本计划 12 个任务的平均工期将缩短 X%，关键路径预计提前 Y 天」，并在导入后把该说明存进项目 notes，避免用户日后误判偏差来源。
3. **依赖降级明细**：哪几条 lag 会被取整（原值→新值）、哪几条 constraint 从硬变软（并标注「导入后不再自动改期，只出违例」）、哪几条因前驱缺失将成为悬空边并被忽略。
4. 报告需可复制为文本，便于用户贴进邮件与对方核对。

**导出时必须在产物内标注 Kairo 独有信息无法带走**：
1. 导出弹窗列出不可带走的项：取消原因、基线颜色索引（8 色）、多基线超出槽位的部分、blocked 状态、软约束的「只报违例」语义、跨群组下推的隐式依赖（`effectiveDependencies`）。
2. 无法带走的内容写进**导出旁注文件**（`<项目名>.kairo-export-notes.md`，与主文件同目录），而不是塞进对方的 Notes 字段污染原文；文件头注明导出时间、Kairo 版本、随附的 `formatVersion` 与源文件名，便于回导时人工比对。
3. 导出成功后提示「本次导出为单向快照：回导不会恢复基线颜色与取消原因」，并提供「导出旁注文件」的打开入口。

## 6. 待与具体版本核对（不得当结论引用）

- OmniPlan 各版本是否支持多基线快照、其 MS Project 导入是否接受 2010+ MSPDI。
- OmniPlan 是否保留 `Priority`（本文按「无原生优先级」处理）。
- 对方 `MinutesPerDay/DaysPerWeek` 与 `LinkLag` 的换算细则需以实际文件验证一次（建议各造 1 个 1 天 FS+1 天 lag 的最小样本对拍）。

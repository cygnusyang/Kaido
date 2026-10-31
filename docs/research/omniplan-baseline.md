# OmniPlan 基线 / 实际进度语义与业界口径

> 调研日期 **2026-10-25**。来源口径：**[官方]** = OmniPlan 4 参考手册（macOS 4.2.2 / iOS 4.7）原文；**[官方-旧]** = OmniPlan 2.4.1 手册（仅用于标注版本差异）；**[推断]** = 文档未明说、由行为反推或业界实践；**[二次]** = 未能直连原始出处。
> 本次 PMI 站点 PDF 返回 403，PMBOK 定义只能二次引用，见第 4 节。

## 0. 结论摘要

1. OmniPlan 只有**两层时间轴**：baseline（冻结快照）与 actual（活日程）。设基线后一切编辑都改 actual，**不存在独立的「当前预测」层**。
2. 基线**数量不限**、可命名（默认今日日期）、可删除，但**任一时刻只对比一份**（选中的那份）。
3. 基线在 4.x **只读**：任务检查器基线区「不可直接编辑」；2.4.1 曾允许逐任务改基线日期，4.x 已收紧。
4. 偏差口径极简：开始偏差 / 结束偏差 / 项目结束偏差，单位是时间；**没有工期偏差列**，挣值（SV/SPI）另属 Pro 的 EVA 列组。
5. Kaido 不能照抄「两层」：Kaido 的 `scheduledStart` 是**预测**不是事实，需引入第三层，否则违例引擎与关键路径语义整体错位。

## 1. 功能清单（OmniPlan 4）

| 能力 | 行为 | 来源 |
| --- | --- | --- |
| 创建基线 | 项目菜单 **Set Baseline** = 用当前 actual 日程造快照 | [官方] mac 4.2.2 菜单章 |
| 命名 | 设置时弹名称框，**默认名 = 今日日期** | [官方] iOS 4.7 工具栏章 |
| 多基线 | 「as many baselines as you want」，任意时点可再拍快照 | [官方] iOS 4.7 |
| 删除 | 基线菜单 **Edit** → 删除开关 / 项目菜单 **Delete Baseline** | [官方] iOS 4.7 / mac 4.2.2 |
| 覆盖范围 | 整项目快照；4.x **无「仅选中任务」选项**（2.4.1 有该勾选框） | [官方] / [官方-旧] |
| 锁定性 | 基线**不可编辑**：检查器明示「cannot be edited directly」 | [官方] mac 4.2.2 任务检查器 |
| 选择对比 | 选中某基线后，基线起止「may change depending on which baseline you select」 | [官方] 同上 |
| 视图模式 | 视图 > **Baseline Comparison**：仅实际 / 仅基线 / **双日程**（基线灰色全高条，重合处被实际条盖住）/ **分割**（上半实际、下半灰色） | [官方] mac 4.2.2 视图菜单 |
| 偏差列 | 大纲列：**Planned Start / Start Variance / Planned End / End Variance** | [官方] mac 4.2.2 大纲列 |
| 项目级偏差 | 项目检查器 Summary **Variance** = 项目实际结束 vs 所选基线结束 | [官方] mac 4.2.2 项目检查器 |

## 2. 语义定义

- **Baseline schedule**：「a project is planned to proceed from a given point in time」；**Actual schedule**：「the way the project turns out in real life」。设基线前两者恒等，设基线后编辑只改 actual。[官方] 术语表
- **Actual 就是活日程本身**：大纲 Start/End 列的定义是「the actual start time，由 leveling 自动决定，或在此单元格 / Task Schedule 检查器手动设置」——**自动排期结果与人工录入写进同一个字段**，OmniPlan 不做区分。[官方]
- **Variance**：「the amount of time by which the actual schedule differs from the baseline schedule」，自动计算、无需录入。[官方]
- **完成度**：Completed 为工作量百分比，甘特条上以内部阴影表示，另有 house 形手柄拖动调整；**Catch Up** 按指定日期批量推进完成度；**Reschedule** 把未完成任务整体前移。[官方] 甘特视图章
- **Actual 何时产生**：文档只说 load leveling 会自动决定、也可手填；**没有**「进度 > 0 自动写实际开始」的明文。[推断] 实际由当前编辑日期 + 排期推导，故「实际开始」在 OmniPlan 里通常是**推导值而非承诺值**。
- **里程碑**：零时长、零工作量任务，随依赖与日历移动。[官方] 术语表
- **2.4.1 差异（历史）**：旧版 Actual 起止可「locked against accidental editing, changes from dependencies, and leveling」；基线日期可逐任务改。4.x 取消锁与逐任务基线编辑，改用 Automatic/Manual 排期方式表达同类意图。[官方-旧]

## 3. 边界条件

| 情形 | 结论 | 来源 |
| --- | --- | --- |
| 设基线后新增任务 | 无基线值，偏差列应为空/不参与对比 | [推断] 文档未明说 |
| 删除任务后 | 快照内条目成孤儿；4.x 无任何孤儿清理或告警说明 | [推断] |
| 基线被删 | 直接删除，**无变更审批、无审计留痕** | [官方] |
| 切换对比基线 | 所有偏差列随所选基线整体变化 → 报表必须显式记录「用的哪份基线」 | [官方] + [推断] |
| 基线是否含依赖关系 | 快照对象是**日期**（起止 / 进度），文档未提依赖边、资源分配的基线化 | [推断] |
| 日历 / 工时变更 | 偏差以时间量表达，工作日历改动会改变「天数」口径 | [推断] |
| 里程碑偏差 | 零时长，开始偏差 = 结束偏差 | [推断] |
| 只快照部分任务 | 4.x 不支持；2.4.1 支持（Set only on selected tasks） | [官方]/[官方-旧] |

## 4. PMI / PMBOK 口径

- **Baseline**：工作产物的**已批准版本**，只能通过正式变更控制程序修改，用作与实际结果比较的基准；**Schedule baseline** = 进度模型的已批准版本。[二次] PMBOK 6 术语表通行表述；PMI Lexicon PDF 本次 403，未能原文核验。
- **Performance measurement baseline**：scope + schedule + cost 三条基线合成，供挣值分析使用；re-baseline 是受控、留档的决定，不得用于掩盖延期，且**应保留历史基线**。[二次]
- 与 OmniPlan 的差异：PMI 强调「批准 / 变更控制 / 留档」，OmniPlan 只提供「快照 / 可删 / 可多份」——**没有审批状态、没有变更理由字段**。[对比推断]
- 对 Kaido 的现实取舍：Kaido 是单人/小团队工具，**不必实现变更控制流程**，但应保留「谁在什么时候拍了哪份基线」这一最小留痕（可用 name + snapshotDate + 可选备注）。

## 5. 对 Kaido 的约束与风险

### 5.1 硬约束

- **C1｜三层时间轴，不是两层。** baseline（冻结）/ plan（当前预测，引擎 `scheduledStart/scheduledFinish`）/ actual（事实，新增 `actualStart/actualEnd`）。照抄 OmniPlan 会把 Kaido 的「计划」改名「实际」，导致违例、关键路径、宽延全部口径错位。
- **C2｜基线必须是独立快照集合，不能回写任务单值。** 现行 F-14-16 方案写 `TaskItem.baselineStart/baselineEnd` 只能承载一份基线，与 F-12-17 / US-E2-06 的「多基线 + 切换对比」直接冲突。偏差应是「所选基线 × 任务」的**派生量**，不落盘。
- **C3｜偏差口径必须显式声明基准。** OmniPlan 一律「actual vs baseline」；Kaido 未录实际时（大量任务）会出现空值，需定义回落规则（actual 缺失 → 以 plan 对比并标注为「预测偏差」），且报表要带 `baselineID`，否则跨版本报表不可比。

### 5.2 风险与缓解

| 风险 | 说明 | 缓解 |
| --- | --- | --- |
| 文件体积 | 500 任务 × 10 基线 × 全字段快照 ≈ 数 MB 级；`.kaido` 是人工可读、git 友好的 JSON | 快照只存 `(taskID, start, finish, progress, isMilestone)`；不复制 title/tags |
| 格式兼容 | `currentFormatVersion = 1`，读路径忽略未知字段 → **旧版打开新文件再保存会静默丢基线** | 升 `formatVersion = 2` 走既有 `FormatMigrationPlan` 加法迁移 |
| 视图状态混入数据 | `selectedBaseline` 是 UI 偏好，不该进撤销栈、不该污染 diff | 与列宽偏好同处理（不进撤销栈） |
| 写入入口分裂 | actual 可能被「状态回写」与「甘特拖拽 / 检查器」两路写 | 单一写入路径 + 一个派生出口（D-021 的教训正是字段有多个来源导致拖拽不生效） |
| 语义蔓延 | 「基线关键路径」「基线依赖」需要快照依赖边，成本陡增 | 一期只快照时间与进度，依赖不基线化 |
| 完成度与实际的耦合 | 若「进度置 1 自动写 actualEnd」可能覆盖人工录入 | 自动只在字段为空时回填，且可在时间线里撤销 |

### 5.3 与既有文档的落点

- PRD **US-E2-06 基线快照与差异**（已存在）、规格 **F-14-16 / F-12-17 / F-13-09 / F-22-05**（均 P2）。
- 三处需要修订：F-14-16 的「回写 TaskItem.baselineStart」、F-13-09 的「`baselineStart/baselineEnd: Date?` 单值」、F-22-05 的「差异 = 实际 − 基线」（缺 actual 时的口径）。

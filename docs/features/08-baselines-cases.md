# 基线（v0.13）验收用例与判据

> 依据：[08-baselines.md](./08-baselines.md) §9（12 条判据）、§4（偏差口径）、§5（孤儿）、§7（迁移与兼容）、§8（接口契约）；
> 版本范围：[09-baseline-version-plan.md](./09-baseline-version-plan.md) §2。
> 本文件是**测试前置**产物：判据 → 用例的映射表，实现完成后逐条转绿。
> 自动化文件：Tests/KairoCoreTests/BaselineAcceptanceTests.swift（本文件产出的 37 例，覆盖 core / storage / commands）。
> 其余三层已由各 owner 补齐并纳入同一门禁：Tests/KairoPresentationTests/BaselinePresentationTests.swift（pres，19 例）、Tests/AppTests/BaselineWorkspaceTests.swift（app，17 例）、Tests/InterfaceTests/BaselineInterfaceTests.swift（cli + mcp，12 例）。
> 全仓基线相关用例合计 139 例（本文件 37 + coder-core 侧 54 + pres 19 + app 17 + cli/mcp 12）；例数仍在随 owner 增补变动，门禁结论以全量运行的总数为准。
> §3 记录各层归属、已核的关键断言，以及本版明确不做的范围；未做的验证在 §5 末尾列明。

## 0. 口径

**L1 层级**：core = KairoCore（模型 / 引擎 / 存储）｜storage = KairoCore.Storage（KairoFile + FormatMigration，归 core 目标但单列以便定位）｜commands = KairoCommands.KairoSession（唯一写入口）｜pres = KairoPresentation（快照 / 列策略 / 视图状态）｜app = Apps/macos（Store / 视图）｜cli = KairoCLI + KairoMCP。

**L2 三层时间轴**：基线（冻结 Baseline.entries）/ 计划（引擎 scheduledStart/Finish）/ 实际（actualStart + completedAt）。断言必须能指出自己比较的是哪两层；把 plan 冒充 actual、或让基线回流排期，一律判红。

**L3 排期表类型**：§8 写的 schedules 参数类型是 [UUID: ScheduleEntry]，仓库内**没有** ScheduleEntry 这个类型，既有排期结果是 ScheduledTask。用例统一按 [UUID: ScheduledTask] 构造（手工构造，不跑 ScheduleEngine），实现与之一致；若后续引入新类型，只需改 BaselineAcceptanceTests.swift 的 scheduleMap 一处。

**L4 时间注入**：所有时刻由参数给出（now: 与字面日期）；core 用 UTC 字面日期，命令层用本地日历零点（ScheduleEngine 与默认名都用当前时区的公历，混用会把时区偏移误判成实现缺陷）。用例内不读 Date()。

**L5 期望值独立**：期望值写成字面日期/整数，不用被测函数现算（D-009 教训）。日算术的对照值由测试侧独立实现（Calendar.dateComponents）给出。

**L6 偏差符号**：偏差 = 后者 − 基线，单位日历天；正数 = 比承诺晚，负数 = 提前；**空缺一律 nil，不写 0**（0 表示准时，与无数据不同）。

**L7 自动化列**：✅ = 已落盘并在 2026-10-25 的收口全量门禁（1073 tests / 98 suites）中通过；用例归属见每行的层标识，文件名见文首。❌ 待裁定 = 用例已落盘但对当前实现为红（本轮无此项）。

---

## 1. §9 判据 1-12 → 用例

| ID | 判据（08 §9） | 用例名（BaselineAcceptanceTests.swift） | 输入 / 前置 | 预期 | 层 | 自动化 |
|---|---|---|---|---|---|---|
| B-01 | 1. 创建基线：条目数 = 已排期任务数；默认名含日期与序号；createdAt 取注入时钟 | snapshotCapturesOnlyScheduledTasks、snapshotRecordsMilestoneAsZeroDuration、snapshotWithoutSchedulesHasNoEntries、createBaselineUsesInjectedClockAndDefaultName | core：3 任务（2 条有排期、1 条无）+ 1 里程碑；commands：projectStart=11-03，2 任务 duration 2/3 | core：entries.count == 2、无排期任务不入表、createdAt == 注入值、anchor 落盘、里程碑 start == finish 且 isMilestone；commands：entries.count == 2、name 前缀「基线 1」+ 含 now 的 yyyy-MM-dd、第二次为「基线 2」且名字不同 | core + commands | ✅ 三例 core + 一例 commands |
| B-02 | 2. 不可变：无 API 改既有条目；rename 只改名字；delete 后其余基线不受影响；再拍一份是新增不是覆盖 | baselineHasValueSemantics、editingTasksDoesNotMutateExistingBaseline、renameOnlyChangesName、deleteBaselineLeavesOthersAndTasksIntact、secondSnapshotAddsNewBaseline、createBaselineIsUndoable | ① 拷贝 Baseline 后改 name/entries；② 拍完改任务 duration 2→6 并置 in_progress；③ rename 为「承诺 V1」；④ 两条基线删第一条；⑤ 改 duration 后拍第二份；⑥ snapshot → createBaseline → restore | ① 原快照不变（值类型）；② 重新读到 == 原 Baseline（条目 finish 仍 11-05）；③ id/createdAt/entries 不变；④ 只剩第二条、任务列表逐字段不变；⑤ id 不同、entries 不同、第一条仍是旧承诺；⑥ restore 后基线与任务一起回滚 | core + commands | ✅ 六例（基线段无 update 入口由「KairoSession 只提供 create/rename/delete」编译期保证） |
| B-03 | 3. 偏差公式：B.finish=11-05、P.finish=11-08 → 3；提前一天 → −1；空值 → nil（不是 0） | planVarianceIsSignedCalendarDays、missingLayersStayNilInsteadOfZero | 同一基线（11-03→11-05），计划分别改为 11-05→11-08、11-02→11-04、计划不变且无实际 | 3 / −1；计划未变时 planFinishVariance == 0（合法 0），actualStartVariance 与 actualFinishVariance == nil，不写成 0 | core | ✅ 两例 |
| B-04 | 4. 跨 DST（America/New_York 11-02 回拨）不产生 ±1 天漂移 | varianceAcrossDstFallBackHasNoDrift、calendarDayMathCountsWholeCalendarDays | 基线 11-01→11-02；计划 11-02→11-04（正向）与 11-01→11-02 且基线 11-01→11-03（反向 −1） | 正向 2、反向 −1；同日不同时刻算 0；CalendarDayMath 直接断 3 / −1 / 0 / 0 / −1 | core | ✅ 两例 |
| B-05 | 5. actual 缺失：actualFinishVariance == nil 且 overdueDays 有值；完成后 overdueDays == nil | missingLayersStayNilInsteadOfZero、completedTaskDropsOverdueAndCarriesActualVariance | ① 未完成、无 actualStart/completedAt；② status=done、actualStart=11-02、completedAt=11-08 | ① 两 actual 偏差 nil、overdueDays != nil、overdueOpenCount == 1、predictedTaskCount == 1；② actualStartVariance == −1、actualFinishVariance == 3、overdueDays == nil、overdueOpenCount == 0 | core | ✅ 两例 |
| B-06 | 6. 偏差输出必带 baselineID/name/createdAt | reportCarriesBaselineIdentity、varianceDefaultsToLatestBaselineAndCarriesIdentity | core：单任务报告；commands：两条基线，分别按 id 与「省略 = 最新」查询 | 三字段逐项等于所选基线；省略 id 时指向最新一条 | core + commands + pres + app + cli | ✅ 全层：core/commands 两例；pres baselineColumnWidthsFollowDateAndNumberColumns；app baselineColumnCopySaysPlanVariance（列头「计划偏差」）；cli/mcp 四出口身份三字段各一例（baseline list/create/delete/variance 文本 + --json、MCP 三工具 + baseline_variance） |
| B-07 | 7. 基线后新增：hasBaseline == false、偏差列 —、计入 tasksWithoutBaseline、不计入项目偏差 | taskAddedAfterBaselineIsFlaggedWithoutVariance、addedAndDeletedTasksStayVisibleFromCommands | 基线只含任务 A；现任务有 A 与「基线后新增」 | report.tasks 含「新增」任务且 hasBaseline == false、baseline 三字段与 plan 偏差全 nil；tasksWithoutBaseline == 1；projectFinishVariance 只按有基线条目算（== 1） | core + commands + pres + app | ✅ 四层：core/commands 两例（首轮为红，实现按 §4-1 方案 (a) 对齐后转绿）；pres taskAddedAfterBaselineHasNoVariance（hasBaseline == false、偏差 nil）；app missingEntryCellsRenderPlaceholder（单元格 —） |
| B-08 | 8. 删除任务后：进 orphans、大纲行集合不变、项目偏差不含它、面板可见「已删除」 | deletedTaskBecomesOrphanAndLeavesProjectVarianceIntact、addedAndDeletedTasksStayVisibleFromCommands | 基线含 A（11-03→11-05）与 B（11-03→11-07）；B 从任务列表删除，A 计划后移一天 | orphans == [B]、孤儿条目仍读出承诺起止、report.tasks 无合成行、projectFinishVariance == 1；命令层基线条目数仍为 2（未被静默清理） | core + commands + pres + app | ✅ 四层：core/commands 两例；pres deletedTaskShowsUpAsOrphanInPanel、panelSeparatesOrphansFromTasksWithoutEntry；app deletedTaskAppearsInBaselinePanel（大纲不插行由 ADR-013 行索引用例兜住） |
| B-09 | 9. 群组：偏差取自身条目聚合值，不等于子任务偏差之和 | groupVarianceUsesOwnEntryNotChildrenSum | 群组（B 11-03→11-07）与两个子任务；计划整体后移 2 天 | 群组 planFinishVariance == 2；两子任务各 2；群组值 ≠ 子任务之和（4） | core | ✅ |
| B-10 | 10. 切换基线（setBaseline）只改视图状态：不产生撤销点、不置脏、不写文件 | switchingBaselinesDoesNotAffectEachOther | 两条基线（finish 11-05 / 11-08），同一任务分别查询 | 两条报告各给各的偏差（3 / 0）、反复交错查询结果稳定、基线集合不变 | commands + pres + app | ✅ 三层：commands switchingBaselinesDoesNotAffectEachOther（数据侧互不影响、重复查询稳定）；pres viewStateHasNoBaselineByDefault、switchingBaselineChangesVariance、danglingSelectionNormalizesOnRead（归一化只读、不改写 viewState）、danglingSelectionSnapshotMatchesNoSelection（悬挂选择下快照等价「未选」）；app setBaselineIsViewStateOnly、undoKeepsSelectedBaseline（撤销后选择保留）、danglingBaselineSelectionIsNormalizedAfterUndo（删除选中基线 → 撤销 → 不悬挂）、switchingBaselineDoesNotTouchProjectFile（文件 mtime 与字节均不变）、selectedBaselinePersistsAcrossLaunch、varianceIsCachedAcrossViewOnlyActions（纯视图动作 0 次重算） |
| B-11 | 11. 格式版本：§7.6 六条迁移/兼容用例全绿；needsFormatUpgrade v1 为 true、v2 为 false | currentFormatVersionIsTwo、v1FileOpensWithEmptyBaselinesAndNeedsUpgrade、savingProjectWithoutBaselinesOmitsBaselinesKey、v2BaselinesSurviveRoundTrip、baselineEntryEncodingKeepsContractKeys、futureFormatVersionIsRejectedWithoutTouchingDisk、v2MigrationOnlyBumpsVersionAndKeepsUnknownRootKeys、v1MissingResourcesAndBaselinesFallBackToDefaults、oldClientRejectsV2File、openingV1ThenSavingUpgradesToV2、openingV2FileNeedsNoUpgrade | v1 / v2（2 基线 + 1 孤儿）/ v3 夹具；临时文件 | 见 §2 迁移矩阵；currentFormatVersion == 2；保存无基线时省略 baselines 键；v3 抛 unsupportedFormatVersion(3) 且磁盘字节不变；迁移只碰 formatVersion（未知根键 futureThing 保留）；打开不落盘 | storage + commands | ✅ 十一例 |
| B-12 | 12. CLI 与 MCP 的偏差数值与 BaselineEngine.variance 逐字段一致（对等性门禁） | — | — | kairo baseline variance / MCP baseline_variance 的每个数值（含 nil 留空、负数带符号）与引擎输出逐字段相等 | cli + mcp | ✅ 三例对等性：baselineVarianceJSONMatchesEngine（CLI --json 逐字段 == BaselineEngine.variance）、baselineVarianceMCPMatchesEngine（MCP baseline_variance 同上）、baselineVarianceCLIAndMCPAgreeOnFilteredTask（--baseline/--task 过滤后两侧一致且仍等引擎）；空值省略与非 0 负号由 baselineVarianceJSONOmitsEmptyValuesAndKeepsSigns 覆盖 |

---

## 2. 补充用例（lead 指定 + 边界）

| ID | 场景 | 用例名 | 输入 / 前置 | 预期 | 层 | 自动化 |
|---|---|---|---|---|---|---|
| S-01 | 多基线切换互不影响 | switchingBaselinesDoesNotAffectEachOther | 同 B-10 | 见 B-10 | commands | ✅ |
| S-02 | 删除基线不动其它基线 | deleteBaselineLeavesOthersAndTasksIntact | 两条基线删第一条 | 剩余基线 == 第二条（逐字段）、任务列表 == 删除前 | commands | ✅ |
| S-03 | 孤儿条目（任务已删） | deletedTaskBecomesOrphanAndLeavesProjectVarianceIntact | 见 B-08 | 孤儿不进 report.tasks、不进项目偏差，条目仍带 start/finish | core | ✅ |
| S-04 | 基线后新增任务无基线条目 | taskAddedAfterBaselineIsFlaggedWithoutVariance | 见 B-07 | hasBaseline == false、偏差全 nil、计入 tasksWithoutBaseline、不参与项目结束偏差 | core | ✅ |
| S-05 | 偏差空值不写 0 | missingLayersStayNilInsteadOfZero | 计划与基线一致、无实际时间 | planFinishVariance == 0（合法 0），两个 actual 偏差 == nil | core | ✅ |
| S-06 | 格式迁移矩阵 v1→v2 / v2 直读 / v3 拒读 | v1FileOpensWithEmptyBaselinesAndNeedsUpgrade、v2BaselinesSurviveRoundTrip、futureFormatVersionIsRejectedWithoutTouchingDisk | 见下矩阵 | 见下矩阵 | storage | ✅ 三例 |
| S-07 | 旧客户端打开 v2 报 unsupportedFormatVersion | oldClientRejectsV2File | 用 KairoFile.read(from:targetVersion:1, plan:) 模拟 ≤ v0.12 客户端；分别喂「v2 有基线」与「v2 无基线」 | 两者都抛 unsupportedFormatVersion(2)（不静默丢基线，也不因无基线而放行） | storage | ✅ |
| S-08 | 条目键契约（只有 5 个字段） | baselineEntryEncodingKeepsContractKeys | v2 夹具 → encode | 条目键集合恰为 {taskID, start, finish, progress, isMilestone}；不出现 title / durationDays / outlineNumber | storage | ✅ |
| S-09 | 撤销栈：createBaseline 进撤销、restore 可还原 | createBaselineIsUndoable | snapshot → createBaseline → restore | restore 后 baselines 空、任务仍在（ProjectState 必须携带 baselines） | commands | ✅ |
| S-10 | 负路径：未知基线 ID | baselineOperationsRejectUnknownIdentifiers | rename / delete / variance 各喂随机 UUID | 三处均抛 code == invalidArgument + reason == baselineNotFound（与 CLI/MCP 的 model_baseline_not_found 同码），基线集合与任务列表不变 | commands | ✅ |
| S-15 | 负路径：空基线名 | blankBaselineNameIsRejected | createBaseline(name: "   ") | code == invalidArgument + reason == baselineNameEmpty，不产生基线 | commands | ✅ |
| S-11 | 负路径：未打开项目 | baselineOperationsRequireOpenProject | 全新 KairoSession（无项目） | 五个入口全抛 SessionError，不静默返回空数组 | commands | ✅ |
| S-12 | 打开 v1 后首次保存才升版 | openingV1ThenSavingUpgradesToV2 / openingV2FileNeedsNoUpgrade | 临时 .kairo | 打开 v1：needsFormatUpgrade == true 且磁盘字节不变；保存后 formatVersion == 2、无 baselines 键、needsFormatUpgrade == false；打开 v2：needsFormatUpgrade == false、基线可读 | commands | ✅ 两例 |
| S-13 | 纯函数确定性 | varianceIsPureAndDeterministic | 同参数连算两次 | 两次报告 == （无墙钟、无外部状态） | core | ✅ |
| S-14 | 空输入边界 | snapshotWithoutSchedulesHasNoEntries | 任务无排期条目 | entries 为空数组、不崩、createdAt 照写 | core | ✅ |

### S-06 迁移矩阵（§7.4 / §7.6）

| 文件 \ 客户端 | 用例 | 断言 |
|---|---|---|
| v1 无 baselines → 新客户端 | v1FileOpensWithEmptyBaselinesAndNeedsUpgrade、openingV1ThenSavingUpgradesToV2 | sourceFormatVersion == 1、baselines == []、needsFormatUpgrade == true、打开不落盘；保存后 formatVersion == 2 且无 baselines 键 |
| v2 无基线 → 新客户端 | savingProjectWithoutBaselinesOmitsBaselinesKey | 直读成功、baselines == []；再编码仍省略键 |
| v2 有基线（2 条 + 1 孤儿）→ 新客户端 | v2BaselinesSurviveRoundTrip | 读 → 写 → 读，id/name/createdAt/anchor/entries 逐字段相等；anchor 缺省回落 nil |
| v1 缺 resources + baselines | v1MissingResourcesAndBaselinesFallBackToDefaults | 不报错，两者回落默认值 |
| v1 根节点带未知键 | v2MigrationOnlyBumpsVersionAndKeepsUnknownRootKeys | 迁移后未知键仍在（断言落在迁移层；保存层不保未知键是既定非目标） |
| v3 → 新客户端 | futureFormatVersionIsRejectedWithoutTouchingDisk | unsupportedFormatVersion(3)、磁盘字节不变 |
| v2 → 旧客户端（≤ v0.12） | oldClientRejectsV2File | 有无基线都抛 unsupportedFormatVersion(2) |

---

## 3. 各层覆盖与归属（2026-10-25 收口状态）

本文件开头的 36 例只覆盖 core / storage / commands；下列三层由各 owner 落盘，与本文件同属一个门禁，已逐条核对关键断言后计入覆盖。

| 层 | 归属文件（例数） | 覆盖判据 | 已核的关键断言 |
|---|---|---|---|
| pres | Tests/KairoPresentationTests/BaselinePresentationTests.swift（19） | B-06、B-07、B-08、B-10 | baselineColumnsAreOptional + snapshotOmitsBaselineColumnsWithoutSelection（未选基线时四列不出现，选了才出现）；baselineColumnWidthsFollowDateAndNumberColumns；actualAndBaselineColumnsCoexistInCanonicalOrder（与 07 实际列共存且顺序稳定）；planVarianceIsPositive/NegativeWhen…（+3 / −1）；taskAddedAfterBaselineHasNoVariance（hasBaseline == false、偏差 nil）；inspectorSeparatesPlanAndActualVariance；deletedTaskShowsUpAsOrphanInPanel、panelSeparatesOrphansFromTasksWithoutEntry；viewStateHasNoBaselineByDefault |
| app | Tests/AppTests/BaselineWorkspaceTests.swift（17） | B-06、B-07、B-08、B-10 + §11 删除确认 | baselineColumnCopySaysPlanVariance（列头文案区分「计划偏差」）；missingEntryCellsRenderPlaceholder（单元格 —）；setBaselineIsViewStateOnly；undoKeepsSelectedBaseline；danglingBaselineSelectionIsNormalizedAfterUndo（删除选中基线 → 撤销 → 选择不悬挂）；switchingBaselineDoesNotTouchProjectFile（mtime 与文件字节均不变）；selectedBaselinePersistsAcrossLaunch；deleteBaselineRequiresConfirmation（§11 二次确认）；varianceIsCachedAcrossViewOnlyActions（缓存键 = 选中基线 × revision，视图动作 0 次重算） ；deletedTaskAppearsInBaselinePanel |
| cli + mcp | Tests/InterfaceTests/BaselineInterfaceTests.swift（12，owner 已声明不再新增） | B-06、B-12（对等性门禁） | baselineVarianceJSONMatchesEngine / baselineVarianceMCPMatchesEngine / baselineVarianceCLIAndMCPAgreeOnFilteredTask：期望值由 BaselineEngine.variance 现算，再与 CLI --json 和 MCP 逐字段比对（不是两边实现互比）；baselineVarianceJSONOmitsEmptyValuesAndKeepsSigns（无基线条目的键缺席、actualFinishVariance == −1、文本无「+-1」）；baselineTaskGetPrintsBaselineSection；MCP 稳定码 model_baseline_not_found / model_baseline_name_empty |
| storage（体积 / 性能闸门） | Tests/KairoCoreTests/BaselinePerformanceTests.swift（2） | 09 §2 门禁、08 §6 NFR | 5,000 × 3 = 5.10 MB、5,000 × 5 = 7.31 MB（体积断言 ≤ 12 / 15 MB，变异验证过会红）；debug encode/decode/variance 0.13–0.52 s 区间，远低于 1 s NFR；30 s 时间阈值只拦复杂度回归 |

不在本版范围、故无对应用例（08 §10 / 09 §3）：甘特灰条（v0.14）、项目摘要偏差块（v0.14）、CSV 导出与基线 A vs B（v0.15）、挣值、保存时透传未知根键。

---

## 4. 待裁定与已知偏差

1. **【已裁定 (a)，2026-10-25】判据 7 的 hasBaseline == false 落在 core 报告层。**
   08 §9-7 要求「基线后新增：hasBaseline == false」，08 §8 的 TaskVariance 也带 hasBaseline 字段；但 §8 对 report.tasks 的注释写「仅含有基线条目的任务」。
   当前实现按后者：无基线条目任务不进 report.tasks，于是 hasBaseline 在报告里恒为 true（字段无假值），判据 7 第一条在 core 层不可验证。
   两条出路，选 (a)：
   - **(a) 已采用**：report.tasks 覆盖全部现存任务：无基线条目任务给 hasBaseline == false、baselineStart/Finish 与 plan 偏差全 nil，仍计入 tasksWithoutBaseline、不进项目结束偏差。判据 7 字面达成，TaskVariance.hasBaseline 有假值可断。
   - (b) 不采用：把 hasBaseline 断言下移 pres 并删掉 core 字段——会让 core 报告无法自证「哪些任务没基线」，pres 要自己去对 entries 做集合差。
   对应用例：taskAddedAfterBaselineIsFlaggedWithoutVariance、addedAndDeletedTasksStayVisibleFromCommands（各 1 条断言）。
2. **【已定】未知基线 ID / 空基线名的错误码**：实现为 invalidArgument + reason baselineNotFound / baselineNameEmpty，08 未规定。但 CLI/MCP 已把它们做成对外稳定码（model_baseline_not_found / model_baseline_name_empty），所以 commands 层用例也钉住同一粗码 + 细码（原先是只断「抛 SessionError」）。改码会三层同时红——这是刻意的，避免只有 CLI 红、core 静默。
3. **【已定】默认名日期时区**：BaselineEngine.defaultName 用当前时区公历渲染 yyyy-MM-dd。用例按同一口径（本地日历）取期望值，不写死 UTC 字符串。
4. **【口径提示】projectFinishVariance 的集合口径**：只统计「条目在且任务仍在」的任务（孤儿与基线后新增都不参与），用例以 B-07 / B-08 的 == 1 显式锁住。
5. **【口径记录】同一错误在两个出口的包装不同，断言别写串。**
   MCP：工具层抛 ToolError，粗码 invalid_argument + 细码 model_baseline_not_found（Sources/KairoMCP/Tools.swift:447），文案「基线不存在：<uuid>」。
   CLI：走 UsageError（Sources/KairoCLI/CLIRouter.swift:781/786/787），进程退出码 2（同文件 48/52）。标识解析统一走 resolveBaseline：接受**完整 UUID 或 ≥4 位的唯一前缀**，过短/无匹配/歧义分别为 :781/:786/:787 三条 UsageError；**delete 与 variance --baseline 两处都吃前缀**（调用点 :649 / :670），list/create 不需要标识。
   **输出里的 baselineID 一律是完整 UUID**（baseline list/create 均用 id.uuidString；shortID 只用于任务与项目），文本断言不要按短码匹配——输入可以短，输出永远全长，这条容易写反。
   两层 reason 一致、包装与退出码路径不同；commands 层（BaselineAcceptanceTests）钉的是 SessionError 的同名细码，三处同源。
6. **【已知边界】「删除选中基线 → 撤销」这个具体序列由读取侧归一化覆盖，不是写入侧清理。**
   已落盘断言：app danglingBaselineSelectionIsNormalizedAfterUndo（删除选中基线 → 撤销 → 选择不悬挂）、pres danglingSelectionNormalizesOnRead（找不到即 nil，且**不改写** viewState.selectedBaselineID）、pres danglingSelectionSnapshotMatchesNoSelection（悬挂选择下的快照等价「未选基线」）。因此「viewState 里残留一个已不存在的 ID」是合法中间态而非脏数据；若将来改为写入侧清理，这 3 例需同步改。
   另纠正一处编号误标：该行为一度被写作 D-030，但 D-030 是 RecentProjectsTests.launchOpensTheMostRecentProject 的并行偶发超时（回执式修复，与本版基线无关）。本文档已不再使用该编号，避免缺陷表与用例名互相污染。

---

## 5. 自验记录

- 用例条数：37（core 14 / storage 9 / commands 14）。
- 首轮（实现已并行落地）：31 通过 / 5 失败。其中 3 条为**测试自身缺陷**（默认名日期按 UTC 取期望值、排期锚点与条目用 UTC 零点对本地零点比较），已按本地日历改期望值并补 now: 注入后修复——归因为测试代码缺陷，未改动 Sources。
- 次轮：34 通过 / 2 失败，失败项是同一条契约冲突（判据 7 的 hasBaseline，§4-1），按判据字面保留红灯，未弱化断言。
- 本层终态：37 通过 / 0 失败。
- 收口全量门禁（2026-10-25 15:37–15:40 由 tester 连跑四次，期间 owner 陆续增补用例）：**1073 → 1076 → 1077 tests / 98 suites 全绿**，最终态 1077 为准。数差可对账：1073（lead 测）+ 3 例悬挂选择（pres）+ 1 例空名拒绝（本文件）= 1077。四次体积字节级一致（5,000 × 3 = 5.10 MB、5,000 × 5 = 7.31 MB）；耗时随负载在 encode 0.108–0.515 s、decode 0.150–0.262 s、variance 0.194–0.284 s 区间，均远低于 30 s 阈值与 1 s NFR。
- D-030 独立复核（与本版基线无关，因 lead 要求一并判定）：用例已改为完成回执（RecentProjectsTests.swift:143 awaitPendingOpenForTesting，源码内无 Date() 轮询、无 Task.sleep）；单跑连续 3 次通过（0.018–0.021 s，旧实现最长等到 3 s）；全量并行连续 4 次全绿。核销成立。
- 中间态未计入结论：pres/cli 并行落地期间出现过三类红（Presenter.swift 边编边存、Apps/macos 两处 switch 未穷尽、CLIRouter 与 MCP Tools 的 helper 未落），每次失败点不同，均由对应的 owner 在途修复，未作为缺陷上报。
- 说明：本流程要求「先红后绿」，但实现（Baseline.swift / BaselineEngine.swift / CalendarDayMath.swift / KairoFile v2 / KairoSession 基线接口）在我落盘用例的同时已由 dev-coder-core 完成，因此**未能取得编译期红灯**；红灯证据是行为级的（判据 7 的两条断言，行号 363 / 863），不是编译失败。
- 未做的验证（不虚报）：UI 像素级外观只由 app 测试的函数级断言与本地渲染用例间接覆盖，未做整屏截图比对；macOS 之外平台未跑（与既有 CI 口径一致）；基线数量不设上限，未测「极大基线数（如 50 条）」的体积曲线。

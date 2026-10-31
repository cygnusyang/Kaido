# final-summary.md — 计划视图大纲/甘特纵向错位修复

## FINAL STATUS

PASS — 缺陷已修复并独立验证通过。commit `fd3b248`（分支 `feat/plan-workspace-redesign`），缺陷已登记 `docs/defects.md` D-006 并核销。

## ROOT CAUSE

`OutlineTable.swift` 每行（28pt）后渲染占布局空间的 `Divider()`，左列实际行节距 ≈29pt；而 Timeline 的内容高、命中换算、行线/高亮/任务条全部按 28pt 节距（`DesignTokens.rowHeight = 28`）。偏移 = 行号 × 1pt，线性累积（约第 28 行错开一整行）；画布点击命中换算同样错位，导致选中高亮「指错行」。两侧数据源完全同源（同一 `snapshot.outline.rows`），非数据/排序/过滤问题。

## CHANGED_FILES

| 文件 | 改动 |
|---|---|
| `Apps/macos/Sources/Workspace/Outline/OutlineTable.swift` | 删除每行后占布局空间的 Divider，改为 OutlineRowView 28pt 行内底部 overlay 自绘 1pt 分隔线（视觉不变，左列总高 = 行数×28） |
| `Tests/AppTests/OutlineAlignmentTests.swift`（新增） | 离屏渲染 40 行量测总高，断言 == 40×28；旧代码上实测 1160 vs 期望 1120（先红），修复后转绿 |
| `docs/defects.md` | 登记 D-006 并核销（队长收尾时补） |

预存的 `Apps/macos/Sources/CommandRegistry.swift` 未提交改动未被带入提交，保持原样。

## VERIFICATION

- Vic 独立复跑：OutlineAlignmentTests 1/1、GUIRenderTests 8/8、AppTests 99/99、ZenoCoreTests 234/234、`swift build -c release`（warnings-as-errors）通过；gate-ui / gate-core 门禁通过。
- 回归证明：worktree 挂修复前代码（ac8e360）跑新测试实测 FAIL（measured 1160 vs expected 1120），红→绿闭环独立复现。
- 提交范围核查：fd3b248 仅含 OutlineTable.swift + OutlineAlignmentTests.swift。
- 注：本机 SwiftPM 跑测试需 `--disable-sandbox`（系统策略）。

## REPORTS

- 计划：`.agent-runs/2026-10-20/task-001/plan.md`
- 调查报告：`.agent-runs/2026-10-20/task-001/investigation-report.md`（Vera）
- 实现报告：`.agent-runs/2026-10-20/task-001/implementation-report.md`（Max）
- 验证报告：`.agent-runs/2026-10-20/task-001/verification-report.md`（Vic）

## KNOWN_ISSUES

- 无阻断项。遗留体验项（非本次缺陷）：画布点击只选中不滚动（`scrollTo` 仅键盘/查找路径），如需可另开任务。

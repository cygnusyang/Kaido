# plan.md — 计划视图：左侧任务列表与右侧甘特图不对应

- 日期：2026-10-20
- 任务目录：`.agent-runs/2026-10-20/task-001/`
- 团队：crew-plan-gantt-sync

## 现象

用户报告：Kairo「计划」tab（`WorkspaceMode.plan`）中，左边的任务列表（Outline）与右边的甘特图（Timeline）没有对应上。

具体表现待调查确认，可能方向：
1. 行序不一致：两侧排序/折叠展开状态不同步。
2. 行高或缩进不一致：任务条与列表行错位。
3. 数据集不一致：两侧过滤/可见行集合不同。
4. 滚动/选中不同步：点击列表行，甘特对应行未高亮或未滚动到可见区。

## 相关代码位置（初步勘察）

- 视图切换：`Apps/macos/Sources/Workspace/WorkspaceView.swift`（"计划" tag 在 :136）
- 左侧列表：`Apps/macos/Sources/Workspace/Outline/`
- 右侧甘特：`Apps/macos/Sources/Workspace/Timeline/`
- 布局计算：`Sources/KairoCore/Query/GanttLayout.swift`
- 状态：`Apps/macos/Sources/WorkspaceStore.swift`、`Sources/KairoCore/Query/`（snapshot.outline.rows）

## 计划

| 阶段 | 成员 | 产出 |
|---|---|---|
| Phase 1 调查 | Vera | investigation-report.md（定位不对应的根因，指出具体文件/行） |
| Phase 2 实现 | Max | 修复 + implementation-report.md |
| Phase 3 测试 | Tess | 回归测试用例 + test-report.md |
| Phase 4 验证 | Vic | 跑测试/构建，PASS/FAIL 结论 + 验证产物 |
| Phase 5 审查 | Ray（按需） | review-report.md |

## 约束

- 仓库当前有未提交改动：`Apps/macos/Sources/CommandRegistry.swift`（与本次 Bug 无关，修复时不得动它）
- 已知历史缺陷 D-002/D-003（1970 纪元排期）已核销，不要重开。
- 修复必须配测试证据；实现与验证分离。

# 验证报告 — 验证员 Vic

- 日期：2026-10-20
- 验证对象：Kaido「计划」tab 大纲/甘特纵向错位修复，commit `fd3b248`，分支 `feat/plan-workspace-redesign`
- 结论：**PASS**

## 1. 验证环境

- macOS arm64（arm64e-apple-macos14.0），Swift Testing Library Version 1743
- 仓库：/Users/cygnus/work/opc/04-开发项目/Kaido
- 所有 swift 命令按本机系统策略要求带 `--disable-sandbox`
- 全程只运行未修改任何代码；唯一临时操作为 git worktree（已清理，见 §2.4）

## 2. 执行记录

### 2.1 提交范围核查 ✅

- `git branch --show-current` → `feat/plan-workspace-redesign`；`git rev-parse HEAD` → `fd3b24806419538ceec6a640381dc4716655e53e`，与任务书一致。
- `git show --stat fd3b248` → 仅 2 个文件：
  - `Apps/macos/Sources/Workspace/Outline/OutlineTable.swift`（10 行变更）
  - `Tests/AppTests/OutlineAlignmentTests.swift`（新增 56 行）
- `git status` → `Apps/macos/Sources/CommandRegistry.swift` 的预存改动仍在工作区未暂存（modified, not staged），**未被带入提交**。✅

### 2.2 复跑测试（独立于 Max 的执行）✅

| 命令 | 结果 |
|---|---|
| `swift test --disable-sandbox --filter OutlineAlignmentTests` | `✔ Test outlineRowsListHeightMatchesTimelinePitch() passed` — 1/1 |
| `swift test --disable-sandbox --filter GUIRenderTests` | `Test run with 8 tests in 1 suite passed` — 8/8 |
| `swift test --disable-sandbox --filter KaidoCoreTests` | `Test run with 234 tests in 32 suites passed` — 234/234 |
| `swift test --disable-sandbox --filter AppTests`（额外全量回归） | `Test run with 99 tests in 6 suites passed` — 99/99 |
| `swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors` | `Build complete!`，exit 0，无警告 |

### 2.3 回归证明（新测试确实抓住原缺陷）✅

用 `git worktree add /tmp/kaido-prefix-verify ac8e360`（修复前提交）临时挂出旧代码，将 `OutlineAlignmentTests.swift` 复制进 worktree 后运行：

```
✘ Test outlineRowsListHeightMatchesTimelinePitch() recorded an issue at
  OutlineAlignmentTests.swift:54:9: Expectation failed:
  (measured → 1160.0) == (expected → 1120.0)
✘ Test run with 1 test in 1 suite failed
```

在旧代码上测试**FAIL**，实测 1160pt vs 期望 1120pt，恰为 40 行 × 1pt Divider 的占位开销，与根因描述精确吻合；修复后同测试转绿（1/1 passed）。红→绿闭环独立复现成立。

清理：`git worktree remove --force /tmp/kaido-prefix-verify` 已执行，`git worktree list` 确认仅剩主工作区，工作区状态与验证前一致（仅 `CommandRegistry.swift` 预存改动 + `.agent-runs/`、`.omc/` 未跟踪目录）。

### 2.4 根因闭环（代码审查）✅

读修复后 `OutlineTable.swift`：

1. `OutlineRowsList.body`（L16–33）：`ForEach` 内每行 `.frame(height: DesignTokens.rowHeight)` 后**无任何占布局空间的 Divider**，原 `Divider().opacity(0.35)` 已删除，仅余注释。文件中仅存的 `Divider()` 全部位于 `contextMenu`（L412/416/420，菜单分隔符，不参与行布局）。
2. 分隔线改由 `OutlineRowView` 的 `.overlay(alignment: .bottom)` 内 1pt `Rectangle`（L125–130）自绘——overlay 不占布局空间，行总高严格 = 行数 × rowHeight。
3. `DesignTokens.rowHeight = 28`（`Apps/macos/Sources/Theme/DesignTokens.swift:11`），与测试断言 `rows.count × DesignTokens.rowHeight` 同源。
4. `TimelineView.swift:100` 的 contentHeight 定义即 `CGFloat(rows.count) * DesignTokens.rowHeight`，测试断言与之共定义式，两侧节距一致，错位消除在布局层成立。

### 2.5 边角检查（折叠/展开）✅（代码层面）

折叠/展开只影响 Presenter 输出的行集合（树扁平化后哪些行可见），每行渲染路径统一为 `OutlineRowView` + `.frame(height: 28)`，分隔线 overlay 挂在行视图自身底部，因此无论行 depth/折叠状态如何，分隔线始终位于该行 28pt 区间内（行内底部 1pt），不会越界或占额外节距。拖拽插入线（2pt accent）绘制在分隔线之后，覆盖关系与改前视觉层次一致。

## 3. 逐条判定（success_criteria）

| 标准 | 判定 | 证据 |
|---|---|---|
| 报告含提交范围核查结果 | ✅ | §2.1：commit 仅含 2 个约定文件；CommandRegistry.swift 预存改动未被带入 |
| 报告含复跑测试的命令与输出摘要 | ✅ | §2.2：5 条命令全绿（新测试 1/1、GUIRender 8/8、KaidoCore 234/234、AppTests 99/99、release build 通过） |
| 回归证明（新测试在旧代码上 FAIL） | ✅ | §2.3：worktree @ ac8e360 实测 FAIL（1160 vs 1120），与 Max 报告数字独立吻合；worktree 已清理 |
| 根因闭环（无占布局 Divider、断言与 rowHeight=28 一致） | ✅ | §2.4 |
| 边角检查（折叠/展开下分隔线仍在 28pt 行内） | ✅ | §2.5 |
| 最终结论三选一、不模糊 | ✅ | **PASS** |

## 4. 证据索引

- §2.1 提交范围：`git show --stat fd3b248` / `git status` 输出（本报告引用）
- §2.2 测试输出：各 swift test/build 命令 stdout 摘要（本报告引用，均为本会话独立复跑）
- §2.3 红测输出：/tmp/kaido-prefix-verify 内运行结果（worktree 已删，输出留存于本报告）

## 5. 最终结论

**PASS**

修复（commit fd3b248）经独立复跑验证：提交范围合规、全部测试套件绿、新对齐回归测试在修复前代码上可稳定复现缺陷（红）且修复后转绿、根因在代码层闭环。可以交付。

（备注，不影响结论：末行底缘分隔线的视觉取舍与 Retina 下 1pt overlay 的抗锯齿观感属视觉验收项，已在 Max 实现报告中如实标注，建议真机过一眼。）

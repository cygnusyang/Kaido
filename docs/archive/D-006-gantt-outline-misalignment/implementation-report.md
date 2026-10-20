# 实现报告 — 实现工程师 Max

- 日期：2026-10-20
- 任务书：`.agent-runs/2026-10-20/task-001/brief-implementer.md`
- 分支：`feat/plan-workspace-redesign`（原工作区在 `main`，两分支同指向 ac8e360，已切至任务书指定分支提交）
- Commit：`fd3b248`

## 1. 任务目标

消除「计划」tab 左侧 Outline 与右侧甘特图纵向错位：去掉左列每行 Divider 占用的额外布局高度，使左列行节距回到 28pt，并补对齐回归测试。

## 2. 变更清单

### `Apps/macos/Sources/Workspace/Outline/OutlineTable.swift`（方案 A）

- `OutlineRowsList.body`：删除 `ForEach` 内每行后的 `Divider().opacity(0.35)`（根因，占布局空间 ≈1pt/行），保留注释说明分隔线改由行视图自绘、左列总高必须等于 行数 × rowHeight。
- `OutlineRowView`：在既有的 `.overlay(alignment: .bottom)`（拖拽插入线）内，先叠一条 `Rectangle().fill(DesignTokens.separator).frame(height: 1).opacity(0.35)` 作为行分隔线，再叠插入线。分隔线不占布局空间；插入线（2pt accent）绘制在后、覆盖分隔线，视觉优先级与改前一致。
- 分隔线颜色从 `Divider` 默认色改为 `DesignTokens.separator`（token 化，与画布行线同源），透明度保持 0.35。

### `Tests/AppTests/OutlineAlignmentTests.swift`（新增，方案 C）

- 新套件「大纲纵向对齐」：构造 40 行 `PlanRow`（N≥30），用离屏 `NSHostingView`（`sizingOptions = .intrinsicContentSize` + `layoutSubtreeIfNeeded`）实测 `OutlineRowsList` 内容高度，断言 == `rows.count × DesignTokens.rowHeight`（即 `TimelineBody.contentHeight` 的定义式；该属性为 private，无法直接引用，故按同一定义式断言）。
- 红绿验证：在未修复代码上先跑，实测 1160 vs 期望 1120（= 40 × 1pt Divider），准确复现根因；修复后转绿。

## 3. 关键决策

| 决策 | 理由 | 被否方案 |
|---|---|---|
| 分隔线并入 `OutlineRowView` 既有底部 overlay | 保证拖拽插入线绘制在分隔线之上（保持原视觉层次）；改动集中一处 | 在 `OutlineRowsList` 对 `.frame(height:)` 外层再挂 overlay：分隔线会盖在插入线上，视觉层次变差 |
| 测试用 `intrinsicContentSize` 而非 `sizeThatFits(巨大高度)` | VStack/LazyVStack 对大高度提案是贪婪的，会直接返回提案高度，量不到内容高；intrinsic 按不指定高度提案求值，返回真实内容高 | `ImageRenderer` + `onAppear`/PreferenceKey 采高：离屏同步渲染不保证回调执行，不可靠 |
| contentHeight 第三项断言用定义式 | `TimelineBody.contentHeight` 为 private；`TimelineView.swift`、`Presenter.swift` 均在禁改范围，不改可见性 | — |

## 4. 自查结果（success_criteria）

| 标准 | 结果 |
|---|---|
| `OutlineTable.swift` 不再有占布局空间的行间 Divider；左列布局高度 = rows × 28pt | ✅ PASS（`Divider()` 已删，测试实测 40 行总高 == 1120 == 40 × 28） |
| 新增对齐回归测试并通过；受影响既有测试全绿 | ✅ PASS（新测试 + GUIRenderTests 8/8 全绿，见 §5） |
| 提交内不含 scope 外文件；报告含改动说明、测试证据、commit hash | ✅ PASS（`git show --stat fd3b248` 仅 2 个文件；预存的 `CommandRegistry.swift` 改动原样保留在未提交区） |

## 5. 验证证据

环境说明：本机 SwiftPM manifest 编译的 `sandbox-exec` 被系统策略阻止，所有 swift 命令需 `--disable-sandbox`（仅影响包管理沙箱，不影响测试本身）。

1. **新测试（修复前，红）**：`swift test --disable-sandbox --filter OutlineAlignmentTests`
   `Expectation failed: (measured → 1160.0) == (expected → 1120.0)` —— 每行恰好多 1pt，复现根因。
2. **新测试（修复后，绿）**：`✔ Test outlineRowsListHeightMatchesTimelinePitch() passed`
3. **既有 GUI 渲染测试**：`swift test --disable-sandbox --filter GUIRenderTests` → `Test run with 8 tests in 1 suite passed`
4. **构建**：`swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors`（即 `tools/build.sh` 核心步骤）→ `Build complete! (24.86s)`，无警告
5. **门禁**：`tools/gate-ui.sh` 通过（7 个视图文件）；`tools/gate-core.sh` 通过（34 个文件）
6. **提交范围**：`git show --stat fd3b248` → 仅 `OutlineTable.swift` + `OutlineAlignmentTests.swift`（2 files changed, 64 insertions, 2 deletions）

## 6. 已知风险（给 Tess 的交接提示）

- **末行分隔线**：改前 Divider 挂在最后一行之后（列表底缘），改后为每行行内底部 overlay，末行也有分隔线，视觉等价；若设计验收认为列表底缘应无线，需另议（属视觉项，非本缺陷）。
- **测试对 `intrinsicContentSize` 的依赖**：依赖 LazyVStack 在不指定高度提案下物化全部行并返回内容高（已实测 40 行成立）。若未来把 `OutlineRowsList` 包进固定高度容器或改用 `ScrollView` 内嵌，量测路径可能需调整。
- **未做真机像素级验证**：对齐在布局层已严格相等（28pt 节距两侧同源），但 Retina 下 1pt overlay 的抗锯齿渲染与原 Divider 的视觉差异建议真机过一眼。
- **画布滚动末端留白**：改前画布 contentHeight < 左列实际总高导致滚到底留白，属同一根因的附带症状，本次修复应一并消除，可顺带人工验收。
- **命中换算/滚动逻辑未动**：`TimelineView` 命中、缩放、滚动路径零改动（任务书要求），28pt 节距恢复后自然对齐；若仍有命中偏移报告，应另开缺陷调查。

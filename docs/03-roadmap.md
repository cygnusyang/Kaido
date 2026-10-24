# Kairo 敏捷路线图（Roadmap）

> 版本 0.1 · 2026-10-17 · 状态：已接受（Sprint 0 产出，待评审）
> 上游依据：[00-vision.md](00-vision.md)（G3 门槛）、[01-prd.md](01-prd.md)（US 编号与状态表）、[02-architecture.md](02-architecture.md)（选型与架构）
> 节奏：Sprint 0 为本周期（文档 + 选型定稿）；Sprint 1 起每个 Sprint 两周，各有明确 Goal 与 Demo 判据。

## 1. Sprint 划分

### Sprint 0 — 文档与选型定稿（2026-10-19 ~ 2026-10-30）

- **Goal**：需求文档三件套定稿、技术选型定稿、KairoCore 重构骨架落地、现有测试迁移通过。
- **包含 US**：[US-E1-02](01-prd.md)、[US-E4-01](01-prd.md)、[US-E4-02](01-prd.md)（已完成项的验证收口）；[US-E5-05](01-prd.md)（接口契约草案评审）；ADR-002/004（选型与核心边界）落地。
- **交付物**：
  - `docs/01-prd.md`、`docs/02-architecture.md`、`docs/03-roadmap.md` 定稿；
  - `Sources/Kairo/` 重构为 `Sources/KairoCore/`（核心 target 与 macOS 应用 target 分离，见 [02-architecture.md §5](02-architecture.md)）；
  - 现有 17 项测试迁入 `Tests/KairoCoreTests/` 并通过；新增编译门禁：KairoCore 不得 import AppKit/SwiftUI。
- **验收 Demo**：评审通过；`swift test` 在重构后 17 项全绿；对 KairoCore 编译门禁脚本运行一次，证明无 UI 依赖。

### Sprint 1 — 核心模型 + 持久化 + 接口骨架（2026-11-02 ~ 2026-11-13）

- **Goal**：跑通程序化路径「建项目 → 批量建 WBS 任务树 → 保存为 .kairo」，MCP 与 CLI 提供对等的任务 CRUD 与 WBS 导入。
- **包含 US**：[US-E1-01](01-prd.md)、[US-E1-03](01-prd.md)、[US-E1-04](01-prd.md)、[US-E6-01](01-prd.md)、[US-E5-01](01-prd.md)（子集：project/task/wbs/save 工具）、[US-E5-02](01-prd.md)（对等子集）、[US-E5-05](01-prd.md)（契约定稿与首个对等测试）。
- **交付物**：
  - 核心模型重构：`TaskDependency`（类型 + 前导时间）、`kind`（任务/群组/里程碑）、`parentID` 树、投入/持续时间字段；
  - `.kairo` 单文件读写（JSON，本地优先）；
  - MCP 服务骨架 + CLI 对等命令（task add/list/get/update/delete、wbs import、project open/create/save）；
  - macOS 应用升级为可打开/保存 `.kairo`，层级树展示。
- **验收 Demo**：Claude Code 通过 MCP 一次导入 20 任务的 WBS 树并存为 `.kairo`；同一序列用 CLI 复现；macOS 打开该文件看到完整任务树。

### Sprint 2 — 调度引擎 + 状态回写闭环（2026-11-16 ~ 2026-11-27）

- **Goal**：跑通全闭环「排期 → AI 逐任务开发 → 状态回写」，排期计算（相关性传播 + 时限 + 基础违例）与状态回写就绪。
- **包含 US**：[US-E2-01](01-prd.md)、[US-E2-02](01-prd.md)、[US-E2-05](01-prd.md)、[US-E1-05](01-prd.md)、[US-E3-01](01-prd.md)、[US-E3-02](01-prd.md)；[US-E5-01](01-prd.md)（补排期/状态/违例工具）、[US-E5-02](01-prd.md)（补对等命令）；[US-E2-03](01-prd.md)（实际提前完成）。
- **交付物**：
  - 调度引擎（纯函数）：FS/FF/SS/SF + 前导时间传播、项目方向、ASAP/ALAP、四类时限校验、基础违例检测（环、时限冲突、超项目范围）；
  - 状态回写：单任务与批量更新、群组完成度投入加权聚合、完成时间记录；
  - MCP/CLI 补 `schedule_*`、`status_*`、`violations` 工具；
  - 基础 `Resource` 与分配（支撑投入↔持续时间换算）。
- **验收 Demo**：Claude Code 读一份需求文档 → 建 WBS → 计算排期（含一条时限冲突违例被报告）→ 逐任务开发并回写进度 → 全程无人点界面，群组完成度正确聚合。

### Sprint 3 — 人工审阅增强 + 插件（2026-11-30 ~ 2026-12-11）

- **Goal**：人能在 macOS 应用查看甘特、层次树、违例并干预；Claude Code 插件接入；重要路径可查询。
- **包含 US**：[US-E4-03](01-prd.md)、[US-E4-04](01-prd.md)、[US-E4-05](01-prd.md)、[US-E4-07](01-prd.md)、[US-E5-03](01-prd.md)、[US-E5-04](01-prd.md)（US-E2-03 已于 Sprint 2 提前完成）。
- **交付物**：
  - 甘特视图基础（任务条/日期标头/缩放/非工作时段着色）、层次树大纲交互（缩进/群组/展开收合/键盘导航）、命令面板（⌘K）、检查器与违例面板；
  - Claude Code 插件（斜杠命令 + hooks + `.mcp.json`）、`kairo://` 深链。
- **验收 Demo**：人在 macOS 中看到甘特与违例面板，修正一条时限后重新排期；Claude Code 内用 `/kairo plan` 与 `/kairo done` 完成一次回写；`kairo://task/<id>` 直达任务。

### Sprint 4 — 完整化与稳健化（2026-12-14 ~ 2026-12-25）

- **Goal**：可保存过滤器、CSV 导入导出、字段级版本历史、JSON Schema、项目摘要就绪，性能达标 NFR-1/2/3。
- **包含 US**：[US-E4-02](01-prd.md)（可保存过滤器升级）、[US-E4-06](01-prd.md)、[US-E6-03](01-prd.md)、[US-E3-03](01-prd.md)、[US-E3-04](01-prd.md)、[US-E5-06](01-prd.md)。
- **交付物**：
  - 可保存的结构化过滤器（自然语言筛选升级，保存/复用）；
  - CSV 导入导出 + 保真报告（含 AI 栏名映射建议）；
  - 字段级版本历史（回看/撤销）、重新安排未完成任务、项目摘要面板；
  - `.kairo` 对应 JSON Schema 导出；
  - 性能验收：1,000 任务列表交互 ≤ 100 ms、排期计算 ≤ 1 s、5,000 任务文件读写 ≤ 1 s。
- **验收 Demo**：导入一份 500 行 CSV 并查看保真报告；保存过滤器后重启复用；撤销一次误改；千级任务性能基准跑通（指标落盘）。

### Sprint 5 — Linux 编译 + G3 验收 + 发布准备（2026-12-28 ~ 2027-01-08）

- **Goal**：核心在 Linux 编译并通过同一套测试，G3 四判据逐条验收通过，发布准备就绪。
- **包含 US**：[US-E2-04](01-prd.md)（工作时数日历）、[US-E2-06](01-prd.md)（基线）、[US-E6-02](01-prd.md)（自动保存）、[US-E3-05](01-prd.md)（冲突差异说明）、[US-E6-04](01-prd.md)/[US-E6-05](01-prd.md)/[US-E6-06](01-prd.md)（收尾，可选）、[US-E5-05](01-prd.md)（接口对等验收）。
- **交付物**：
  - 工作时数日历（项目级/资源级）与基线快照/差异；
  - Linux CI：KairoCore 在 Linux 编译 + 全量单测通过；
  - G3 四判据验收记录（vision §7）：MCP 全闭环、CLI 对等、macOS 完整查看编辑、Linux 编译；
  - 打包与发布准备（.app 打包、`kairo` / `kairo-mcp` 分发）。
- **验收 Demo**：G3 验收表逐条勾选并留存证据；在 Linux 容器执行 `swift test` 全绿；macOS 应用完成一次端到端闭环演示。

## 2. 风险登记簿

| 编号 | 风险 | 影响 | 概率 | 缓解措施 |
|---|---|---|---|---|
| R1 | Swift 跨平台风险：Linux 编译或 Foundation 差异导致 G3 判据 4 不达标 | 高（阻塞 G3） | 中 | KairoCore 只依赖 Foundation 子集（ADR-004）；Sprint 2 起在 CI 加 Linux 构建门禁，尽早暴露；核心逻辑保持纯函数 |
| R2 | MCP 接口频繁演进：契约未定稿前工具名/参数反复变化 | 中 | 高 | 接口单一事实源（ADR-005）；Sprint 1 工具清单定稿后冻结；对等性测试作门禁（US-E5-05） |
| R3 | 范围蔓延：175 条功能规格的诱惑导致 Sprint 失焦 | 高 | 高 | MVP 边界裁定（[01-prd.md §5](01-prd.md)）；Sprint 只做 Goal 内 US；P3 一律不入 Sprint；计划会做范围冻结 |
| R4 | Swift MCP SDK 不成熟：SDK 缺功能或维护停滞 | 中 | 中 | Sprint 1 复核官方/社区 SDK；工具面 ≤ 20 个，必要时自实现最小 JSON-RPC 传输 |
| R5 | 调度引擎复杂度：环检测/违例/资源逻辑正确性风险 | 中 | 中 | 调度为纯函数 + TDD（ADR-007）；分步落地：先相关性传播，后违例，资源分级本期不做 |
| R6 | 模型重构风险：`Sources/Kairo` → `KairoCore`、`dependencies` 迁移破坏现状 | 中 | 中 | 现有 17 项测试作回归门禁；旧相关性按 FS/无前导时间迁移（US-E2-01）；独立提交可回滚 |
| R7 | 性能不达标：千级任务交互/排期计算超阈值 | 中 | 低 | Sprint 4 性能验收前置；排期重算增量设计；NFR 阈值在 Sprint 4 复核 |

## 3. 度量

每个 Sprint 在回顾会跟踪以下流动度量，Sprint 0 建立基线：

| 度量 | 定义 | 目标 |
|---|---|---|
| 完成 Story 数 | 本 Sprint 由「已接受」推进到「完成」的 US 数（见 [01-prd.md §6](01-prd.md) 状态表） | 5–8 / Sprint |
| 累积流图（CFD） | 各状态（提议/已接受/进行中/完成）Story 数随 Sprint 变化曲线 | 无积压膨胀：进行中 ≤ 3 |
| 闭环耗时 | 从「AI 发起建 WBS」到「首个任务开发完成并回写状态」的端到端时长（Sprint 2 起跟踪） | ≤ 10 分钟 |
| 回归测试数 | `KairoCoreTests` 通过用例数（含 Linux CI） | 17 → 200+（Sprint 5） |
| 接口对等性 | MCP/CLI 对等性契约测试通过率 | 恒为 100%（门禁） |
| 缺陷逃逸率 | 验收 Demo 中发现的问题 / 本 Sprint 总缺陷 | ≤ 20% |

## 4. 里程碑与退出条件

- **MVP 出口**：Sprint 5 结束，G3 四判据（[vision §7](00-vision.md)）全部通过并留存验收证据。
- **停止条件**：任一 Sprint 出现 R1 无法缓解（Linux 编译阻塞）或连续两个 Sprint 闭环耗时目标未达成时，触发 lead 决策：缩小 MVP 或调整选型（重新评估 ADR-002 的 Rust 迁移）。

## 5. 状态更新（2026-10-20 · 实际进度已越过 v0.1 规划）

> 本节为当前事实源；上方 v0.1 的 Sprint 划分与日期为早期规划，保留作历史。

### 实际完成

| 版本 | 日期 | 内容 |
|---|---|---|
| v0.1.0 | 2026-10-18 | 计划工作台重设计、甘特布局 v2、核心模型/持久化、MCP/CLI 对等、撤销/重做（覆盖原 Sprint 1–3 与 Sprint 4–5 大部分范围，MVP 出口达成） |
| v0.2.0 | 2026-10-20 | `.kairo` 格式版本契约、另存为、任务负责人、大纲编号前置、甘特日宽自定义（Sprint 6，dev-team 全流程；缺陷 D-001…D-011/D-018 闭环，IEEE 829 登记） |
| v0.3.0 / v0.3.1 | 2026-10-20 | OTA 应用内更新（通用模块 KairoUpdater，移植 COFFER OTA；Ed25519 签名清单 + 四级校验 + 白名单；自动检查 4h；见 docs/features/05-ota-updates.md） |
| v0.4.0 | 2026-10-21 | 甘特图直接编辑（F-14-09：拖条改期、拖端点改持续、拖拽建依赖/删线；见 docs/archive/Sprint7-gantt-direct-edit/design.md） |
| v0.5.0 | 2026-10-21 | 任务起止日期可自定义（F-14-10：检查器「开始/结束」+ 月历弹层）+ **D-021 修复**（排期引擎消费 `startDate`，画布拖条改期真正生效）+ 日历日算术（DST 结束落点修复）；见 docs/archive/Sprint8-task-dates/design.md |
| v0.6.0 | 2026-10-22 | 甘特图横向平移（F-14-18：触摸板/滚轮横向滚动 + 画布空白拖拽；亚日余量累积、整天归一；见 docs/archive/Sprint9-gantt-horizontal-pan/design.md） |
| v0.7.0 | 2026-10-22 | 大纲「开始/结束」日期列可编辑（F-14-19：点击弹月历、复用 CalendarPopover；群组/里程碑/无排期按策略禁用；写回与撤销与检查器同源；见 docs/archive/Sprint10-outline-date-cells/design.md） |
| v0.8.0 | 2026-10-22 | 大纲列宽可调 + 列显隐可配置（F-14-20：表头手柄拖拽调宽、双击复位；视图菜单/右键菜单显隐列，序号与任务说明固定；偏好持久化、不进撤销栈；见 docs/archive/Sprint11-outline-columns/design.md） |
| v0.8.1 | 2026-10-23 | 发版 CI 时区缺陷修复（D-025：S8 日期渲染用例在 UTC runner 整体错位一天）+ AI 协作接入指南（Plugins/README.md：Claude Code / CodeBuddy / Codex 接法与 WBS 拆解规程） |
| v0.8.2 | 2026-10-23 | 发版工作流加固（D-026：artifacts 推送重试与 postBuffer、latest/ 每次重建不残留历史产物） |
| v0.8.3 | 2026-10-23 | 一键发版工具链（`tools/release.sh` 串起前置校验→版本号→测试→打包→tag→推送；`package.sh` 本地与 CI 同源产出 dmg/zip；`release_notes.sh` 让 Release 说明与 CHANGELOG 单一来源） |
| v0.8.4 | 2026-10-24 | 甘特图双指横向平移回归修复（D-027：坐标同源 + 监听单例 + 取消窗口身份判定 + 「编辑中」改按光标落点判定，修复「双指横滑画布不动」；F-14-18 需求收口） |

### Sprint 7（计划）

- **Goal**：技术债清偿 + 甘特图直接编辑主线。
- **技术债**（docs/defects.md 顺延项）：D-012（偏好载入口径对称）、D-013（clearCustomDayWidth 拼写统一）、D-014（日宽提交复用 lastSchedule）、D-016（偏好逐字段容错解码）、D-017（fit 窗口天数上限，需 lead 批准，破坏 A7 门禁须重设计）。
- **主线**：F-14-09 甘特图直接编辑（拖条改期、拖端点改持续、拖拽建依赖/删线）——✅ 已完成（2026-10-21，558/558 全绿，设计稿 docs/archive/Sprint7-gantt-direct-edit/design.md）；技术实现为 `GanttHitTesting` 纯函数命中 + `CanvasDragSession` 节流状态机，命令层零改动。
- **验收 Demo**：甘特画布直接拖拽完成改期/建依赖全流程；D 系列顺延项全部核销或更新目标版本。

### Sprint 8（已交付 v0.5.0 · 2026-10-21）

- **Goal**：任务起止日期可自定义（检查器日历）+ 修复 v0.4.0 遗留的「startDate 不驱动排期」（D-021）。
- **交付**：F-14-10 检查器「开始/结束」两行 + 月历弹层（键盘/无障碍/深浅色）；排期引擎把显式 startDate 作为开始下界（ASAP/ALAP 统一收敛）；排期算术改为 Calendar 整日（跨夏令时结束落点不再少一天）。
- **顺延 v0.5.1**：D-022（晚开始触发误导性违例文案）、D-023（违例引擎跨 DST 秒算术）、D-024（无下界哨兵口径）。
- **候选池**：US-E2-04 工作时数日历、US-E3-03 重新安排未完成任务、US-E3-04 字段级版本历史、US-E4-06 项目摘要面板、US-E6-02 自动保存与文件监控、US-E6-03 CSV 导入导出。

### Sprint 9（已交付 v0.6.0 · 2026-10-22）

- **Goal**：甘特图横向平移（F-14-18）——任务/依赖链超出视口时无法左右移动，macOS 触摸板横向滚动无效。
- **交付**：触摸板双指横向滚动、Shift+纵向滚轮、画布空白拖拽三条平移入口；亚日余量累积（整天归一契约下不丢位移）、平移退出「适合项目」、Escape 取消；`HorizontalPanAccumulator` 纯函数 + `PanDragSession`/`HorizontalPanContext` 状态机均可单测，命令层零改动。
- **设计稿**：docs/archive/Sprint9-gantt-horizontal-pan/design.md。
- **未做（有意排除）**：横向滚动条、子日粒度窗口（会破坏 A7 黄金基线）。
- **候选池**：沿用 Sprint 8 候选池；D-022 / D-023 / D-024 仍计划 v0.6.1 处置。

### Sprint 10（已交付 v0.7.0 · 2026-10-22）

- **Goal**：大纲「开始 / 结束」两列可编辑（用户需求：左侧日期要能改，并用日历组件快速选日）。
- **交付**：`OutlineDateCell`（点击弹 `CalendarPopover`，复用 F-14-10 组件不改造）；`OutlineDateEditing` 纯函数策略（启用/原因/最小日）；写回复用 `setTaskStart` / `setTaskFinish`，撤销键与检查器同源；群组/里程碑/无排期禁用并给出原因。
- **测试**：策略 17 例（含跨 DST、闰日、群组优先于里程碑）+ App 层 2 例同源断言；全量 701/701。
- **设计稿**：docs/archive/Sprint10-outline-date-cells/design.md。
- **顺带修正**：PRD 中 v0.6.0 甘特平移误用 US-E4-05（与命令面板冲突），已改为 US-E4-08；本需求登记 US-E4-09。

### Sprint 11（已交付 v0.8.0 · 2026-10-22）

- **Goal**：大纲列宽可调（信息显示不全）+ 列显隐可配置（序号与任务说明固定）。
- **交付**：表头列右缘手柄拖拽调宽（松手一次提交、双击复位、误触 2pt 阈值、末列内缩避让边界手柄、聚焦栏不提供手柄）；视图菜单与表头右键菜单显隐列，序号/任务说明固定；`OutlineColumnPreferences` 纯函数统一列集合与宽度区间；偏好持久化两项且不进撤销栈；表头与行统一 leading 锚定 + 裁切修掉溢出错列。
- **测试**：策略 12 + 布局 8 + Store 12 例；全量 742/742。
- **设计稿**：docs/archive/Sprint11-outline-columns/design.md。
- **未做**：列顺序拖拽重排、列宽自动适配内容、拖拽性能专项（≥500 行帧耗时用例留后续）。

### Sprint 12（已交付 v0.8.3 / v0.8.4 · 2026-10-23 → 10-24）

- **Goal**：发版链路工程化 + 甘特横向平移回归收口。
- **交付 v0.8.3**：一键发版工具链（`release.sh` / `package.sh` / `release_notes.sh`），本地与 CI 同源，产物版本号不一致在打包阶段即失败；顺带修复发版链路缺陷 D-025（UTC runner 时区错位）、D-026（artifacts 推送无重试）。
- **交付 v0.8.4**：D-027 —— v0.6.0 交付的 F-14-18 双指横向平移在真机上无响应。两轮排查后确认四处串联闸门（事件窗口为 nil、SwiftUI/AppKit 坐标空间混用、监听绑在已销毁实例、首响应者恒为 field editor 被判「编辑中」），逐条拆除并收敛为单例监听 + 光标命中判定；判定抽为 `GanttScrollRouter` 纯函数，新增 26 例用例（纯函数 + 合成 `NSEvent` 事件级消费 + store 级整天平移），全量 **768/768**，并以合成 `CGEvent` + 现场日志跑通端到端。
- **逃逸登记**：D-027 由验收 Demo 发现（缺陷逃逸率 1/3 = 33%），教训写入 `docs/features/01-views-editing.md` F-14-18「可测性边界」——监听/事件型胶水层必须补一条状态不变量断言，不能只靠人工手测兜底。
- **遗留核对**：D-022 / D-023 / D-024 的目标版本 `v0.5.1` 已被跳过（实际按 v0.6.0 → v0.8.4 连发），三项仍为顺延状态，**待重新排期**（候选：v0.9.0 技术债批次，其中 D-023 违反例引擎日历日口径，与 A7 基线无关，可独立修）。

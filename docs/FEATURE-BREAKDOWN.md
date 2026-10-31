# Kaido 功能拆解总纲

> 来源：OmniPlan 内置简体中文使用手册（`/Applications/OmniPlan.app/Contents/Resources/zh-Hans.lproj/OmniPlan Help/`，24 章）逐章拆解。
> 拆解日期：2026-10-17。搜索功能已先行实现（见 `Sources/Kaido/Search/`、`AI/`），本总纲覆盖其余全部功能。
> 术语基准：[04-glossary.md](features/04-glossary.md)（同一事物全项目同一术语）。

## 子文档索引

| 文档 | 覆盖手册章节 | 条目数 |
| --- | --- | --- |
| [01-views-editing.md](features/01-views-editing.md) | ch.11–16 创建项目/工具栏/大纲/甘特/网络/资源视图 | 70 |
| [02-inspectors-scheduling.md](features/02-inspectors-scheduling.md) | ch.20–30 五大检查器 + 违例引擎（16 类违例） | 50 |
| [03-platform-collab.md](features/03-platform-collab.md) | ch.31–41 仪表盘/导入导出/报告/云/协作/偏好/快捷键 | 55 |
| [04-glossary.md](features/04-glossary.md) | ch.10 术语表 → Kaido 定名与代码标识符 | 82 术语 |

**合计 175 条功能**。优先级分布（按各文档功能总表逐行统计）：P0 ×15 / P1 ×59 / P2 ×58 / P3 ×42。

## 阶段路线图

### Phase 0 — 已具备（本次会话完成）
任务 CRUD、状态/优先级/标签/指派/进度、AI 自然语言筛选（AIFilterTranslator）、字面/正则查找（FindController/FindPattern）、任务自答式过滤（SearchTerm）。对应已实现：`Model/`、`Search/`、`AI/`、`Views/ContentView.swift`。

### Phase 1 — 调度基座（P0，15 条）
目标：让 Kaido 从「待办清单」升级为「调度引擎」。
- **模型重构**：`TaskItem` 扩展 `parentID`/`kind`（任务/群组/里程碑）/`duration`/`effort`；`dependencies: [UUID]` → `[TaskDependency]`（类型 + lag，迁移兼容隐式 FS）——F-22-07
- **资源模型**：`Resource`（人员/设备/素材/群组、单位、效率、使用成本+小时成本、可用期）+ `TaskAssignment`，替换 `assignee: String?`——F-23-01
- **时间与投入栏位族**：持续时间/投入/已完成投入/开始/结束——F-13-04、F-22-03（投入↔持续时间公式 `duration = effort / Σ(units×efficiency)`）
- **任务信息与备注**：任务类型、重复任务、富备注（文本+链接）——F-22-01、F-25-01
- **大纲交互**：创建/删除/添加子项族、基础栏位族——F-13-01/03/06、F-12-08
- **过滤与完成度**：过滤器入口与大纲过滤（衔接现有 AIFilter）——F-12-04、F-13-15、F-14-10
- **持久化**：本地优先单文件格式（.kaido JSON）——F-34-01
- **命令面板**：⌘K 全命令入口——F-41-01

### Phase 2 — 视图与检查器（P1，59 条）
- 甘特视图：结构编辑、相关性绘制/删除、拖拽时间、手动安排、非工作时数着色、基线对比、重要路径高亮
- 大纲完整栏位族（约束/成本/宽延/差异）、资源视图与资源时间线、项目检查器（标题/时间线/摘要）
- 违例引擎：13 错误 + 3 警告，每次调度变更后重算（环检测 DFS、约束冲突、投入超载）
- 样式检查器、自定数据（键/值）、网络视图基础

### Phase 3 — 进阶调度与交换（P2，58 条）
挣值分析、模拟（蒙特卡洛里程碑预测）、资源负荷平衡、吊床任务、四类时限约束、重复规则完整化、CSV 导入导出、.ics 双向同步（EventKit）、报告/打印、kaido:// 深链

### Phase 4 — AI 时代增量（P3，42 条，有意偏离 OmniPlan 之处）
- 项目组合仪表盘（替代 Pro 仪表盘）
- 叙述式 AI 报告（Markdown 生成，替代 HTML 模板）
- 字段级版本历史 + AI 语义合并建议（替代更改跟踪服务器）
- 本地优先 + 文件夹委托同步（替代中心服务器协作）
- AI 自然语言自动化（替代 AppleScript/插件）

## 实施约定
- 每条功能以 `F-<章>-<序号>` 编号追踪，验收以规格文档中的「OmniPlan 行为」字段为准。
- Phase 1 完成前不动 Phase 2；模型重构（TaskDependency/Resource）是硬前置。
- 文档风格遵循 doc-style 规则：术语一致（以 04-glossary 为准）、必须/应当/可以 分级、锚点引用不写行号。

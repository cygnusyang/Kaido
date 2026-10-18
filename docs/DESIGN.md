# Kairo 设计系统（DESIGN）

- 版本：1.0
- 日期：2026-10-18
- 状态：已冻结（DM-4 / DM-5 裁定，Sprint 4 UI 重设计）
- 适用：Kairo 全部界面。macOS 为当前唯一壳层；`KairoPresentation` 的快照类型为跨平台复用边界。
- 上位依据：[设计重设计规格](design/ui-redesign.md)、[架构决策 ADR-013](02-architecture.md#adr-013-呈现层与唯一写路径)。
- 术语：沿用 [04-glossary.md](features/04-glossary.md)。「重要路径」为定名，「关键路径」只作同义说明。

## 1. 原则

1. **信息先于装饰**：界面首先回答「何时、依赖谁、完成多少」。颜色、形状与间距服务于这三类事实。
2. **语义单源**：同一状态在行、条、状态栏与检查器使用同一 token 与同一核心计算结果。界面不各自解释。
3. **颜色不独担信息**：每个语义信号同时具备文本、图标或形状。色觉障碍与高对比模式不得丢失信息。
4. **品牌克制**：品牌渐变只用于小面积 AI 标识；任务条、标题与语义信号不用渐变。
5. **原生优先**：优先使用系统控件与原生工具栏；偏离 Apple HIG 时必须登记理由。

## 2. 色彩

### 2.1 表面与文字

| Token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `surface.base` | `#FFFFFF` | `#1C1C1E` | 内容底：大纲行、画布、检查器 |
| `surface.chrome` | `#F6F7F9` | `#242426` | 壳层：工具栏、筛选栏、表头、状态栏、检查器分组卡 |
| `surface.elevated` | `#FFFFFF` | `#2C2C2E` | 浮层：弹出层、命令面板。必须不透明 |
| `separator` | `#D8DAE0` | `#3A3A3C` | 分隔线、浮层边框、表格边界 |
| `grid` | `#E6E8EC` | `#303032` | 画布网格 |
| `nonWorkingBand` | `#F2F3F5` | `#232325` | 非工作带 |
| `selection` | `#E4E7FA` | `#2B3050` | 选中行底 |
| `textPrimary` | `#1C1C1E` | `#F2F2F7` | 正文、标题、数值 |
| `textSecondary` | `#5C6169` | `#A6A6AD` | 次要说明、未排期占位、空群组 |

表面语义不得混用：`surface.base` 承载内容，`surface.chrome` 承载壳层，`surface.elevated` 承载浮层。浮层必须同时具备不透明底色、1pt `separator` 边框与阴影；不得用 material 承载文字。

### 2.2 语义信号

| Token | 浅色 | 深色 | 用途 |
|---|---|---|---|
| `today` | `#4A56D6` | `#9AA6FF` | 今天线、今天芯片 |
| `critical.graphic` | `#A13EF2` | `#A13EF2` | 重要路径任务条描边、依赖线 |
| `critical.text` | `#7A1FC4` | `#C79BFF` | 重要路径文字与图例 |
| `overdue` / `violationError` | `#C4121F` | `#FF453A` | 逾期、错误级违例 |
| `violationWarning` | `#A15C00` | `#FF9F0A` | 警告级违例、优先级「紧急」 |
| `status.success` | `#1E7B4D` | `#4BD18A` | 健康点、完成徽标 |
| `accent.base` | `#5F6CF8` | `#5F6CF8` | 图形、焦点外环。禁止承载正文 |
| `accent.strong` | `#4A56D6` | `#9AA6FF` | 正文级强调、焦点内环、编辑框边框 |
| `progressTrack` | `#E4E7EC` | `#3A3A3C` | 进度条底 |
| `progressFill` | `#3D74C9` | `#6FA3E8` | 进度填充 |
| `dependency` | `#7A8290` | `#8B93A3` | 常规依赖线 |

红色只用于错误与逾期。优先级「紧急」使用 `violationWarning` 加「!」形状，不使用红色。重要路径使用品牌紫，不使用红色。

品牌渐变 `#57A0FF → #5F6CF8 → #A13EF2` 只用于 AI 小面积标识与渐变边。`#57A0FF` 不单独承担界面信号。

### 2.3 对比度矩阵

判定阈值：正文与语义文字 ≥ 4.5:1；图形、线条、进度填充与非文本信号 ≥ 3:1。以下比值按 WCAG 2.x 相对亮度公式计算。

**浅色**

| 前景 | 底色 | 比值 | 判定 |
|---|---|---|---|
| `textPrimary` | `surface.base` | 17.01 | 通过 |
| `textSecondary` | `surface.base` | 6.23 | 通过 |
| `textSecondary` | `selection` | 5.08 | 通过 |
| `overdue` | `surface.base` | 6.08 | 通过 |
| `violationWarning` | `surface.base` | 5.19 | 通过 |
| `status.success` | `surface.base` | 5.26 | 通过 |
| `critical.text` | `surface.base` | 7.45 | 通过 |
| `accent.strong` | `surface.base` | 5.84 | 通过 |
| `accent.base` | `surface.base` | 4.21 | 仅图形 |
| `overdue` | `selection` | 4.95 | 通过，但仍按 §2.4 替换 |
| `violationWarning` | `selection` | 4.23 | **不通过**正文阈值 |
| `status.success` | `selection` | 4.28 | **不通过**正文阈值 |
| `accent.base` | `selection` | 3.43 | 仅图形 |
| `today` | `surface.base` | 5.84 | 通过（非文本） |
| `critical.graphic` | `surface.base` | 4.68 | 通过（非文本） |
| `dependency` | `surface.base` | 3.87 | 通过（非文本） |
| `progressFill` | `progressTrack` | 3.73 | 通过（非文本） |

**深色**

| 前景 | 底色 | 比值 | 判定 |
|---|---|---|---|
| `textPrimary` | `surface.base` | 15.25 | 通过 |
| `textSecondary` | `surface.base` | 7.03 | 通过 |
| `textSecondary` | `selection` | 5.29 | 通过 |
| `overdue` | `surface.base` | 4.99 | 通过 |
| `violationWarning` | `surface.base` | 8.28 | 通过 |
| `status.success` | `surface.base` | 8.74 | 通过 |
| `critical.text` | `surface.base` | 7.75 | 通过 |
| `accent.strong` | `surface.base` | 7.51 | 通过 |
| `accent.base` | `surface.base` | 4.04 | 仅图形 |
| `overdue` | `selection` | 3.76 | **不通过**正文阈值 |
| `violationWarning` | `selection` | 6.22 | 通过，但仍按 §2.4 替换 |
| `critical.text` | `selection` | 5.83 | 通过，但仍按 §2.4 替换 |
| `today` | `surface.base` | 7.51 | 通过（非文本） |
| `critical.graphic` | `surface.base` | 3.64 | 通过（非文本） |
| `critical.graphic` | `surface.elevated` | 2.98 | **不通过**。深色浮层不得绘制重要路径图形 |
| `dependency` | `surface.base` | 5.51 | 通过（非文本） |
| `progressFill` | `progressTrack` | 4.37 | 通过（非文本） |

### 2.4 选中行规则

选中行必须遵守以下规则，不因浅色模式个别比值达标而豁免：

1. 次要文字提升为 `textPrimary`。
2. 语义色文字（逾期、违例、警告、成功、重要路径）一律替换为 `textPrimary`。
3. 语义由图标或形状承载：时钟、三角、对勾、暂停、菱形等。
4. 选中状态另以 2pt 左轨表达；高对比模式同样为 2pt。

理由：浅色 `violationWarning` 与 `status.success` 在 `selection` 上低于 4.5:1，深色 `overdue` 在 `selection` 上为 3.76:1。统一替换避免模式相关规则分叉。

### 2.5 高对比模式

触发条件为系统「增强对比度」。高对比模式必须保留结构边界与信号可辨性。

| Token | 浅色高对比 | 深色高对比 |
|---|---|---|
| `surface.base` | `#FFFFFF` | `#000000` |
| `surface.chrome` | `#F2F2F2` | `#141416` |
| `surface.elevated` | `#FFFFFF` | `#1F1F22` |
| `separator` | `#6E7686` | `#A8B0BE` |
| `grid` | `#C4C8D0` | `#4A4A4E` |
| `selection` | `#D3D9F7` | `#1F2A55` |
| `textPrimary` | `#000000` | `#FFFFFF` |
| `textSecondary` | `#3C4048` | `#C7C7CC` |
| `today` | `#2C6BC9` | `#8FC0FF` |
| `critical.graphic` | `#8F2DD6` | `#B968F5` |
| `critical.text` | `#6A15B0` | `#D9B3FF` |
| `overdue` | `#A80E1A` | `#FF6B61` |
| `violationWarning` | `#8A4E00` | `#FFB340` |
| `status.success` | `#14663D` | `#6BE3A3` |
| `dependency` | `#5C6472` | `#A8B0BE` |
| `progressTrack` | `#D5D8DE` | `#3A3A3C` |
| `progressFill` | `#1F5FA8` | `#8AB8F0` |

高对比复核结果：

- 浮层边框与底色比值：浅色 4.57:1、深色 9.62:1，均 ≥ 3:1。
- 今天线：5.18:1 / 11.15:1。
- 依赖线：5.96:1 / 9.62:1。
- 进度填充与轨道：4.51:1 / 5.51:1。
- 选中底上的语义文字最低为 4.74:1（浅色警告）；仍执行 §2.4 的替换规则。
- `grid` 为装饰性网格，不承担判定；月份与周边界使用 `separator`。

## 3. 排版

| 角色 | 字号 | 字重 | 用途 |
|---|---|---|---|
| 正文 | 13 | regular | 大纲标题、检查器取值、条标签 |
| 正文强调 | 13 | semibold | 选中标题、分组标题、表头 |
| 次要 | 11 | regular | 编号、状态、违例、辅助说明、空群组 |
| 标签 | 12 | regular | 检查器字段标签 |
| 标题 | 13 | semibold | 检查器页眉、浮层标题 |

- 字体使用系统字体（SF Pro）。数字使用等宽数字（`monospacedDigit`），保证进度与日期列对齐。
- 字号档位为 13 / 15 / 17。日期、持续、负责人、完成度列宽按 `bodyFontSize / 13` 缩放；标题最小宽度为 `160 × 该比例`。
- 编号、状态、违例列固定 11pt 与固定列宽，不随字号缩放。
- 大纲标题单行尾部省略；悬停显示全文 tooltip；VoiceOver 读取完整标题。就地编辑时输入框可横向滚动。

## 4. 尺寸与间距

| 项 | 值 |
|---|---|
| 间距梯度 | 2 / 4 / 6 / 8 / 12 / 16 / 24 |
| 圆角 | 3（条）、4（任务条）、6（控件）、10（浮层） |
| 行高 | `max(28, bodyFontSize + 15)`；默认 28 |
| 两级表头 | 44（22 + 22） |
| 筛选栏 | 32 |
| 状态栏 | 26 |
| 工具栏 | 52 为设计参考；以原生 `.toolbar` 实际高度为准 |
| 最小点击区 | 24×24；推荐 28×28 |
| 大纲默认 / 范围 | 600 / 320–640 |
| 画布最小宽 | 320（1pt 分隔线计入预算） |
| 检查器默认 / 范围 | 320 / 280–420 |
| 图表聚焦标签栏 | 180 |

检查器宽度小于 300 时，字段行改为两行：标签 12pt 在上，值 13pt 在下，行高 44。

## 5. 组件

### 5.1 工具栏与筛选栏

- 工具栏必须使用原生 `.toolbar`。工具栏不显示文稿标题，窗口标题承载文稿名。
- 工具栏项顺序：视图模式 → 缩放 → 重要路径开关 → 违例徽标 → AI 过滤徽标 → 保存状态 → 新建「+」（28×28）→ 检查器开关。
- 筛选栏高度 32，可收起。筛选栏包含自然语言输入、筛选令牌与查找入口。

### 5.2 大纲行与表头

- 行高与画布行严格一致，顺序一致。
- 列顺序：状态 18 / 违例 18 / 编号 30 / 标题 flex（最小 160）/ 开始 78 / 结束 78 / 持续 56 / 负责人 76 / 完成度 72。
- 列降级阈值（默认字号）：≥586 全列；510–585 隐藏负责人；454–509 隐藏持续；376–453 隐藏结束；320–375 隐藏开始。状态、违例、编号、标题、完成度始终可见（聚焦标签栏除外）。大纲不做横向滚动。
- 完成度列同时显示百分比与微型进度条。
- 群组行显示聚合开始、结束、持续与加权进度，并标注「由子任务聚合」。

### 5.3 时间画布

| 元素 | 规格 |
|---|---|
| 任务条 | 高 14，圆角 4，进度填充 `progressFill` |
| 群组条 | 高 10，两端帽形 |
| 里程碑 | 10×10 菱形 |
| 逾期描边 | 1.5pt `overdue` |
| 重要路径描边 | 1.5pt `critical.graphic` |
| 双描边 | 禁止；逾期优先 |
| 违例标记 | 条尾 12pt 三角，不描边条体 |
| 依赖线 | 1pt `dependency`；重要路径 1.5pt `critical.graphic` |
| 今天线 | 2pt `today`，覆盖网格与条体 |
| 非工作带 | `nonWorkingBand`，位于依赖线之下 |

- 依赖线置于非工作带之上、任务条之下。
- 条标签默认位于条外右侧 6pt，颜色 `textPrimary`。右侧空间不足 60pt 时翻到左侧；仍不足时隐藏。月缩放默认隐藏，悬停或选中时显示浮层标签。
- 里程碑标签默认位于菱形右侧；空间不足 60pt 时翻左。
- 今天不在可见范围时不绘制今天线；状态栏提供「回到今天」。

### 5.4 状态栏

- 高度 26，底色 `surface.chrome`，上边界 1pt `separator`。
- 健康点必须同时使用图标、文本与颜色，不得只靠颜色。
- 常驻项：健康点、加权进度、违例计数、逾期计数、保存状态。
- 宽度 < 1100 隐藏剩余天数；< 980 隐藏重要路径计数与可见范围；< 900 隐藏缩放与隐藏任务数。被隐藏项进入「⋯」菜单或 tooltip。
- 选择摘要只在宽度 ≥ 1100 且存在选择时显示。

### 5.5 检查器

- 顶部 40pt：面包屑、锁定、关闭。下一行为「检查器 | 违例 N」标签页。
- 分组卡使用 `surface.chrome`，卡间距 12，内边距 12。
- 字段标签使用 `textSecondary` 12pt；取值使用 `textPrimary` 13pt。
- 锁定为视图状态，不写入任务模型。

### 5.6 浮层与命令面板

- 浮层使用 `surface.elevated`、1pt `separator` 边框、圆角 10、阴影。
- 命令面板选中行使用 `selection` 底加 2pt `accent.strong` 左轨；不使用品牌渐变。
- 添加前置任务浮层为 320×400。

### 5.7 状态形状

| 状态 | 形状 | Token |
|---|---|---|
| 待办 | 空心圆 | `textSecondary` |
| 进行中 | 半填充圆 | `accent.strong` |
| 完成 | 对勾 | `status.success` |
| 阻塞 | 暂停 | `violationWarning` |
| 逾期 | 时钟后缀 | `overdue` |
| 重要路径 | 紫描边 | `critical.graphic` |
| 违例 | 条尾三角 / 行内图标 | 按严重级 |

选中行内，上述 token 文字改为 `textPrimary`，形状保持不变。

## 6. 交互状态

| 状态 | 规格 |
|---|---|
| 悬停 | `textPrimary` 4%（深色 6%）叠加 |
| 就地编辑 | `surface.base` 底 + 1pt `accent.strong` 边框 + 2pt 25% 光晕 |
| 拖放目标 | `accent.strong` 8% 叠加 |
| 插入线 | 2pt `accent.strong` |
| 焦点环 | 3pt 外环 `accent.base` 35% + 1pt 内环 `accent.strong`，偏移 1pt |
| 高对比叠加 | 悬停与拖放不透明度提高到 8% / 12%；焦点外环 60% |

悬停、编辑与拖放只使用叠加，不新增品牌色。

## 7. 可访问性

1. **对比度**：正文 ≥ 4.5:1；图形与非文本信号 ≥ 3:1。新增颜色必须先通过矩阵复核再入库。
2. **焦点**：所有可键盘操作元素必须有可见焦点环。大纲内 `⌃Tab` 将焦点移出，不得被缩进快捷键截断。
3. **运动**：减弱动态效果开启时，撤销反馈、脉冲提示与滚动动画改为静态变化；不播放位移或缩放动画。
4. **语音**：大纲行朗读顺序为「标题 → 状态 → 起止 → 完成度 → 违例」。画布按可见条提供摘要；依赖线以「N 条依赖，M 条重要路径」分组摘要暴露，不逐线朗读。
5. **非颜色信号**：状态、逾期、违例、重要路径均具备形状或图标。非工作带在表头提供文字标签与 VoiceOver 说明。
6. **点击区**：行内违例图标（18pt）与条尾三角（12pt）只作显示，不单独承接点击。入口为整行、整条、工具栏徽标与 `⌥⌘V`。

## 8. 实现映射

- SwiftUI 实现位于 `Apps/macos/Sources/Theme/DesignTokens.swift`。
- Token 以 `Color` 与 `CGFloat` 常量暴露，按 `ColorScheme` 与 `colorSchemeContrast` 解析。
- 视图只引用语义 token，不直接写十六进制色值。新增色值必须同时更新本文档与对比度矩阵。
- `KairoPresentation` 不包含颜色、字号或任何视觉 token；快照只携带语义枚举与几何数值。

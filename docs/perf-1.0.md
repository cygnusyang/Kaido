# Kairo 性能 NFR 复测（v0.17 / 1.0 前置）

> 复测日期 2026-10-25 · 口径：[08-baselines](features/08-baselines.md) §6、[09-baseline-version-plan](features/09-baseline-version-plan.md) §2、[10-multi-baseline-gantt](features/10-multi-baseline-gantt.md) §9
> 仓库：main @ `285f172`（v0.16.0）+ 未提交工作区（多人共享 checkout，测量时含 v0.17 并行改动）

## 1. 环境与构建

| 项 | 值 |
| --- | --- |
| 机器 | Apple M1（8 核），macOS 27.0.1（Darwin 27.0.0），arm64 |
| 工具链 | Swift 6.3.1（swiftlang-6.3.1.1.2 clang-2100.0.123.102） |
| debug | `swift test --disable-sandbox -c debug --filter 'Performance'` |
| release | `swift test --disable-sandbox -c release --filter 'Performance'` |
| 覆盖 | 8 用例 / 3 套件（BaselinePerformanceTests、应用性能 + 日宽性能、GanttRenderPerformanceTests），debug 与 release 各全绿一次 |

`swift test` 并行执行用例，量测期间相互争 CPU，墙钟偏保守（v0.13 记录同一口径）。体积为确定值，耗时为样本。

## 2. 5,000 任务读写（NFR：≤ 1 s）

| 规模 | 构建 | encode | decode | variance | 体积 | 每条目 |
| --- | --- | --- | --- | --- | --- | --- |
| 5,000 × 3 基线 | debug | 0.104 s | 0.145 s | 0.233 s | 5.10 MB | 231 B |
| 5,000 × 3 基线 | release | 0.136 s | 0.155 s | 0.170 s | 5.10 MB | 231 B |
| 5,000 × 5 基线 | debug | 0.143 s | 0.203 s | 0.231 s | 7.31 MB | 231 B |
| 5,000 × 5 基线 | release | 0.167 s | 0.213 s | 0.168 s | 7.31 MB | 231 B |

多轮观测的 debug encode 落在 0.099–0.171 s：release 不比 debug 稳定更快，瓶颈在 Foundation 的 pretty JSON 与并行负载抖动，不在 Swift 代码生成质量。

## 3. 1,000 行渲染（10 §9）

| 指标 | 预算 | debug | release | 判定 |
| --- | --- | --- | --- | --- |
| 1000 行 × 3 基线快照构造 P50 | < 100 ms | 42.8 ms | 30.4 ms | 达标 |
| ↑ 同项最快 / 最差 | — | 40.5 / 43.1 ms | 27.8 / 37.4 ms | 参照 |
| 选择 / 展开收合 / 缩放 | ≤ 100 ms | 52.9 / 53.9 / 52.1 ms | 32.7 / 32.1 / 31.0 ms | 达标 |
| 日宽提交（同一条 refresh 管线） | ≤ 100 ms | 51.7 ms（最差 52.4） | 31.6 ms（最差 32.8） | 达标 |
| 排期重算 1000 任务 | ≤ 1 s | 91.9 ms | 50.8 ms | 达标 |
| 横向翻窗 `panWindow`（跨整日，重建全表） | < 16.7 ms（60Hz 单帧） | 54.6 ms（最差 61.3） | 37.6 ms（最差 47.7） | **不达标** |
| 1000 行（无基线）快照构造（单独运行） | — | 89.5 ms | 43.3 ms | 参照 |

亚日滚动不重建：`HorizontalPanAccumulator` 只累积余量，跨整日才提交一次 `panWindow`。所以掉帧点集中在跨日那一刻，其余滚动事件近似零成本。

## 4. NFR 判定

| NFR | 结论 |
| --- | --- |
| 5,000 任务读写 ≤ 1 s | **达标**：最慢 decode 0.213 s，余量约 4.7 倍 |
| 1,000 行渲染不掉帧 | **不达标**：跨日翻窗单帧 release 37.6 ms / debug 54.6 ms，超 16.7 ms 预算；「单次视图刷新 ≤ 100 ms」这一半达标（见 §3） |

## 5. 不达标与未覆盖（单列）

1. **跨日翻窗掉帧（不达标）**：release 37.6 ms、debug 54.6 ms（1000 行），是 60Hz 单帧预算的 2.2–3.3 倍。根因是 `panWindow` 走整表 `refresh()`，重算 1000 行排期快照并重建全部 3000 条基线细条，未复用视口切片。连续横滑每跨一天掉 1–2 帧，表现为拖动中的周期性顿挫，不是「偶尔一帧」。
2. **逐帧绘制成本未实测（未覆盖）**：10 §9 声称绘制按 `firstRow…lastRow` 只画视口约 40 行，但单元测试没有逐帧钩子，本次拿不到该数字；上表「横向翻窗」是唯一可测的近似帧，不能替代绘制侧取证。

## 6. 与 v0.13 记录对比

| 项 | v0.13（CHANGELOG / 08 §6） | 本次 | 说明 |
| --- | --- | --- | --- |
| 5,000 × 3 体积 | 5.10 MB | 5.10 MB | 逐字节一致，存储形态未漂 |
| 5,000 × 5 体积 | 7.31 MB / 231 B/条目 | 7.31 MB / 231 B/条目 | 同上 |
| encode（debug） | 0.108–0.515 s | 0.104–0.171 s | 落在同区间下沿，差异属负载噪声 |
| decode / variance（debug） | 0.150–0.262 / 0.194–0.284 s | 0.145–0.213 / 0.170–0.239 s | 略快，机器更闲 |
| 1000 行 × 3 基线构造、翻窗 | 无记录 | 42.8 / 54.6 ms（debug） | 本次新增口径 |

任务书引用的「encode 0.102 s」在仓库记录里查不到：v0.13 记录是 0.108–0.515 s（下沿 0.108），本文一律以 CHANGELOG 为准。

## 7. 遗留

- 跨日翻窗掉帧（§5 第 1 条）需另立工作项做增量刷新（复用行快照、只重算可见切片），本次只取证不修。
- 逐帧绘制成本要补测，需在 app 侧加逐帧钩子，建议与上条同批处理。
- release 数字仅本机（Apple M1）；CI 只跑 debug，release 数据属手工复测值。

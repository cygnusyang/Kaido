# 17 · EVM 数据日期（Status Date）字段设计

> 2026-10-27。前置决策：v1.3 只做工时挣值（SV/SPI），**不引入成本/费率、不引入实际工时填报**，故 CV/CPI 不做。

## 1. 为什么必须先有这个字段

PV（计划价值）的定义是「**到某个日期为止**按计划应完成的工作量」。没有这个日期，PV 无法计算，SPI 也就无从谈起。Kaido 现在只有 actualStart / actualFinish，那是**任务事实**，不是**观察时点**。

## 2. 字段定义

```swift
// ProjectMetadata 新增，可选加法字段
public var statusDate: Date?   // nil = 使用「今天」（每次渲染时求值）
```

- **不升 formatVersion**（仍为 2）：缺键 = nil，旧文件读入行为不变
- **不进基线**：数据日期是**报告参数**，不是计划事实。基线只记任务起止，不该被报告口径污染
- 语义：nil 时 UI 明确显示「数据日期：今天（未固定）」，并提示「固定后报告可复现」——**动态默认会让同一份周报今天和明天不同**，这一点必须让用户看见

## 3. 取值与校验

| 规则 | 处理 |
| --- | --- |
| 早于项目开始 | 接受，但 PV 恒为 0 → SPI 显示「—」而非 0 或 ∞ |
| 晚于项目结束 | 接受（项目已过计划终点，SV 为正即提前完成） |
| 落在非工作日 | **不吸附**。数据日期是观察时点，不是排期输入，吸附反而制造错觉 |
| 时区 | 与项目一致，按当日 00:00 归一化存储 |

## 4. 计算口径（工时口径）

对每个未取消的任务：

```
PV_i = effort_i × clamp((statusDate − plannedStart_i) / (plannedFinish_i − plannedStart_i), 0, 1)
EV_i = effort_i × effectiveProgress_i
SV   = Σ EV_i − Σ PV_i        // 单位：小时
SPI  = Σ EV_i / Σ PV_i        // ΣPV = 0 时返回 nil
```

**effectiveProgress 的两条规则（关键，容易做错）**：

1. `actualFinish ≤ statusDate` → 视为 100%，**忽略 progress 字段**（已完成的任务不该因为没填进度而被算成半成品）
2. `actualFinish > statusDate` → 视为 **未完成**。即在追溯某历史时点时，**晚于该时点才完成的任务不能计入**——否则历史报告会随时间“自我修饰”

里程碑：`plannedFinish ≤ statusDate` 则全额计入，否则 0（零工期，不能按比例插值）。

已取消任务：完全不参与（与排期引擎一致，不进分母）。

## 5. 已知局限（必须写进 UI，不许藏）

- **SPI 在项目末期必然回归 1**（任务最终都完成，EV 追平 PV）。它适合观察进行中的趋势，不是终局结论。PMI 后来为此提出 Earned Schedule（SPI(t)=ES/AT），本版不做，文档注明。
- 工时口径下的 SPI 反映的是**工作量进度**，若任务的工作量分布前重后轻，早期 SPI 会偏高。

## 6. 不做

- 成本类指标（CV/CPI）——无费率、无实际成本
- 实际工时（AC in hours）——用户决定不引入工时填报
- Earned Schedule、To-Complete Performance Index
- 数据日期进基线快照

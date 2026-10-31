# issue #16 复现步骤：群组依赖不传播 + 群组跨度恒为 1 天

> 对应 issue：[#16](https://github.com/cygnusyang/Kaido/issues/16) · 版本：v0.14.1 · 平台：macOS
> 记录时间：2026-10-25 · 复现者：lead（真实建 WBS 时发现，非构造用例）

## 环境

    Kaido v0.14.1（/Applications/Kaido.app 或 dist/KaidoCLI）
    任一含「群组 + 子任务」的 .kaido 项目

## 最小复现（3 条命令）

```bash
# 1) 建项目与两个阶段组
KaidoCLI project create "复现 #16" --file /tmp/repro16.kaido
cat > /tmp/repro16-wbs.json <<'JSON'
[
  { "title": "阶段 A", "kind": "group", "children": [
      { "title": "A1", "durationDays": 2 },
      { "title": "A2", "durationDays": 3 } ] },
  { "title": "阶段 B", "kind": "group", "children": [
      { "title": "B1", "durationDays": 2 } ] }
]
JSON
KaidoCLI wbs import /tmp/repro16-wbs.json --file /tmp/repro16.kaido

# 2) 给「阶段 B」加依赖：阶段 A 完成后再开始
A=$(KaidoCLI task list --json --file /tmp/repro16.kaido | python3 -c 'import sys,json;print([t["id"] for t in json.load(sys.stdin) if t["title"]=="阶段 A"][0])')
B=$(KaidoCLI task list --json --file /tmp/repro16.kaido | python3 -c 'import sys,json;print([t["id"] for t in json.load(sys.stdin) if t["title"]=="阶段 B"][0])')
KaidoCLI task update "$B" --dep "$A" --file /tmp/repro16.kaido

# 3) 看排期
KaidoCLI schedule compute --file /tmp/repro16.kaido
```

## 预期

- `阶段 B` 的所有子任务（B1）最早开始时间 ≥ `阶段 A` 全部完成时间
- `阶段 B` 的跨度等于其子任务聚合跨度（2 天），而不是 1 天

## 实际（v0.14.1 实测）

| 对象 | 实际结果 |
| --- | --- |
| 子任务 B1 | **不动**，仍从项目锚点起排（10/25），与阶段 A 并行 |
| 群组「阶段 B」 | 顺延了，但跨度恒输出 **1 天** |
| 甘特图 | 群组条走 `aggregateStart/Finish`（聚合），与 `schedule compute` 打印的群组条目不一致 |

日志/输出摘录（真实路线图项目，35 项）：

    73D46551 v0.16 列表与状态词汇   2026-10-25T16:00:00Z → 2026-10-26T16:00:00Z（1 天，ASAP）
    D68B6978 大纲表头拖拽重排（#12） 2026-10-24T16:00:00Z → 2026-10-27T16:00:00Z（3 天，ASAP）

群组声称 10/26 开始、1 天结束；其子任务实际 10/25 开始、跨 3 天。

## 影响面（真实成本）

在 35 项 / 7 组的路线图上做「阶段串行」，降级为叶子级门链后：

| 项 | 数量 |
| --- | --- |
| 手写依赖边 | 21 条 |
| 人工判断阶段收口 | 4 次 |
| 插入 1 个新任务需重新指派的依赖 | 5 条 |

插入任务会改变「最长任务 = 阶段门」，需要重新比较工期并改指下游依赖；漏改一条不会报错，只会让某阶段莫名提前。

## 期望的验收（二选一）

**方案 A（建议）**：群组依赖下推 —— 群组作为阶段门，其前驱完成后子树所有叶子的最早开始不早于该完成时刻。
**方案 B**：明确拒绝「目标是群组」的依赖，并提示「请对叶子任务设依赖」。

两者都要附带：`schedule compute` 不再对群组输出独立条目，或输出与甘特同源的聚合跨度。

---
description: 把 Kairo 任务标记完成并回报群组完成度
argument-hint: <任务 ID 或 ID 前缀>
---

把任务 `$ARGUMENTS` 标记为完成。

步骤：

1. 若当前会话尚未打开项目，先用 `project_open` 打开 `KAIRO_PROJECT` 指向的文件
   （未设置时询问用户）。
2. 调用 `status_update`，参数 `{"taskID": "<完整 ID 或前缀>", "status": "done"}`。
   工具返回任务标题、`completedAt` 与状态；失败时原样报告结构化错误。
3. 用 `task_get` 读取该任务的 `parentID`。若有父任务，再调用 `status_update`
   仅传 `taskID`（不带 `status`/`progress`）读取 `groupProgress`。
4. 回报：任务标题、完成时间、状态，以及所在群组的完成度百分比。
   无父任务时只回报任务本身。

约束：

- 任务 ID 不存在或前缀不唯一时，列出候选任务让用户选择，禁止猜测。
- 不要同时修改进度以外的字段；`done` 已把进度置为 100%。

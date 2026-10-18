# Kairo Claude Code 插件

把 Kairo 的计划能力接入 Claude Code：斜杠命令驱动 WBS、排期、违例查看与状态回写，
底层经 MCP 工具（ADR-005 契约同源）。

## 前置条件

1. 已在本仓库构建 MCP 服务：

   ```bash
   swift build -c release
   ```

2. 设置 `KAIRO_PROJECT` 为 `.kairo` 文件路径（可放入 shell 配置），或在命令中按提示提供。

## 加载

```bash
claude --plugin-dir /path/to/Kairo/Plugins/claude-code
```

MCP 启动脚本按以下顺序定位服务：

1. 环境变量 `KAIRO_MCP_BIN` 指定的可执行文件；
2. 仓库 `.build/release/KairoMCP`；
3. 仓库 `.build/debug/KairoMCP`。

三者都找不到时，脚本向 stderr 输出原因并以非零码退出。

## 命令

| 命令 | 作用 |
|---|---|
| `/kairo plan <需求>` | 读需求、建 WBS、排期、列违例 |
| `/kairo done <任务ID>` | 任务标记完成并回报群组完成度 |
| `/kairo status` | 任务表、重要路径与违例汇总 |

任务 ID 接受完整 UUID 或 ≥4 位唯一前缀。

## 已配置的 hook

当前版本不配置 hook。任务完成回写由 `/kairo done` 显式触发：Claude Code 的任务工具
与 Kairo 任务之间没有 ID 映射，自动检测完成信号会误伤或漏写。待 Sprint 4 引入映射后，
再以 hook 自动回写（US-E5-03 验收第 3 条）。

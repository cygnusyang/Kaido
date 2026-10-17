import Foundation

// KairoCLI 入口：子命令路由到 KairoSession 命令层（ADR-005 契约同源）。
// 退出码：0 成功 / 1 运行时错误 / 2 用法错误。
let code = CLIRouter.run(arguments: Array(CommandLine.arguments.dropFirst()))
exit(code)

# v0.17 稳定性审计 · 自动保存 / 外部更新 / 崩溃恢复

审计对象：`Apps/macos/Sources/WorkspaceStore.swift`、`Apps/macos/Sources/AppDelegate.swift`（v0.16.0 基线）。
方法：逐条读代码 → 用独立会话重写磁盘模拟外部写入 → 每条判定配一条可证伪断言（回滚修复必红）。
范围外：KaidoCore / KaidoCommands / KaidoPresentation / CLI / MCP / OutlineTable 未改动。

## 一、缺陷（已修）

| # | 位置 | 结论（改前 → 改后） |
| --- | --- | --- |
| B1 | WorkspaceStore.swift:2147 | **异步打开被外部轮询挤掉**：`checkExternalUpdate` 不看 `isLoading`，打开 A 的解码窗口内若旧项目 B 在磁盘变化，会同步重载 B——撤销栈清空、`pendingOpenURL` 被重设、`revision` 前进，A 的载入被判成「载入期间被编辑」，用户收到一条假提示且目标文件打不开。改后：载入窗口内跳过轮询，A 正常接管（断言 5 条）。 |
| B2 | WorkspaceStore.swift:1704、1968、2157 | **刷新失败把仍在编辑的项目摘出「最近打开」**：`open(url:)` 无条件 `forgetRecentProject`，外部刷新复用它 → 项目还开着，菜单里却没了，重启后找不回。改后：`forgetOnFailure` 参数，显式打开始终剔除（原语义不变），外部刷新保留记录。 |
| B3 | WorkspaceStore.swift:1892 | **⌘S 静默吞掉挂着的外部版本**：横幅在时保存会覆盖磁盘那版，`recordDiskVersion` 把横幅直接清掉，用户不知道覆盖了别人。改后：保存前记下横幅状态，成功后提示「Kept the local version」（复用既有 i18n 键，无新增文案）。 |
| B4 | AppDelegate.swift:58-76 | **退出时同一保存失败可能弹两次**：`alertMessage` 在 `NSAlert` 之后才清空，取消退出后视图的 alert 绑定仍为真，会补弹一次。改后：先取走文本并清槽再弹窗；同时补 `!hasUnsavedChanges` 复核——退出是最后一次落盘机会，失败态或仍脏都不放行。 |
| B5 | AppDelegate.swift:20-30、46 | **退出守卫不可断言**：裁决/面板/错误提示内联在模态代码里，没有缝就测不到「必拦」。改后：三个注入点（默认仍走 NSAlert / NSSavePanel，行为不变）+ `terminationReply()`，6 条退出断言可直接跑。 |

## 二、核对无缺陷（保留现状，断言已锁）

- **保存失败不得报已保存**：`save()` 失败 → `.failed`（:1907），`refresh()` 遇 `.failed` 不降级（:413）；失败不动 `projectURL` 与磁盘旧文件（`failedSaveKeepsPreviousFileAndPath`）。
- **写盘原子性**：`KaidoFile.save` 走 `Data.write(options: .atomic)`，崩溃不会留半截文件；无草稿/恢复机制是既有设计（见第四节）。
- **外部提示不重复**：同一 mtime 三轮询只立一次横幅、不弹窗不刷 notice；「保留本地」后同一磁盘版本不再立起（`repeatedChecks…` / `keepLocalSilences…`）。读失败按 mtime 记 `failedExternalMtime`，同一坏版本只提示一次（既有用例 `unrulyExternalFileIsNotRetriedRepeatedly`）。
- **监视定时器**：`monitorTimer` 只做外部更新轮询（2s，`.common` 模式），不承担自动保存；`deinit` 失效，block 弱引用 self，无循环引用。**本版本无自动保存**。
- **退出守卫必拦**：脏 → 询问；取消 → `.terminateCancel` 且内容不变；丢弃 → 直接退；保存成功才退（`quitGuardBlocksDirty…` 等 6 条）。
- **载入示例置 `.saved`**：与 AC「载入示例不写盘、不置脏」一致（`loadExampleFillsSeedData` 已锁 `!hasUnsavedChanges`），保留；该内容可从菜单原样重建，退出不丢。
- **undo 回退到磁盘状态仍显示 Unsaved**：会话只有 dirty 布尔、无内容比对，属假阳性方向（永不误报「已保存」），接受；记入 1.0 后的内容比对议题。

## 三、断言清单（`Tests/AppTests/SaveStateAuditTests.swift`，12 条）

保存失败 2 条：`failedSaveNeverReportsSaved`、`failedSaveKeepsPreviousFileAndPath`。
外部更新 5 条：`repeatedChecksDoNotRepeatExternalPrompt`、`keepLocalSilencesTheSameDiskVersion`、`failedExternalReloadKeepsProjectOpenAndRecent`、`saveOverPendingExternalUpdateSaysLocalKept`、`externalCheckIsSkippedWhileAsyncOpenInFlight`。
退出守卫 5 条：`quitGuardBlocksDirtyProjectAndCancels`、`quitGuardTerminatesCleanProjectWithoutPrompt`、`quitGuardSavesThenQuits`、`quitGuardCancelsWhenSaveFails`、`quitGuardUsesSavePanelWhenNoPath`。
有效性验证：回滚 B1/B2/B3 后对应用例分别红 5 / 1 / 1 条；把失败路径改成置 `.saved` 后保存类用例红 3 条。

自验：`swift build` 与 `swift build --build-tests` 零告警；`swift test --disable-sandbox --filter 'Save|Workspace|External'` 139 通过；全量 1331 通过。

## 四、1.0 之后（本版本明确不做）

- **自动保存**（定时/失焦保存）与**崩溃恢复草稿**：需要新的落盘位置与生命周期，属新功能。
- **版本历史与三路合并**：当前外部冲突只有「重载 / 保留本地」二选一，无合并。
- 外部更新的内容差异预览、`fsync` 与 mtime 精度兜底（同秒写入漏检）。
- dirty 由「内容比对」判定，消除 undo 回退后的 Unsaved 假阳性。

# Kairo 1.0 发布检查单与回滚预案

> 配套：`docs/release-1.0-scope.md`（范围与准入判据）、`docs/release.md`（签名/公证与产物格式）。
> 用法：逐条勾选；任一条无法勾选即**停止发布**，不允许「先发再补」。

## 0. 冻结

- [ ] 代码冻结：main 上除发版提交外无其他改动；`git status` 干净（`.codebuddy/` 与本地 `.kairo` 除外）。
- [ ] 版本号三处一致：`tools/build.sh`、`Sources/KairoMCP/MCPServer.swift`、`Apps/macos/Sources/CommandRegistry.swift`。
- [ ] CHANGELOG 有 `## v1.0.0` 段，且「不兼容变更」「已知限制」两节非空。

## 1. 门禁（缺一不可）

- [ ] `swift test --disable-sandbox` 全绿，**连续两次**结果一致（排除并行噪声）。
- [ ] `swift build --build-tests -Xswiftc -warnings-as-errors` 零告警。
- [ ] `tools/gate-core.sh`、`tools/gate-ui.sh`、`tools/check-shell-fullwidth.sh`、`tools/gate-i18n.sh` 全通过。
- [ ] 性能复测对照 `docs/perf-1.0.md`：5k 任务 decode ≤1 s；1,000 行翻窗 ≤16.7 ms。
- [ ] `docs/defects.md` 无「待修复」行；顺延项均写明目标版本。
- [ ] 格式三条：v1→v2 迁移、v2 往返、未来版本拒读，用例常绿。

## 2. 产物

- [ ] `bash tools/build.sh` 成功，`dist/Kairo.app` 版本号正确、`codesign -v` 通过（ad-hoc 或 Developer ID）。
- [ ] `dist/KairoCLI --version`、`dist/KairoMCP` 可执行且版本一致。
- [ ] 按 `docs/release.md` 生成 DMG/ZIP/tar.gz 与 `update-manifest.json`；校验 sha256 与本地一致。
- [ ] `SIGNING.txt` 存在且内容如实（本版：**未签名、未公证**）。

## 3. 发布

- [ ] 打 tag `v1.0.0` 并推送；确认 release 工作流 success。
- [ ] Release 说明：顶部「未签名、未公证」横幅 → 本版要点 → 不兼容变更 → 已知限制 → 校验方式。
- [ ] 附件齐全：DMG / ZIP / tar.gz / sha256 / update-manifest / SIGNING.txt。

## 4. 发布后冒烟（在干净用户目录下）

- [ ] 从 DMG 安装到 `/Applications`，首启可打开（未签名需右键打开）。
- [ ] 新建项目 → 建任务 → 排期 → 关键路径/违例显示正常。
- [ ] 建基线 → 甘特出现分轨 → 改任务日期后偏差读数变化。
- [ ] 导出偏差 CSV：11 列、带 BOM、Excel 可开。
- [ ] 语言切到 English 重启：菜单栏全英文（含 File/Edit/View/Window/Help）。
- [ ] 应用内「检查更新」能识别当前为最新版（不误报）。

## 5. 回滚预案

| 场景 | 处置 |
| --- | --- |
| 发版后发现阻断缺陷 | 立刻把该 Release 标记为 **pre-release**（不删除，保留产物供已下载用户校验），在说明顶部加「已知阻断问题 + 建议版本」；修复后发 1.0.1 |
| 产物损坏 / 版本号错 | 删除 Release 与 tag，重新走一遍第 2–3 步；**同号重发前先确认无人下载** |
| 代码需回退 | `git revert <发版提交>` 后发 patch；不回退已发布的 tag（tag 是审计锚点） |
| 用户数据兼容问题 | 1.0 写入的 `formatVersion 2` **不能被 0.12 及更早版本打开**（明确拒读）。降级指引：先在 1.0 里「另存为」留档，再装旧版只读旧文件；不得让旧版覆盖新文件 |
| OTA 误推 | `update-manifest` 回滚到上一版本指针；已安装用户不会自动降级，需手动下载 |

## 6. 决策记录

| 事项 | 结论 | 日期 | 决策人 |
| --- | --- | --- | --- |
| 1.0 范围（含 9 项非目标） | 按 `release-1.0-scope.md` 执行 | 2026-10-26 | lead（用户授权） |
| 签名与公证 | **推迟**，1.0 未签名发布，账号就绪后补发签名版 | 2026-10-26 | 用户 |
| 1000 行翻窗性能 | 已达标（4.9 ms / 16.7 ms 预算），D-038 核销 | 2026-10-25 | lead |

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


**冒烟结果（2026-10-26，v1.0.1，逐项实测）**

| 项 | 结果 | 证据 |
| --- | --- | --- |
| 从 DMG 安装、首启可打开 | ✅ | 挂载 `Kairo-v1.0.1.dmg` → 版本 1.0.1、双架构；`tools/install.sh` 安装后 `pgrep Kairo` 有进程，窗口正常渲染大纲 / 甘特 / 检查器 |
| 基线分轨与偏差读数 | ✅ | 菜单「基线 → 初始基线 → 设为主对比」后，甘特每行出现两条轨道（灰 = 当前计划渐变、青 = 基线）；检查器出现「与基线对比」块。用**副本**把 5.2 时长 2→12 天，读数由 0 变为 **项目结束偏差 +10**，同名任务在导出 CSV 里也是 `planStartVariance/planFinishVariance = 10`（正=晚） |
| 偏差 CSV 在表格软件打开 | ✅（Excel 未装，用两个独立解析器交叉验证） | App 菜单「基线 → 导出偏差 CSV…」→ 保存面板默认名 `kairo-variance.csv` → 写盘 5560 B：`EF BB BF` 开头、3 行基线身份、11 列固定表头、36 行数据每行列数均 11。**Numbers** 打开后 11 列 / 40 行、表头与中文标题原样；**LibreOffice** 转 xlsx 同样 40 行、中文保留；python `csv` 模块解析一致 |
| 语言切英文重启后菜单栏全英文 | ✅（已切回简中） | 切 English → 弹「已切换语言：English / 退出并重新打开…」→ 重启后菜单栏 `Apple, Kairo, File, Edit, View, Task, Workspace, Baseline, Find, Window, Help`，界面 Plan/Outline、Filter tasks、Inspector、状态栏全英文；应用自弹提示也是英文（`Language saved: Chinese (Simplified)`）。最后已切回简体中文并确认菜单栏恢复中文 |
| 应用内「检查更新」不误报 | ✅ | 点「检查更新…」→「当前版本 1.0.1 (Build 20261026.2252)，无需更新。」与服务器 manifest 的 1.0.1 一致 |

未做：Excel 本体（本机未安装），BOM 的 Excel 语义靠字节断言 + Numbers/LibreOffice 双读替代。

## 5. 回滚预案

| 场景 | 处置 |
| --- | --- |
| 发版后发现阻断缺陷 | 立刻把该 Release 标记为 **pre-release**（不删除，保留产物供已下载用户校验），在说明顶部加「已知阻断问题 + 建议版本」；修复后发 1.0.1 |
| 产物损坏 / 版本号错 | 删除 Release 与 tag，重新走一遍第 2–3 步；**同号重发前先确认无人下载** |
| 代码需回退 | `git revert <发版提交>` 后发 patch；不回退已发布的 tag（tag 是审计锚点） |
| 用户数据兼容问题 | 1.0 写入的 `formatVersion 2` **不能被 0.12 及更早版本打开**（明确拒读）。降级指引：先在 1.0 里「另存为」留档，再装旧版只读旧文件；不得让旧版覆盖新文件 |
| OTA 误推 | `update-manifest` 回滚到上一版本指针；已安装用户不会自动降级，需手动下载 |


## 6. 发布记录

| 版本 | 日期 | 结果 | 备注 |
| --- | --- | --- | --- |
| v1.0.0 | 2026-10-26 | 已发布（arm64 only） | 首轮 CI/Release 因用例 `exportWritesBOMAndFixedHeader` 在 runner 上暴露「Foundation 是否保留 BOM」的环境差异而红；修复用例后**同号重发**（未产生任何 Release，无人下载）。产物只含 arm64，Intel Mac 打不开 → 由 v1.0.1 取代。 |
| v1.0.1 | 2026-10-26 | 已发布（universal） | app / CLI / MCP 均为 arm64 + x86_64；DMG / ZIP 各带 `sha256`，另有 `SHA256SUMS`；`update-manifest.json` 的 sha256 与 zip 字节一致（已实测校验）。**Intel Mac 用这个版本。** |

发布后校验（实测命令与结果）：

```bash
gh release download v1.0.1 --repo cygnusyang/Kairo --clobber
shasum -a 256 -c SHA256SUMS            # 三行全 OK
hdiutil attach -nobrowse -readonly Kairo-v1.0.1.dmg
/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' '/Volumes/Kairo v1.0.1/Kairo.app/Contents/Info.plist'   # 1.0.1
file '/Volumes/Kairo v1.0.1/Kairo.app/Contents/MacOS/Kairo'   # universal: x86_64 + arm64
python3 - <<'PY'
import json, hashlib
m = json.load(open('update-manifest.json'))
print(m['sha256'] == hashlib.sha256(open('Kairo-v1.0.1.zip','rb').read()).hexdigest())   # True
PY
```

未覆盖的冒烟项（需人工在 GUI 里看）：新建项目建任务排期、基线分轨偏差读数、偏差 CSV 在 Excel 打开、语言切英文重启后菜单栏全英文、应用内「检查更新」不误报。

## 7. 决策记录

| 事项 | 结论 | 日期 | 决策人 |
| --- | --- | --- | --- |
| 1.0 范围（含 9 项非目标） | 按 `release-1.0-scope.md` 执行 | 2026-10-26 | lead（用户授权） |
| 签名与公证 | **推迟**，1.0 未签名发布，账号就绪后补发签名版 | 2026-10-26 | 用户 |
| 1000 行翻窗性能 | 已达标（4.9 ms / 16.7 ms 预算），D-038 核销 | 2026-10-25 | lead |

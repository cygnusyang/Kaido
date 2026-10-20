# Sprint 7（前置）/ v0.3.0 设计稿 —— 应用内 OTA 更新（KairoUpdater）

> 2026-10-20 · 状态：已实现并发版（v0.3.0 / v0.3.1）
> 参照实现：COFFER `macos/Coffer/Updater/`（~/work/github/coffer，9 文件 1537 行 + 签名工具 + CI 接线）
> 用户指令：把 COFFER 的 OTA 做成标准通用模块，在 Kairo 中支持；编译好的 OTA 产物放到 git 仓库上。

## 1. 通用化改造（与 COFFER 的差异裁定）

| 项 | COFFER | Kairo 裁定 | 理由 |
|---|---|---|---|
| 模块形态 | App 内目录 | 独立库 target `KairoUpdater`（Apple 平台门禁） | 「标准通用模块」要求；appId/公钥/feed/白名单全部 init 注入 |
| 验签层级 | 三级（DR anchor apple generic + TeamID + CDHash） | 两级（identifier + CDHash） | Kairo 为 ad-hoc 签名，无 TeamID；CDHash 由 CI 对实际产物提取并签名锚定 |
| 安装载体 | 嵌套 helper .app（沙盒 App 不能写 /Applications） | detached bash 脚本 | Kairo 非沙盒；替换协议（等退出→备份→替换→relaunch→result 握手）与守卫不变 |
| 诊断日志 | DiagLog | 注入式 logger（默认 os.log） | 解耦 |
| 自动检查 | 无（零网络姿态裁定） | 启动 5s + 每 4h 静默检查（v0.3.1 用户指令） | 用户显式要求；静默语义 = 失败不弹面板、发现新版才弹、同版本去重 |
| 跳过版本 | UpdateCopy（UI 层） | UpdaterManager 内建 `skipCurrentUpdate()` | 语义一致（securityCritical 禁跳） |

## 2. 安全模型

1. **签名链**：CI 私钥（secret `UPDATE_SIGNING_KEY_BASE64`，永不落仓）→ canonical JSON（去 signature，sortedKeys + withoutEscapingSlashes）→ Ed25519 → 清单。App 侧公钥硬编码 `UpdaterConfiguration.updatePublicKeyBase64`。
2. **公钥门禁（H-2 同构）**：CI 从源码常量提取公钥复验刚签的清单——私钥/公钥漂移即发版失败（`tools/verify_update_manifest.swift`）。
3. **四级产物校验**：白名单端点 → 清单验签 → zip SHA256 → 解压后 identifier + CDHash。全部 fail-closed。
4. **防降级**：`minimumVersion` 地板（CI env `OTA_MINIMUM_VERSION=0.2.0`，只增不减人工复核）。
5. **网络层**：请求前 URL 校验 + challenge 兜底 + 重定向逐跳白名单 + URLCache 禁用（BUG-28 同款：缓存旧 manifest 会致 CDHash 误报）。

## 3. 替换协议（detached 脚本）

`InstallerScript.replacement` 生成脚本：等当前 pid 退出（0.2s × 300 上限）→ `mv` 备份（`Kairo-<stamp>.app`）→ `cp -R` 替换 → `open` relaunch → 写 result JSON（0=成功 / 1=已装但自动启动失败 / 2=安装失败已回滚 / 3=备份失败 / 4=等待退出超时）。路径全部单引号包裹；消费侧目录前缀 + 文件名形状双守卫（fail-closed 不误删）。

## 4. CI 接线（release.yml）

secrets 校验 → 构建 → OTA 载体 zip（ditto，SHA256 入 env）→ `extract_cdhash.sh` 提取 CDHash → `sign_update_manifest.sh` 签清单 → 公钥门禁验签 → DMG → Release 三附件（dmg/zip/manifest）→ **artifacts 分支归档**（`<tag>/` + `latest/` 镜像，强制添加绕过 gitignore）。

## 5. 测试与验证

- 单测 27 条（`Tests/KairoUpdaterTests` + `UpdaterConfigurationTests`）：验签往返/篡改拒绝/缺签名/错钥、清单解析 fail-closed、白名单（含前缀伪装域拒绝）、SHA256 标准向量、状态机全迁移（stub 注入不联网）、脚本契约真机跑（备份+替换+result 握手）、启动路径错位拦截、配置自洽。
- 本机端到端：临时密钥走完整签名→验签链路 VALID。
- 发版实测（v0.3.0）：CI 一次通过；latest feed 拉取 + 真实公钥验签 VALID；v0.3.1 起补 artifacts 分支归档。

## 6. 已知限制与后续

- v0.2.0 及更早无 OTA 客户端（需手动装一次 v0.3.0+）。
- ad-hoc 签名期间产物验签无 TeamID 主锚；换证书后加回 DR 一级。
- 自动检查失败无横幅（避免打扰），手动面板可见失败态。

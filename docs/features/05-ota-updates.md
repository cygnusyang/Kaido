# US-E7-01 应用内 OTA 更新（KairoUpdater）

> 状态：完成（v0.3.0 初版 / v0.3.1 自动检查）· 2026-10-20
> 设计决策记录：[../archive/Sprint7-ota-updates/design.md](../archive/Sprint7-ota-updates/design.md)（移植自 COFFER OTA 的裁定与差异）

## 1. 目标

用户无需手动下载安装包，应用内即可发现新版本、验证安全性并完成升级。升级通道的安全模型与 COFFER OTA 同构（Ed25519 签名清单 + 多级校验 + 白名单），实现为独立通用模块 `KairoUpdater`，可复用于其他 Apple 平台项目。

## 2. 规格

### F-36-01 更新检查

- 入口：应用菜单「检查更新…」（手动，同步打开更新面板）。
- 自动检查：启动后 5 秒静默检查一次；此后每 4 小时一次（`UpdaterConfiguration.autoCheck*`）。
- 静默语义：自动检查的网络失败**不弹面板**（状态留在 `UpdaterManager`，手动检查可见）；仅「发现新版本且未被跳过」时自动展示更新面板，同版本一次运行只弹一次。
- Feed：`https://github.com/cygnusyang/Kairo/releases/latest/download/update-manifest.json`（GitHub latest 永久链接，清单随每个 Release 重传即完成 feed 更新）。

### F-36-02 更新清单与验签

- schema v1 字段：`schemaVersion / appId / version / minimumVersion / buildTime / downloadUrl / cdHash / securityCritical / notes? / sha256? / signature`。
- 签名：Ed25519（CryptoKit），被签内容 = 去除 `signature` 后的 canonical JSON（`JSONSerialization + .sortedKeys + .withoutEscapingSlashes`，无缩进；签名工具与 App 验签双侧同实现）。
- 密钥纪律：私钥只存 GitHub secret `UPDATE_SIGNING_KEY_BASE64`，永不进仓库；公钥硬编码于 `UpdaterConfiguration.updatePublicKeyBase64`；CI 有「从源码常量提取公钥复验签名」门禁，密钥漂移即发版失败。

### F-36-03 下载与产物校验（四级，全部 fail-closed）

1. 端点白名单：强制 HTTPS + host 白名单（github.com / api.github.com / objects.githubusercontent.com / release-assets.githubusercontent.com），重定向逐跳复核，URL 缓存禁用。
2. 清单验签：canonical JSON + Ed25519。
3. 下载完整性：zip SHA256 与清单 `sha256` 比对（流式计算）。
4. 产物验签：解压后 `.app` 的 bundle identifier 复核 + `kSecCodeInfoUnique` CDHash 与清单比对（清单由 CI 对实际产物提取并签名锚定，构成「合法签名但非官方构建」防线）。

### F-36-04 安装

- 唯一入口：`.downloaded` 态确认弹窗（「退出并安装」）。
- 替换协议（非沙盒 detached bash 脚本）：等待当前进程退出（上限 60s）→ 备份 → 替换 → relaunch → 写 result JSON；失败自动回滚备份。
- 结果握手：重启后 App 消费 result 文件（成功删备份静默；失败呈现退出码与文案）；路径守卫（目录前缀 + 文件名形状双校验）防误删。
- 启动路径错位拦截：从非安装位置（如 build 副本）运行时 fail-fast 拒绝更新。

### F-36-05 版本判定与跳过

- 版本比较：点分数字，缺组件按 0 补齐；非数字 fail-closed。
- 防降级：当前版本低于清单 `minimumVersion` 拒装（CI env `OTA_MINIMUM_VERSION`，只增不减）。
- 跳过版本：`skipCurrentUpdate()` 持久化；同版本静默，严格更新版本重新提示；`securityCritical: true` 的版本禁跳。

### F-36-06 产物分发

- GitHub Release 附件三件：`Kairo-vX.Y.Z.dmg`（人装）、`Kairo-vX.Y.Z.zip`（OTA 载体）、`update-manifest.json`（feed）。
- 仓库归档：`artifacts` 分支按 tag 子目录 + `latest/` 镜像保存全部产物（CI 自动提交）。

## 3. 已知限制

- v0.2.0 及更早版本无 OTA 客户端，需手动安装 v0.3.0+ 一次。
- ad-hoc 签名（无 Apple 证书）：产物验签为 identifier + CDHash 两级；换发开发者证书后应在 `AppProductVerifier` 加回 DR（anchor apple generic + TeamID）一级。
- 自动检查失败无横幅提醒（避免打扰），可在「检查更新…」面板看到失败态。

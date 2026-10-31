# Kaido（原 Kairo）Mac App Store 上架 · 交接单

> 2026-10-31 记录。上一会话上下文用尽前留下，供后续会话直接接手。

## 一、当前位置

| 项 | 状态 |
|---|---|
| 品牌 | **Kaido**（App Store 名称 **Kaido Plan**，已验证可用） |
| 代码分支 | `refactor/rename-zeno`（提交 `48d4f48`，**尚未合并 main**） |
| 改名范围 | 15 个目录 + 26 个文件 `git mv`；5383 处引用替换；`KaidoMacApp` 编译 0 error |
| bundle id | `top.cygnusyang.kaido`（门户 App ID 已注册一致） |
| 扩展名 / CLI | `.kaido` / `kaido` |
| App Store Connect | App 记录已建（Kaido Plan / 简体中文 / SKU `kaido-macos`） |
| provisioning profile | `~/kairo-signing/KaidoPlanMAS.provisionprofile` |

## 二、签名材料（仓库外，禁止入库）

```
~/kairo-signing/
  apple_distribution.p12        Apple Distribution（签 .app）
  all-identities.p12            含 3rd Party Mac Developer Installer（签 .pkg）
  KaidoPlanMAS.provisionprofile Mac App Store profile
  p12-password.txt              上述 p12 的密码
```

`tools/gate-secrets.sh` 会拦截把这类文件提交进仓库；CI 用 GitHub Secrets 注入。

## 三、待办（按依赖顺序）

1. **合并** `refactor/rename-zeno` → main（先跑全量测试）
2. **沙盒收尾**：最近项目 / 会话恢复改 security-scoped bookmark（`Kaido.entitlements` 已含三项权限）
3. **`tools/build-mas.sh`**：MAS 变体——编译开关禁用自更新（`KaidoUpdater` 会起进程自替换，商店必拒）、去掉 CLI/MCP 安装入口；产物进 `dist-mas/`
4. **回归**：`swift test` 全量 + `bash tools/gate-i18n.sh`
5. **出包上传**：
   ```bash
   tools/sign-mas.sh --app dist-mas/Kaido.app \
     --entitlements Apps/macos/Resources/Kaido.entitlements \
     --provisionprofile ~/kairo-signing/KaidoPlanMAS.provisionprofile \
     --pkg-out dist-mas/Kaido.pkg
   xcrun altool --upload-app -f dist-mas/Kaido.pkg -t macos
   ```
6. **提审**：元数据、Mac 截图（1280×800 / 1440×900）、隐私清单、文件访问用途说明

## 四、已知坑

- **签名身份不在登录钥匙串**：Apple Distribution 用 `apple_distribution.p12`（配套 `developerID.key`），Installer 在 `all-identities.p12`；签名前导入临时钥匙串并用 `KAIRO_KEYCHAIN` 指定，跑完删除。
- **改名破坏兼容**：老 `.kairo` 文件与新 `.kaido` 不通用，建议兼容读 `.kairo`。
- **已发布 v1.5.1 是旧 bundle id**（`app.kairo.macos`），装了旧版的机器不会自动升级到新 id。
- `git stash list` 里的 `wip-rename-ordo` 可删。

## 五、新会话开场

> 继续 Kaido 上架：分支 `refactor/rename-zeno` 待合 main（改名完成、编译通过）。之后做沙盒 bookmark、`build-mas.sh`（禁用自更新）、全量测试，用 `~/kairo-signing/KaidoPlanMAS.provisionprofile` 出 `.pkg` 并上传 App Store Connect。

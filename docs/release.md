# 发版与签名（release）

> 适用：v0.16.0 起的发布链路 · 文档口径核对于 2026-10-25（macOS 27.0.1 / Swift 6.3.1 / Xcode 16+ / notarytool 1.1.1）
> 权威实现：[.github/workflows/release.yml](../.github/workflows/release.yml)、[tools/release.sh](../tools/release.sh)、[tools/package.sh](../tools/package.sh)、[tools/build.sh](../tools/build.sh)

## 0. 现状：当前产物未签名、未公证

先把话说清楚，避免把「链路支持签名」读成「产物已签名」：

| 事实 | 证据 |
|---|---|
| 仓库未配置 Developer ID 凭据（`MACOS_CERT_P12` 等 5 个 secret 为空） | `gh secret list` 实测只有 `UPDATE_SIGNING_KEY_BASE64`，无任何 `MACOS_CERT_*` / `NOTARY_*` |
| 本地构建产物是 ad-hoc 签名（`codesign --sign -`，由 `tools/build.sh` 做），**未公证** | 见下实测输出 |
| 已发布的 DMG / zip 均为未签名、未公证 | `dist/` 历史产物实测一致 |

本机实测（v0.16.0 开发机，未签名状态）：

```console
$ codesign -dv --verbose=4 dist/Zeno.app
Executable=.../dist/Zeno.app/Contents/MacOS/Zeno
Identifier=app.zeno.macos
CodeDirectory v=20400 size=16488 flags=0x2(adhoc) hashes=509+3 location=embedded
...
CDHash=51d841c71f8ef587910cb18e4c995cb3a15ec3f4
Signature=adhoc

$ codesign --verify --strict --verbose=2 dist/Zeno.app
dist/Zeno.app: valid on disk
dist/Zeno.app: satisfies its Designated Requirement
# 退出码 0 —— ad-hoc 签名对 codesign 而言「结构完整」，但这不代表能过 Gatekeeper

$ spctl -a -vvv -t exec dist/Zeno.app
dist/Zeno.app: rejected
# 退出码 3 —— 这才是用户机器上的真实结果

$ codesign -dv dist/Zeno-v0.9.0.dmg
dist/Zeno-v0.9.0.dmg: code object is not signed at all

$ spctl -a -t open --context context:primary-signature -v dist/Zeno-v0.9.0.dmg
dist/Zeno-v0.9.0.dmg: rejected
source=no usable signature

$ xcrun stapler validate dist/Zeno-v0.9.0.dmg
Zeno-v0.9.0.dmg does not have a ticket stapled to it.
# 退出码 65
```

**两个容易踩的判读坑**（都实测过）：

1. `codesign --verify` 通过 ≠ 能安装。ad-hoc 包也会返回 0，必须看 `spctl`。
2. `xcrun stapler validate` **无票据时退出码是 65、输出一行 "does not have a ticket stapled to it."**，判定要看文字 + 退出码，别只看其中一个。

## 1. 签名三态：workflow 怎么决定

`.github/workflows/release.yml` 的 `判定签名与公证方式` 步骤读 5 个 secret，只有两种合法结局：

| secret 状态 | `SIGNING_MODE` | 行为 | 产物标注 |
|---|---|---|---|
| 5 个全空 | `adhoc` | ad-hoc 发布照常进行，不阻断 | Release 说明顶部加「未签名」提示；`SIGNING.txt` 写「未签名（ad-hoc），未公证」 |
| 5 个齐全 | `developer-id` | 签 App → 公证并装订 App → 打包 → 签 DMG → 公证并装订 DMG → 签 CLI/MCP | `SIGNING.txt` 写签名身份 + 公证结论 |
| 只配了一部分 | — | **直接失败**，报出缺哪几个 secret | 无产物 |

第三种为什么是失败而不是降级：签了名但不公证的包在用户机器上照样被 Gatekeeper 拦（`source=Unnotarized Developer ID`），而「看起来签过」比「明确未签名」更难排查。要发就发完整链，否则一个都别配。

`SIGNING.txt` 会同时出现在三处：Release 附件、`artifacts` 分支的 `<tag>/` 与 `latest/`。这是「产物自述状态」的唯一落盘位置，排障先看它。

## 2. 需要配置的 secrets

在 GitHub 仓库 Settings → Secrets and variables → Actions 添加（或用 `gh secret set`）。

| Secret | 内容 | 怎么生成 |
|---|---|---|
| `MACOS_CERT_P12` | Developer ID **Application** 证书 + 私钥的 .p12，base64 编码 | 钥匙串访问导出 .p12（设密码）→ `base64 -i DeveloperID.p12 \| pbcopy`，粘贴为 secret 值 |
| `MACOS_CERT_PASSWORD` | 上面 .p12 的密码 | 导出时设定 |
| `NOTARY_APPLE_ID` | 公证用的 Apple ID 邮箱 | — |
| `NOTARY_PASSWORD` | 该 Apple ID 的 **app 专用密码**（不是登录密码） | appleid.apple.com → 登录与安全 → App 专用密码 → 生成 |
| `NOTARY_TEAM_ID` | 10 位 Team ID | developer.apple.com → 会员详情页 |
| `UPDATE_SIGNING_KEY_BASE64` | OTA 清单 Ed25519 私钥（已有，与签名无关但同样必填） | 见 [tools/sign_update_manifest.sh](../tools/sign_update_manifest.sh) 头部注释 |

自查（前提：`gh` 已登录且对该仓库有 admin 权限；只显示名称与更新时间，不显示值）：

```bash
gh secret list
```

期望：列出上述名称。缺 `MACOS_CERT_P12` 就是未签名路径；只缺其中一两个则是「配置不完整」，发版会红。
撰写本文时的实测输出只有一行 `UPDATE_SIGNING_KEY_BASE64`——即当前是**未签名**路径（与 §0 一致）。

前提：Developer ID Application 证书需要 Apple Developer Program 付费会员，且证书私钥只能从有该证书的机器导出。

## 3. 本地发版：只产出未签名包

```bash
tools/release.sh 0.17.0 --dry-run   # 校验 + 改版本号 + 测试 + 打包，不提交不推送
tools/release.sh 0.17.0             # 完整发版：提交 + 打 tag + 推送，由 CI 出正式产物
```

本脚本**不做签名、不做公证**：`tools/build.sh` 用 `codesign --sign -` 做 ad-hoc 签名（只为本地能打开），
`Developer ID` 凭据只在 CI secret 里。产物真实状态写在 `dist/SIGNING.txt`，并且脚本会把状态打到 stdout：

```console
==> 本地产物签名状态：未签名（ad-hoc），未公证
    对外分发请以 CI 产物为准，签名/公证验证见 docs/release.md
```

判定本地产物（在仓库根目录）：

```bash
codesign -dv --verbose=4 dist/Zeno.app 2>&1 | grep -E 'flags=|Signature='
# ad-hoc 时：flags=0x2(adhoc) 与 Signature=adhoc
```

### 3.1 前置：本机必须有 Xcode（不是只有 Command Line Tools）

多语言门禁与打包都用 Xcode 自带的 `xcstringstool`。只装 Command Line Tools 的机器上脚本会在第一道门就停下：

```console
$ tools/release.sh 1.3.3
==> 校验前置条件
ERROR: 找不到 xcstringstool，多语言门禁与打包无法在本机执行（xcode-select -p → /Library/Developer/CommandLineTools）。二选一：
  1) 装 Xcode 后执行：sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  2) 跳过本机发版，直接推 tag 让 CI 跑同一条门禁：
       git tag -a v1.3.3 -m "Zeno v1.3.3" && git push origin refs/tags/v1.3.3
```

确认可用：

```bash
xcode-select -p                 # 应指向 /Applications/Xcode.app/Contents/Developer
xcrun --find xcstringstool      # 应打印路径，而不是 "unable to find utility"
```

### 3.2 幂等：版本号与 CHANGELOG 已就绪时可以重跑

第 4 步只在「版本号 / CHANGELOG 确有改动」时提交；已在前序提交里同步好（例如先补 CHANGELOG 再发版）时打印
`无可提交改动（跳过提交）` 后继续打 tag。tag 已存在时脚本仍会拒绝重发——若上次中断在推送前，按提示手动 `git push origin refs/tags/vX.Y.Z` 收口。

## 4. 在有证书的机器上验证签名与公证（逐步）

> **本文这一节尚未实跑验证**：撰写时手上没有 Developer ID 凭证，本机只跑过「未签名」路径。
> 命令与断言按 CI 的实际步骤编写（同源），第一次真跑请逐条对照，把实际输出回填本文。
>
> 前提清单：Apple Developer Program 会员 + Developer ID Application 证书（含私钥）/ 已导出 .p12 且知道密码 / 已生成 app 专用密码 / 知道 Team ID / macOS 14+ 与 Xcode 16+（提供 `notarytool`、`stapler`）。
>
> 下面 4.1–4.9 请在**同一个 shell 会话**里按顺序执行：命令之间有变量沿用（`ORIG_DEFAULT`、`SIGN_IDENTITY`、`TAG`）。

### 4.1 环境自检

```bash
xcode-select -p                  # 期望：/Applications/Xcode.app/Contents/Developer
xcrun --find notarytool          # 期望：打印 notarytool 路径
xcrun notarytool --version       # 实测：1.1.1 (40)
```

公证凭据从环境变量读，先设好（密码用 `read -rs` 读，不回显、不进 shell 历史）：

```bash
export NOTARY_APPLE_ID='<你的 Apple ID 邮箱>'
export NOTARY_TEAM_ID='<10 位 Team ID>'
read -rs NOTARY_PASSWORD && export NOTARY_PASSWORD   # 粘贴 app 专用密码后回车
```

### 4.2 导入证书到临时钥匙串（用完即删）

```bash
# 记住原默认钥匙串，结束时恢复
ORIG_DEFAULT="$(security default-keychain | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//')"
KEYCHAIN=zeno-sign.keychain

security create-keychain -p zeno "$KEYCHAIN"
security set-keychain-settings -lut 3600 "$KEYCHAIN"
security unlock-keychain -p zeno "$KEYCHAIN"
security default-keychain -s "$KEYCHAIN"

# 只把私钥使用权限授予 codesign，不授予任意进程
security import DeveloperID.p12 -k "$KEYCHAIN" -P '<p12 密码>' -T /usr/bin/codesign
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k zeno "$KEYCHAIN"

# -v 只列「有效」身份：证书过期/被吊销时这里为空
security find-identity -v -p codesigning "$KEYCHAIN"
```

期望输出（形状）：`1) <HASH> "Developer ID Application: <公司或个人名> (<TEAMID>)"`

陷阱：空钥匙串时这条命令**不会报错**，而是打印 `0 valid identities found` 且退出码 0（本地实测）。所以要看输出内容，不要只看退出码。

取签名身份：

```bash
SIGN_IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" \
  | sed -n 's/.*"\(Developer ID Application[^"]*\)".*/\1/p' | head -1)"
echo "$SIGN_IDENTITY"
```

### 4.3 构建并签名 App

```bash
bash tools/build.sh        # 先出 ad-hoc 包，随后被 Developer ID 覆盖；与 CI 顺序一致
codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" dist/Zeno.app
codesign --verify --strict --verbose=2 dist/Zeno.app
```

期望：`dist/Zeno.app: valid on disk` + `dist/Zeno.app: satisfies its Designated Requirement`。

### 4.4 断言 Hardened Runtime 与证书（CI 同款硬门禁）

```bash
codesign -dv --verbose=4 dist/Zeno.app 2>&1 | grep -E 'flags=|^(Authority|TeamIdentifier|Timestamp)='
```

期望（形状，关键字段）：

```text
CodeDirectory ... flags=0x10000(runtime) ...
Authority=Developer ID Application: <名称> (<TEAMID>)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
TeamIdentifier=<TEAMID>
Timestamp=<签名时间>
```

`flags` 必须是 `0x10000(runtime)`；`0x2(adhoc)` 表示还是未签名包（此时同一条命令还会打出 `TeamIdentifier=not set`，可作为一眼判据）。证书必须是 `Developer ID Application`——`Apple Development` / 自签证书无法公证。

### 4.5 公证并装订 **App**（OTA 的前置条件）

顺序不能省：OTA 的 `.zip` 无法 staple，票据必须先进 App 再打包，否则更新包在离线首次启动时仍会被 Gatekeeper 拦。

```bash
ditto -c -k --keepParent dist/Zeno.app /tmp/Zeno-notarize.zip

xcrun notarytool submit /tmp/Zeno-notarize.zip \
  --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" \
  --wait

xcrun stapler staple dist/Zeno.app
xcrun stapler validate dist/Zeno.app     # 期望：The validate action worked!（退出码 0）
spctl -a -vvv -t exec dist/Zeno.app      # 期望：accepted / source=Notarized Developer ID
```

`notarytool submit` 期望结尾：`status: Accepted` 与 `id: <uuid>`。若 `status: Invalid`，拿 `id` 下载日志再修（见 §9）。

### 4.6 打包、签 DMG、公证并装订

```bash
TAG=v0.17.0
bash tools/package.sh "$TAG" --skip-build --out .

codesign --force --timestamp --sign "$SIGN_IDENTITY" "Zeno-$TAG.dmg"
codesign --verify --strict --verbose=2 "Zeno-$TAG.dmg"

xcrun notarytool submit "Zeno-$TAG.dmg" \
  --apple-id "$NOTARY_APPLE_ID" --password "$NOTARY_PASSWORD" --team-id "$NOTARY_TEAM_ID" \
  --wait

xcrun stapler staple "Zeno-$TAG.dmg"
xcrun stapler validate "Zeno-$TAG.dmg"    # 期望：worked!（退出码 0）
spctl -a -t open --context context:primary-signature -v "Zeno-$TAG.dmg"
# 期望：accepted / source=Notarized Developer ID
```

### 4.7 验 OTA zip 里的 App 也带票据（最容易漏的一步）

```bash
rm -rf /tmp/ota-check && mkdir -p /tmp/ota-check
ditto -x -k "Zeno-$TAG.zip" /tmp/ota-check
xcrun stapler validate /tmp/ota-check/Zeno.app   # 期望：worked!（退出码 0）
codesign -dv --verbose=4 /tmp/ota-check/Zeno.app 2>&1 | grep -E 'flags=|Authority=Developer ID'
```

### 4.8 清单 CDHash 与新签名一致

```bash
tools/extract_cdhash.sh                              # 实测：直接打印 40 位 hex，无前缀
codesign -dv --verbose=4 dist/Zeno.app 2>&1 | grep '^CDHash='
```

期望：两条 hex 完全相同（staple 不改签名，但 CDHash 必须在所有签名动作之后提取——CI 已把取 CDHash 放在最后）。

### 4.9 收尾

```bash
security default-keychain -s "$ORIG_DEFAULT"
security delete-keychain zeno-sign.keychain
rm -f /tmp/Zeno-notarize.zip
```

## 5. 下载侧验证（任何一台 Mac，不需要证书）

用户/维护者拿到 Release 附件后的四步，全部只看输出：

```bash
shasum -a 256 Zeno-v0.17.0.dmg          # 与 SIGNING.txt / 发布说明里的值比
spctl -a -t open --context context:primary-signature -v Zeno-v0.17.0.dmg
xcrun stapler validate Zeno-v0.17.0.dmg
ditto -x -k Zeno-v0.17.0.zip /tmp/ota && xcrun stapler validate /tmp/ota/Zeno.app
```

判定表：

| 现象 | 结论 |
|---|---|
| `accepted` + `source=Notarized Developer ID`；`stapler validate` 输出 worked!（退出 0） | 已签名、已公证、票据已装订 |
| `rejected` + `source=no usable signature`；DMG 上 `codesign -dv` 报 `not signed at all` | 未签名（当前常态，见 §0） |
| `rejected` + `source=Unnotarized Developer ID` | 已签名但**未公证**（配置不完整或被绕过） |
| `accepted` 但 `stapler validate` 报 `does not have a ticket stapled to it.`（退出 65） | 已公证但未装订：联网能装，离线首次启动可能被拦 |
| 下载后改过 zip 内容 | 签名与票据一并失效，不要在这种包上做判断 |

CLI / MCP 二进制（tar.gz 无法装订票据，只验签名）：

```bash
tar -xzf zeno-v0.17.0-macos-universal.tar.gz -C /tmp
codesign -dv --verbose=4 /tmp/zeno-v0.17.0-macos-universal/bin/zeno 2>&1 | grep -E 'flags=|Authority=Developer ID'
```

## 6. 1.0 发版前置清单

逐条勾完再打 tag；任何一条不满足就不发。

- [ ] 版本号三处同步（`tools/release.sh` 自动改 `tools/build.sh` / `MCPServer.swift` / `CommandRegistry.swift`），产物内版本 = tag（`tools/package.sh` 门禁）
- [ ] `CHANGELOG.md` 有 `## vX.Y.Z` 章节（缺了 `release.sh` 直接拒发）
- [ ] 门禁通过：`gate-core` / `gate-ui` / `check-shell-fullwidth` / `gate-i18n` / `i18n-lint-selftest`
- [ ] 两端测试通过：macOS（含 AppTests、ZenoUpdaterTests）+ Linux（核心与接口层）；两侧 `swift build -Xswiftc -warnings-as-errors` 均为 0 warning
- [ ] `UPDATE_SIGNING_KEY_BASE64` 存在，公钥复验步骤通过（CI 从源码常量取公钥复验签名）
- [ ] 签名决策明确：要么 5 个 secret 齐全走完整链，要么在 Release 说明里写明 1.0 不签名并给出安装指引（**不允许含糊**）
- [ ] 若签名：`notarytool` 两次提交都是 `Accepted`；App 与 DMG 均 `stapler validate` worked
- [ ] 若签名：OTA zip 内 App 也带票据（§4.7）
- [ ] `SIGNING.txt` 在 Release 附件与 `artifacts` 分支都存在，内容与实测一致
- [ ] 按 §5 用下载侧命令复验一遍（模拟用户，不依赖本机钥匙串）
- [ ] 1.0 是制品面向公众的门槛：建议届时把「未签名也能发」改成硬门禁（见 §7）

## 7. 尚未实施的建议：1.0 起签名硬门禁

现状是「没凭据也能发未签名版」，这对 0.x 合理，对 1.0 不合适。建议在 1.0 前加一个仓库变量（如 `REQUIRE_SIGNED=true`），在 `判定签名与公证方式` 步骤里：变量为真且 secret 不全时直接失败。

**本条未实施**——它会立刻让当前（无凭据）的发版路径变红，需要与发版节奏一起决定，故只作为 1.0 的决策项记录在此。

## 8. Linux CI 与本地 macOS 的口径差异

| 项 | `ci.yml` macOS | `ci.yml` Linux | `release.yml`（macos-14） |
|---|---|---|---|
| 工具链 | setup-xcode latest-stable | 容器 `swift:6.0-jammy` | setup-xcode latest-stable |
| 测试 target | ZenoCoreTests、ZenoPresentationTests、InterfaceTests、AppTests、ZenoUpdaterTests | 前三个 | 同 macOS（全量） |
| warnings-as-errors | **是**（`swift build -Xswiftc -warnings-as-errors`，产出目标） | **是**（同左） | **是**（`build.sh` + 通用二进制） |
| `swift test` | 全量（含 AppTests / Updater） | 核心与接口层 | 全量 |
| `gate-core` | 是 | 是 | **是**（新增，与 CI 同源） |
| `gate-ui` / 全角检查 / `gate-i18n` / i18n 自测 | 是 | 否 | **是**（新增） |
| 签名/公证 | — | — | 按 secret 三态（§1） |

差异的原因与边界：

- **AppTests / ZenoUpdaterTests 天然只在 macOS**：`Package.swift` 用 `#if os(macOS)` 声明这些 target（`ZenoUpdater` 依赖 Security/CryptoKit）。Linux 上不存在「漏跑」问题，但也意味着 **GUI 与 OTA 逻辑不能只靠 Linux 绿**。
- **Linux 容器是 Swift 6.0，本地是 6.3.1**：方言差异（新警告、并发检查）只在 CI 才暴露；本轮已在 `swift:6.0-jammy` 里实跑 `swift build --build-tests -Xswiftc -warnings-as-errors`，结果 0 warning、构建通过。
- **warnings-as-errors 只管产出目标，不管 test target**：这是本轮的选择。原因很具体——把该 flag 加到 `swift test` 上，干净检出的 CI 会立刻红在 `Tests/AppTests/OutlineSelectionAcceptanceTests.swift:74`（`try #require(rows.first)` 的返回值未使用，`[#no-usage]`）。修复它属于测试代码改动，不在发布链路任务范围内，已作为待办记录；在那之前不要让发布门禁依赖它。
- **本地 `release.sh` 用 `swift test --disable-sandbox`，CI 不用**：本地沙箱限制导致 SwiftPM 沙箱失败，CI 无此问题。除此之外两端命令一致。
- `gate-i18n` 依赖 `xcstringstool`（Xcode 自带），Linux 无法执行，故只放在 macOS 与 release 两侧。

## 9. 故障处理

| 现象 | 处置 |
|---|---|
| `notarytool` 返回 `status: Invalid` | `xcrun notarytool log <id> --apple-id … --password … --team-id …` 取日志。常见原因：嵌套可执行文件未签、未开 Hardened Runtime、用了 Development 证书、`LSMinimumSystemVersion` 缺失 |
| `security import` 报 `MAC verification failed` | `MACOS_CERT_PASSWORD` 与 p12 不匹配（导出时设的密码） |
| `find-identity` 为空但有证书 | 证书过期/被吊销，或证书在别的钥匙串（`security find-identity -v -p codesigning` 查全部） |
| `spctl` 拒绝已签名包 | 看 `source=`：`Unnotarized Developer ID` → 缺公证；`no usable signature` → 签名被后续操作破坏（改包后重新打包/改 zip 内容） |
| `stapler validate` 退出 65 | 无票据：漏了 staple，或 staple 后又改了包内容 |
| 用户仍报「无法验证开发者」 | 让用户跑 `xattr -dr com.apple.quarantine /Applications/Zeno.app`；若是 OTA 包被拦，回头查 §4.7 |

## 10. 已知限制

- **tar.gz 无法装订票据**：CLI/MCP 二进制已签名，但首次运行依赖在线校验；离线环境首次运行可能被拦。
- **DMG 与 zip 是两份独立产物**：只验 DMG 不够，OTA 走 zip，必须按 §4.7 单独验。
- **公证依赖 Apple 服务**：CI 里 `--wait` 无超时上限设置，网络异常时可能长时间等待（未加超时/重试，属已知缺口）。
- **未签名路径无法验证签名链**：本文 §4/§5 的签名分支命令按 CI 编写但**未实跑**，只有 §0/§3 的未签名输出是实测的。
- **Linux 侧不覆盖 GUI 与 Updater**：见 §8。

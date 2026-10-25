#!/usr/bin/env bash
# tools/release.sh —— 一条命令完成发版：校验 → 改版本号 → 测试 → 打包（DMG + OTA zip）→ 提交 → 打 tag → 推送。
#
# 推送 tag 后由 GitHub Actions（.github/workflows/release.yml）复跑测试、重新打包、
# 签名 update-manifest.json、归档 artifacts 分支并从 CHANGELOG 生成 Release 说明。
#
# 前置：CHANGELOG.md 里已经写好「## vX.Y.Z — YYYY-MM-DD」章节（脚本不替你写 changelog，
# 只负责把它放到 Release 上）。
#
# 签名：本脚本只做本机构建，产物是 tools/build.sh 的 ad-hoc 签名，**未公证**。
# Developer ID 凭据只在 CI secret 里，正式签名/公证由 .github/workflows/release.yml 完成。
# 产物的真实签名状态写到 dist/SIGNING.txt，对外分发以 CI 产物为准（docs/release.md）。
#
# 用法:
#   tools/release.sh 0.8.3            # 完整发版
#   tools/release.sh 0.8.3 --dry-run  # 只跑校验 + 改版本号 + 测试 + 打包，不提交不推送
#   tools/release.sh 0.8.3 --skip-tests
#   tools/release.sh 0.8.3 --no-push  # 提交并打 tag，但不推送
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<USAGE
用法: $(basename "$0") <版本号，如 0.8.3> [选项]

选项:
  --dry-run      只做校验、改版本号、测试与打包，不提交、不打 tag、不推送
  --skip-tests   跳过 swift test（不推荐：合主干前必须全绿）
  --no-push      提交并打 tag，但不推送
  -h, --help     显示帮助
USAGE
}

RAW_VERSION=""
DRY_RUN=0
SKIP_TESTS=0
PUSH=1
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --skip-tests) SKIP_TESTS=1; shift ;;
    --no-push) PUSH=0; shift ;;
    -h|--help) usage; exit 0 ;;
    -*) echo "未知参数: $1" >&2; usage >&2; exit 2 ;;
    *)
      if [[ -n "$RAW_VERSION" ]]; then echo "多余参数: $1" >&2; exit 2; fi
      RAW_VERSION="$1"; shift ;;
  esac
done

if [[ -z "$RAW_VERSION" ]]; then usage >&2; exit 2; fi
VERSION="${RAW_VERSION#v}"
TAG="v${VERSION}"
if [[ ! "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "版本号格式应为 X.Y.Z（可带 v 前缀），收到: $RAW_VERSION" >&2
  exit 2
fi

fail() { echo "ERROR: $*" >&2; exit 1; }

# ---------- 1. 前置校验（失败要趁早，别改完文件才发现） ----------
echo "==> 校验前置条件"

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
[[ "$BRANCH" == "main" ]] || fail "必须在 main 上发版，当前分支: $BRANCH"

if ! git diff --quiet || ! git diff --cached --quiet; then
  fail "工作区有未提交改动，先提交或 stash"
fi

if git rev-parse -q --verify "refs/tags/$TAG" >/dev/null; then
  fail "本地已存在 tag $TAG"
fi
if git ls-remote --exit-code --tags origin "refs/tags/$TAG" >/dev/null 2>&1; then
  fail "远端已存在 tag ${TAG}（远端不可达时忽略此检查）"
fi

# 版本必须比现有最大 tag 新，避免误发倒退版本
LATEST_TAG="$(git tag -l 'v*' | sort -V | tail -1 || true)"
if [[ -n "$LATEST_TAG" ]]; then
  NEWER="$(printf '%s\n%s\n' "${LATEST_TAG#v}" "$VERSION" | sort -V | tail -1)"
  [[ "$NEWER" == "$VERSION" && "$VERSION" != "${LATEST_TAG#v}" ]] \
    || fail "版本 $VERSION 不大于现有最新 tag ${LATEST_TAG#v}"
fi

# changelog 章节：Release 说明的唯一来源，缺了就别发
NOTES_FILE="${TMPDIR:-/tmp}/kairo-release-notes-${TAG}.md"
if ! bash tools/release_notes.sh "$TAG" > "$NOTES_FILE" 2>/dev/null; then
  fail "CHANGELOG.md 缺少「## ${TAG}」章节——先写好再发版"
fi
echo "    changelog 章节: $(wc -l < "$NOTES_FILE" | tr -d ' ') 行"

# 多语言发布闸门（06-localization §11 判据 1 / §13）：视图层零中文 + 两侧键完整。
# 白名单必须为空——开发期它是迁移基线，发版时它必须消失。
echo "==> 校验多语言资源"
LPROJ_TMP="$(mktemp -d)/lproj"
if ! bash tools/i18n-compile.sh "$LPROJ_TMP" >/dev/null; then
  fail "多语言: Catalog 编译失败（缺 Apps/macos/Resources/Localizable.xcstrings 或 xcstringstool？）"
fi
if ! bash tools/i18n-lint.sh --require-catalog --fail-if-whitelist-nonempty --lproj-dir "$LPROJ_TMP"; then
  fail "多语言: 门禁未通过（白名单未清零或键/占位符不一致，见上方输出）"
fi
echo "    视图层无未登记中文，两侧键与占位符一致"

# ---------- 2. 同步三处版本号 ----------
echo "==> 版本号 → $VERSION"
sed -i '' -E "s|<string>[0-9]+\.[0-9]+\.[0-9]+</string>|<string>$VERSION</string>|" tools/build.sh
sed -i '' -E "s|\"version\": \"[0-9]+\.[0-9]+\.[0-9]+\"|\"version\": \"$VERSION\"|" Sources/KairoMCP/MCPServer.swift
sed -i '' -E "s|static let appVersion = \"[0-9]+\.[0-9]+\.[0-9]+\"|static let appVersion = \"$VERSION\"|" Apps/macos/Sources/CommandRegistry.swift

for f in tools/build.sh Sources/KairoMCP/MCPServer.swift Apps/macos/Sources/CommandRegistry.swift; do
  grep -q "$VERSION" "$f" || fail "版本号未写入 $f"
done
echo "    tools/build.sh / MCPServer.swift / CommandRegistry.swift 均已更新"

# ---------- 3. 测试 + 打包 ----------
if [[ "$SKIP_TESTS" -eq 0 ]]; then
  echo "==> 全量测试"
  swift test --disable-sandbox
fi

echo "==> 构建并打包（DMG + OTA zip）"
PACKAGE_OUT="$(bash tools/package.sh "$TAG")"
printf '%s\n' "$PACKAGE_OUT" | tail -4
DMG="dist/Kairo-${TAG}.dmg"
ZIP="dist/Kairo-${TAG}.zip"
[[ -f "$DMG" && -f "$ZIP" ]] || fail "打包产物缺失"

# 签名状态如实记录：本地产物只经 build.sh 的 ad-hoc 签名，没有公证。
# 不给产物贴「已签名」标签，也不假装本地能验证公证——凭据不在这台机器上。
SIG_LINE="$(codesign -dv --verbose=4 "dist/Kairo.app" 2>&1 | grep -m1 '^Signature=' || true)"
if printf '%s' "$SIG_LINE" | grep -q 'Signature=adhoc'; then
  SIGN_STATE="未签名（ad-hoc），未公证"
else
  SIGN_STATE="非 ad-hoc 签名但未经本脚本公证：${SIG_LINE:-无签名信息}"
fi
{
  printf 'Kairo %s 本地产物签名状态\n' "$TAG"
  printf '================================\n'
  printf '状态: %s\n' "$SIGN_STATE"
  printf '说明: tools/release.sh 只做本机构建；Developer ID 签名与 notarytool 公证在 CI 完成。\n'
  printf '分发: 对外只发 GitHub Release 上的 CI 产物，其状态见该 Release 附带的 SIGNING.txt。\n'
  printf '验证: codesign -dv --verbose=4 dist/Kairo.app（ad-hoc 时 Signature=adhoc）\n'
  printf '\n'
} > dist/SIGNING.txt

if [[ "$DRY_RUN" -eq 1 ]]; then
  echo "==> dry-run：产物与版本号已就绪，未提交、未打 tag、未推送"
  echo "    DMG: $DMG"
  echo "    ZIP: $ZIP"
  echo "    说明: $NOTES_FILE"
  echo "==> 本地产物签名状态：${SIGN_STATE}"
  echo "    对外分发请以 CI 产物为准，签名/公证验证见 docs/release.md"
  exit 0
fi

# ---------- 4. 提交 + 打 tag ----------
echo "==> 提交发版"
git add tools/build.sh Sources/KairoMCP/MCPServer.swift Apps/macos/Sources/CommandRegistry.swift CHANGELOG.md
git commit -q -F - <<MSG
chore(release): ${TAG}

- 版本号同步至 ${VERSION}（tools/build.sh、MCPServer、CommandRegistry）
- 产物：Kairo-${TAG}.dmg（人装）+ Kairo-${TAG}.zip（OTA 载体），本地打包校验通过
- Release 说明取自 CHANGELOG.md「## ${TAG}」章节
MSG

git tag -a "$TAG" -m "Kairo $TAG"

# ---------- 5. 推送 ----------
if [[ "$PUSH" -eq 1 ]]; then
  echo "==> 推送 main 与 $TAG"
  git push origin main
  git push origin "refs/tags/$TAG"
  echo "==> 本地产物签名状态：${SIGN_STATE}（记录在 dist/SIGNING.txt）"
  echo "    CI 会按 secret 决定是否签名/公证，状态写进 Release 的 SIGNING.txt；验证见 docs/release.md"
  echo "==> 已触发发版流程，查看进度："
  echo "    gh run list --workflow=release.yml --limit 3"
else
  echo "==> 未推送（--no-push）；需要时执行："
  echo "    git push origin main && git push origin refs/tags/$TAG"
fi

#!/usr/bin/env bash
# 编译 Kaido（Release）并打包 macOS 应用 Kaido.app。
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-release}"
DIST_DIR="${DIST_DIR:-$ROOT/dist}"
APP_NAME="Kaido"
APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
BINARY_PRODUCT="KaidoMacApp"

usage() {
  cat <<USAGE
用法: $(basename "$0") [选项]

选项:
  -c, --configuration <debug|release>  构建配置（默认: release）
  -o, --output <dir>                   输出目录（默认: dist/）
  --mas                                Mac App Store 变体（禁用自更新、不产出 CLI/MCP）
  --skip-gate                          跳过核心与呈现层平台绑定门禁
  -h, --help                           显示帮助
USAGE
}

SKIP_GATE=0
MAS=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    -c|--configuration)
      CONFIGURATION="${2:?}"
      shift 2
      ;;
    -o|--output)
      DIST_DIR="${2:?}"
      APP_BUNDLE="$DIST_DIR/${APP_NAME}.app"
      shift 2
      ;;
    --mas)
      MAS=1
      shift
      ;;
    --skip-gate)
      SKIP_GATE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "未知参数: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

case "$CONFIGURATION" in
  debug|release) ;;
  *)
    echo "配置必须是 debug 或 release，收到: $CONFIGURATION" >&2
    exit 2
    ;;
esac

if [[ "$SKIP_GATE" -eq 0 ]]; then
  bash "$ROOT/tools/gate-core.sh"
fi

# 商店变体：编译期常量让自更新整体消失（KaidoDistribution.isAppStoreBuild）。
SWIFT_FLAGS=(-Xswiftc -warnings-as-errors)
if [[ "$MAS" -eq 1 ]]; then
  SWIFT_FLAGS+=(-Xswiftc -DKAIDO_MAS)
  echo "==> App Store 变体：自更新编译期禁用，不产出 CLI/MCP"
fi

echo "==> swift build -c $CONFIGURATION (universal: arm64 + x86_64, warnings as errors)"
# 告警一律视为失败，避免带 warning 的产物进入 dist/
# v1.0.1：默认出 universal。此前只构建宿主架构（arm64），而下载页没有任何「仅 Apple Silicon」说明，
# Intel Mac 用户拿到 DMG 会直接遇到「应用无法打开」，属于交付缺陷而非可接受限制。
# 交叉编译不可用时回退宿主架构并显式告警，不让发版卡死。
ARCH_ARGS=(--arch arm64 --arch x86_64)
if ! swift build -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${SWIFT_FLAGS[@]}"; then
  echo "!! universal 构建失败，回退宿主架构（仅 $(uname -m)）—— 该产物不能在另一种 CPU 上运行" >&2
  ARCH_ARGS=()
  swift build -c "$CONFIGURATION" "${SWIFT_FLAGS[@]}"
fi

BUILD_DIR="$(swift build -c "$CONFIGURATION" ${ARCH_ARGS[@]+"${ARCH_ARGS[@]}"} "${SWIFT_FLAGS[@]}" --show-bin-path)"
SRC_BIN="$BUILD_DIR/$BINARY_PRODUCT"
if [[ ! -x "$SRC_BIN" ]]; then
  echo "未找到可执行文件: $SRC_BIN" >&2
  exit 1
fi

echo "==> 打包 ${APP_NAME}.app → $APP_BUNDLE"
rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

# 构建时间戳：写入 CFBundleVersion，「关于」面板与 Finder 显示编译版本
BUILD_STAMP="$(date +%Y%m%d.%H%M)"

# 可执行文件名与 CFBundleExecutable 一致
cp "$SRC_BIN" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"

# 站点外分发才放 CLI / MCP：商店包只允许一个 .app payload，且沙盒下
# 外部进程 spawn 子进程读不到用户文件，带了也用不了（CLI 由 app 的 --cli 模式承担）。
if [[ "$MAS" -eq 0 ]]; then
  cp "$BUILD_DIR/KaidoCLI" "$DIST_DIR/KaidoCLI"
  cp "$BUILD_DIR/KaidoMCP" "$DIST_DIR/KaidoMCP"
  chmod +x "$DIST_DIR/KaidoCLI" "$DIST_DIR/KaidoMCP"
fi

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en</string>
  <key>CFBundleLocalizations</key>
  <array>
    <string>en</string>
    <string>zh-Hans</string>
  </array>
  <key>CFBundleExecutable</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIdentifier</key>
  <string>top.cygnusyang.kaido</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleDisplayName</key>
  <string>${APP_NAME}</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>2.1.0</string>
  <key>CFBundleVersion</key>
  <string>${BUILD_STAMP}</string>
  <key>LSMinimumSystemVersion</key>
  <string>14.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.productivity</string>
  <key>ITSAppUsesNonExemptEncryption</key>
  <false/>
  <key>CFBundleSupportedPlatforms</key>
  <array>
    <string>MacOSX</string>
  </array>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Kaido Project</string>
      <key>CFBundleTypeRole</key>
      <string>Editor</string>
      <key>LSHandlerRank</key>
      <string>Owner</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>app.kaido.project</string>
      </array>
      <key>CFBundleTypeExtensions</key>
      <array>
        <string>kaido</string>
      </array>
    </dict>
  </array>
  <key>UTExportedTypeDeclarations</key>
  <array>
    <dict>
      <key>UTTypeIdentifier</key>
      <string>app.kaido.project</string>
      <key>UTTypeDescription</key>
      <string>Kaido Project</string>
      <key>UTTypeConformsTo</key>
      <array>
        <string>public.data</string>
        <string>public.content</string>
      </array>
      <key>UTTypeTagSpecification</key>
      <dict>
        <key>public.filename-extension</key>
        <array>
          <string>kaido</string>
        </array>
      </dict>
    </dict>
  </array>
  <key>CFBundleURLTypes</key>
  <array>
    <dict>
      <key>CFBundleURLName</key>
      <string>Kaido Deep Link</string>
      <key>CFBundleURLSchemes</key>
      <array>
        <string>kaido</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST

# App icon
ICNS_SRC="$ROOT/design/icons/app/AppIcon.icns"
if [[ -f "$ICNS_SRC" ]]; then
  cp "$ICNS_SRC" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
  # CFBundleIconFile without extension
  /usr/libexec/PlistBuddy -c 'Add :CFBundleIconFile string AppIcon' "$APP_BUNDLE/Contents/Info.plist" 2>/dev/null \
    || /usr/libexec/PlistBuddy -c 'Set :CFBundleIconFile AppIcon' "$APP_BUNDLE/Contents/Info.plist"
fi

# Menubar template icons (for future NSStatusItem)
MENUBAR_SRC="$ROOT/design/icons/menubar"
if [[ -d "$MENUBAR_SRC" ]]; then
  mkdir -p "$APP_BUNDLE/Contents/Resources"
  cp "$MENUBAR_SRC/kaido-menubarTemplate.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
  # @2x 倍图一并入包（NSStatusItem 目前在代码里尚未启用，先备好资源不缺位）
  cp "$MENUBAR_SRC/kaido-menubarTemplate@2x.png" "$APP_BUNDLE/Contents/Resources/" 2>/dev/null || true
fi

printf 'APPL????' > "$APP_BUNDLE/Contents/PkgInfo"

# 本地化资源（F-0700 主路径 B，docs/features/06-localization.md §7）
# .xcstrings 只作源，编译成 .lproj 后拷进 Contents/Resources；必须早于 codesign，
# 否则资源不在签名覆盖内（R4）。缺 Catalog 或任一语言目录一律失败，不静默回退。
LPROJ_DIR="$DIST_DIR/lproj"
echo "==> 编译本地化资源 → $LPROJ_DIR"
if ! bash "$ROOT/tools/i18n-compile.sh" "$LPROJ_DIR"; then
  echo "本地化资源编译失败，停止打包（需要 Xcode 命令行工具与 $ROOT/Apps/macos/Resources/Localizable.xcstrings）" >&2
  exit 1
fi
for LANG_ID in en zh-Hans; do
  if [[ ! -d "$LPROJ_DIR/$LANG_ID.lproj" ]]; then
    echo "缺少本地化目录：$LPROJ_DIR/${LANG_ID}.lproj（Catalog 未提供 ${LANG_ID}）" >&2
    exit 1
  fi
  cp -R "$LPROJ_DIR/$LANG_ID.lproj" "$APP_BUNDLE/Contents/Resources/"
done

# 本地 ad-hoc 签名，避免 Gatekeeper 拦住未签名包。
# 商店变体不签：随后的 tools/sign-mas.sh 用 Apple Distribution 重签，
# 先 ad-hoc 再重签只会多跑一遍 --deep。
if [[ "$MAS" -eq 0 ]] && command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
fi

if [[ "$MAS" -eq 1 ]]; then
  cat > "$DIST_DIR/README.txt" <<NOTE
Kaido 构建产物（Mac App Store 变体）
====================================
- ${APP_NAME}.app     macOS 应用；自更新已在编译期禁用

下一步（签名与出包，凭据见 ~/kaido-signing）:
  tools/sign-mas.sh --app "$APP_BUNDLE" \
    --entitlements Apps/macos/Resources/Kaido.entitlements \
    --provisionprofile ~/kaido-signing/KaidoPlanMAS.provisionprofile \
    --pkg-out "$DIST_DIR/Kaido.pkg"
NOTE
else
  cat > "$DIST_DIR/README.txt" <<NOTE
Kaido 构建产物
==============
- ${APP_NAME}.app     macOS 应用（可 open 或拖到 /Applications）
- KaidoCLI            命令行
- KaidoMCP            MCP 服务（stdio）

安装应用:
  bash tools/install.sh
NOTE
fi

echo "==> 完成"
echo "    App:  $APP_BUNDLE"
if [[ "$MAS" -eq 0 ]]; then
  echo "    CLI:  $DIST_DIR/KaidoCLI"
  echo "    MCP:  $DIST_DIR/KaidoMCP"
else
  echo "    商店版：未产出 CLI/MCP，自更新已禁用；签名请用 tools/sign-mas.sh"
fi

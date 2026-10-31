#!/usr/bin/env bash
# tools/sign-mas.sh —— Mac App Store 签名与打包（只签名，不含任何凭据）。
#
# 凭据来源（全部通过环境或钥匙串身份名，脚本内零密钥）：
#   KAIRO_SIGN_IDENTITY       例："Apple Distribution: ruohu yang (A6DS985SJJ)"
#   KAIRO_INSTALLER_IDENTITY  例："3rd Party Mac Developer Installer: ruohu yang (A6DS985SJJ)"
#   KAIRO_KEYCHAIN            可选，指定钥匙串路径（CI 用临时钥匙串）；默认登录钥匙串
#
# 用法：
#   tools/sign-mas.sh --app dist-mas/Kairo.app --entitlements Apps/macos/Resources/Kairo.entitlements \
#                     --pkg-out dist-mas/Kairo.pkg [--provisionprofile path]
#
# 前置：钥匙串里已有对应身份（security find-identity -p basic 能看到）。
set -euo pipefail

APP=""
ENTS=""
PKG=""
PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --app) APP="$2"; shift 2 ;;
    --entitlements) ENTS="$2"; shift 2 ;;
    --pkg-out) PKG="$2"; shift 2 ;;
    --provisionprofile) PROFILE="$2"; shift 2 ;;
    *) echo "未知参数: $1" >&2; exit 2 ;;
  esac
done

[ -d "$APP" ] || { echo "ERROR: --app 不存在: $APP" >&2; exit 2; }
[ -f "$ENTS" ] || { echo "ERROR: --entitlements 不存在: $ENTS" >&2; exit 2; }
[ -n "${KAIRO_SIGN_IDENTITY:-}" ] || { echo "ERROR: 未设置 KAIRO_SIGN_IDENTITY" >&2; exit 2; }

KEYCHAIN_ARGS=()
if [ -n "${KAIRO_KEYCHAIN:-}" ]; then KEYCHAIN_ARGS=(--keychain "$KAIRO_KEYCHAIN"); fi

# 1) 嵌入 provisioning profile（有则嵌，App Store 分发必需）
if [ -n "$PROFILE" ]; then
  [ -f "$PROFILE" ] || { echo "ERROR: profile 不存在: $PROFILE" >&2; exit 2; }
  cp "$PROFILE" "$APP/Contents/embedded.provisionprofile"
  echo "==> 已嵌入 profile"
fi

# 2) 签名 app（entitlements + 时间戳由 Apple 侧校验，MAS 不要求 hardened runtime）
codesign --force --options runtime --timestamp --sign "$KAIRO_SIGN_IDENTITY" "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" \
  --entitlements "$ENTS" --deep "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "==> 已签名并校验: $APP"

# 3) 出 pkg（App Store 上传载体）
if [ -n "$PKG" ]; then
  [ -n "${KAIRO_INSTALLER_IDENTITY:-}" ] || { echo "ERROR: 缺少 KAIRO_INSTALLER_IDENTITY" >&2; exit 2; }
  STAGE="$(mktemp -d)"
  mkdir -p "$STAGE/Applications"
  cp -R "$APP" "$STAGE/Applications/"
  productbuild --component "$APP" /Applications --sign "$KAIRO_INSTALLER_IDENTITY" "${KEYCHAIN_ARGS[@]+"${KEYCHAIN_ARGS[@]}"}" "$PKG"
  rm -rf "$STAGE"
  pkgutil --check-signature "$PKG" || true
  echo "==> 已产出 pkg: $PKG"
fi
echo "完成"
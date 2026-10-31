#!/usr/bin/env bash
# tools/gate-secrets.sh —— 阻止私钥/证书/密码文件进入仓库。
#
# 只扫「已被 git 跟踪」的文件；临时目录里的 .p12 不受影响。
# 命中即失败，退出码 1。
set -uo pipefail

FAIL=0

# 1) 文件名黑名单
SUSPECT_FILES="$(git ls-files | grep -E '\.(p12|pfx|key|pem|cer|mobileprovision)$|password.*\.(txt|md)$' || true)"
if [ -n "$SUSPECT_FILES" ]; then
  echo "ERROR: 仓库里出现疑似凭据文件：" >&2
  printf "%s\n" "$SUSPECT_FILES" >&2
  FAIL=1
fi

# 2) 内容里出现私钥块
if git grep -I -l -E '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- . >/dev/null 2>&1; then
  echo "ERROR: 以下文件包含私钥块：" >&2
  git grep -I -l -E '-----BEGIN ([A-Z]+ )?PRIVATE KEY-----' -- . >&2
  FAIL=1
fi

# 3) workflow 里写死 base64 证书（长度 > 200 的连续 base64 且含 p12 关键字）
if git grep -I -n -E 'MACOS_CERT_P12[[:space:]]*[:=][[:space:]]*[A-Za-z0-9+/=]{200,}' -- . >/dev/null 2>&1; then
  echo "ERROR: 疑似把证书 base64 写进了仓库文件（应放 GitHub Secrets）" >&2
  FAIL=1
fi

if [ "$FAIL" -eq 0 ]; then
  echo "gate-secrets: 未发现私钥/证书/密码文件，通过"
fi
exit "$FAIL"
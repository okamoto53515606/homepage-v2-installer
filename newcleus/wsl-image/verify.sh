#!/usr/bin/env bash
# =============================================================================
# newcleus CMS 配布用 WSL イメージ: スモークテスト
#
#   圧縮済み tar.gz を検証用 distro に import したあと、
#   配布ユーザー（-u ubuntu）で実行する。
#
#   必須 env:
#     EXPECTED_VERSION ... 期待するアプリ版（例 1.0.6, v 付きでも可）
# =============================================================================
set -uo pipefail

EXPECTED_VERSION="${EXPECTED_VERSION:-}"
EXPECTED_VERSION="${EXPECTED_VERSION#v}"
APP_ROOT="$HOME/newcleus"

fail() { echo "[FAIL] $*"; exit 1; }
pass() { echo "[PASS] $*"; }

# why: verify.sh は非ログインシェルで起動されるため nvm が PATH に無い。
if ! command -v node >/dev/null 2>&1; then
  # shellcheck disable=SC1091
  . /etc/profile.d/10-nvm.sh 2>/dev/null || true
fi

# 1. Node.js
NODE_VERSION="$(node -v 2>/dev/null || true)"
[ -n "$NODE_VERSION" ] || fail "node not found (nvm/PATH)"
case "$NODE_VERSION" in
  v24.*) pass "node $NODE_VERSION" ;;
  *) fail "unexpected node version: $NODE_VERSION" ;;
esac

# 2. AWS CLI
AWS_VERSION="$(aws --version 2>&1 || true)"
case "$AWS_VERSION" in
  aws-cli/2.*) pass "$AWS_VERSION" ;;
  *) fail "unexpected aws cli: $AWS_VERSION" ;;
esac

# 3. Docker デーモン（systemd 自動起動）
if docker info >/dev/null 2>&1; then
  pass "docker $(docker version --format '{{.Server.Version}}' 2>/dev/null)"
else
  fail "docker info failed (daemon not running / group not applied)"
fi

# 4. ビルド成果物
[ -d "$APP_ROOT/setup/.next" ] || fail "~/newcleus/setup/.next missing"
[ -s "$APP_ROOT/setup/.next/BUILD_ID" ] || fail "~/newcleus/setup/.next/BUILD_ID missing"
[ -d "$APP_ROOT/node_modules" ] || fail "~/newcleus/node_modules missing"
[ -x "$APP_ROOT/setup/start.sh" ] || fail "start.sh is not executable"
[ -f "$APP_ROOT/.env" ] || fail "~/newcleus/.env missing"
[ ! -d "$APP_ROOT/prompt_history" ] || fail "prompt_history is included (should be excluded)"
pass "artifact present (.next / BUILD_ID / node_modules / start.sh / .env)"

# 5. バージョン整合（newcleus は NEXT_PUBLIC_APP_VERSION を焼き込まない）
if [ -n "$EXPECTED_VERSION" ]; then
  ACTUAL_VERSION="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
    "$APP_ROOT/package.json" | head -1)"
  [ "$ACTUAL_VERSION" = "$EXPECTED_VERSION" ] \
    || fail "package.json version $ACTUAL_VERSION != $EXPECTED_VERSION"
  pass "version $EXPECTED_VERSION (package.json)"
fi

# 6. sudo NOPASSWD（setup 画面が内部で sudo を呼ぶ）
if sudo -n true 2>/dev/null; then
  pass "sudo NOPASSWD"
else
  fail "sudo requires password (NOPASSWD not configured)"
fi

# 7. クレデンシャル混入・履歴の残存チェック
for p in "$HOME/.aws" "$HOME/.ssh" "$HOME/.bash_history" "$HOME/.git-credentials"; do
  [ -e "$p" ] && fail "unexpected file in image: $p"
done
pass "no stray credentials/history"

# 8. wsl.conf
grep -Eq '^[[:space:]]*default[[:space:]]*=[[:space:]]*ubuntu' /etc/wsl.conf \
  || fail "/etc/wsl.conf has no default user"
grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf \
  || fail "/etc/wsl.conf has no systemd=true"
pass "wsl.conf (default user + systemd)"

# 9. マニフェスト
[ -f /etc/newcleus-image.json ] || fail "/etc/newcleus-image.json missing"
pass "manifest: $(tr -d '\n' < /etc/newcleus-image.json)"

echo "--- all checks passed ---"

#!/usr/bin/env bash
# =============================================================================
# homepage-v2 配布用 WSL イメージ: 軽量化 + 個人情報混入チェック
#
#   build distro の中で root として実行する（provision.sh の後）。
#   順序が重要: 「更新 → ビルド → purge → 掃除」。先に掃除すると apt が壊れる。
#
#   必須 env:
#     DISTRO_USER ... 配布ユーザー（既定 ubuntu）
#   任意 env:
#     LOG_PATH    ... WSL 側から見たログ出力先
# =============================================================================
set -euo pipefail

DISTRO_USER="${DISTRO_USER:-ubuntu}"
LOG_PATH="${LOG_PATH:-}"
USER_HOME="/home/$DISTRO_USER"

if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  exec > >(tee -a "$LOG_PATH") 2>&1
fi

say() { printf '\n=== [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
export DEBIAN_FRONTEND=noninteractive

size_before="$(du -sx --block-size=1MiB / 2>/dev/null | awk '{print $1}')"
echo "size before: ${size_before} MiB"

# -----------------------------------------------------------------------------
# 1. ビルドキャッシュの削除（エクスポート直前にだけ走らせる）
# -----------------------------------------------------------------------------
say "caches: docker / npm / next"
if docker info >/dev/null 2>&1; then
  docker system prune -a --volumes -f || true
else
  echo "WARN: docker daemon not available, skip docker prune"
fi
sudo -u "$DISTRO_USER" -H bash -lc 'npm cache clean --force || true' || true
# why: .next/cache はビルド増分キャッシュ。実行時には不要で数百MBになる。
rm -rf "$USER_HOME/homepage/setup/.next/cache"
rm -rf "$USER_HOME/.npm/_logs" "$USER_HOME/.cache"

# -----------------------------------------------------------------------------
# 2. WSL では不要な常駐パッケージの削除
#    why: snapd は WSL のカーネル依存で正常動作せずディスクだけ食う。
#         cloud-init / landscape / ubuntu-advantage はクラウド/Canonical サポート用。
#         unattended-upgrades は配布後に勝手に更新されると再現性が壊れる。
# -----------------------------------------------------------------------------
say "purge unnecessary packages"
apt-get purge -y \
  snapd \
  unattended-upgrades \
  ubuntu-advantage-tools \
  cloud-init \
  landscape-common \
  command-not-found || true

apt-get autoremove --purge -y || true
apt-get clean
rm -rf /var/lib/apt/lists/*

# -----------------------------------------------------------------------------
# 3. ドキュメント / man / ロケールの削除
#    why: copyright だけは GPL 等のライセンス義務で残す。
# -----------------------------------------------------------------------------
say "trim docs / man / locales"
find /usr/share/doc -depth -type f ! -name copyright -delete || true
find /usr/share/doc -depth -type l -delete || true
find /usr/share/doc -empty -delete || true
find /usr/share/man -type f -delete || true
find /usr/share/locale -mindepth 1 -maxdepth 1 -type d \
  ! -name 'en*' ! -name 'ja*' ! -name 'C.UTF-8' \
  -exec rm -rf {} + || true

rm -rf /var/lib/snapd /var/cache/snapd /snap /var/lib/cloud

# -----------------------------------------------------------------------------
# 4. 一時ファイル / ログ
#    why: /var/log は cp /dev/null で inode を保持したまま中身だけ空にする
#         （journald 等の書き込み先 fd を壊さない）。
# -----------------------------------------------------------------------------
say "clear tmp / logs"
rm -rf /tmp/* /var/tmp/* || true
find /var/log -type f -exec cp /dev/null {} \; || true

# -----------------------------------------------------------------------------
# 5. 個人情報混入チェック（配布物にクレデンシャル/履歴を入れない）
# -----------------------------------------------------------------------------
say "scrub credentials & history"
rm -f  "$USER_HOME/.bash_history" "$USER_HOME/.sudo_as_admin_successful"
rm -f  /root/.bash_history
rm -rf "$USER_HOME/.aws" /root/.aws
rm -f  "$USER_HOME/.npmrc" "$USER_HOME/.git-credentials" "$USER_HOME/.netrc"
rm -f  "$USER_HOME/.docker/config.json" /root/.docker/config.json
rm -rf "$USER_HOME/.ssh" /root/.ssh
rm -rf "$USER_HOME/homepage/.git"   # 配布物は tar 展開のみ（履歴は不要）

SECRET_HIT=0
if [ -f "$USER_HOME/homepage/.env" ]; then
  if grep -Eq '(AKIA[0-9A-Z]{16}|aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]+|ghp_[0-9A-Za-z]{20,})' \
       "$USER_HOME/homepage/.env"; then
    echo "ERROR: クレデンシャルらしき文字列が .env に含まれています:" >&2
    grep -En '(AKIA[0-9A-Z]{16}|aws_secret_access_key[[:space:]]*=[[:space:]]*[^[:space:]]+|ghp_[0-9A-Za-z]{20,})' \
      "$USER_HOME/homepage/.env" | sed 's/=.*/=<redacted>/' >&2
    SECRET_HIT=1
  fi
fi
[ "$SECRET_HIT" -eq 0 ] || exit 21
echo "credential scan: clean"

# -----------------------------------------------------------------------------
# 6. レポート
# -----------------------------------------------------------------------------
say "size report"
size_after="$(du -sx --block-size=1MiB / 2>/dev/null | awk '{print $1}')"
echo "size after : ${size_after} MiB"
du -x --block-size=1MiB -d1 / 2>/dev/null | sort -rn | head -12 || true

say "cleanup done"

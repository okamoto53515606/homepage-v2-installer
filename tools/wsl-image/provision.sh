#!/usr/bin/env bash
# =============================================================================
# homepage-v2 配布用 WSL イメージ: プロビジョニング
#
#   `wsl --import` した Ubuntu rootfs（= build distro）の中で root として実行する。
#   呼び出し元: tools/build-wsl-image.ps1
#
#   必須 env:
#     APP_VERSION  ... イメージに焼き込む版（例 2.1.2）。空なら検査をスキップ
#   任意 env:
#     DISTRO_USER  ... 配布イメージの Unix ユーザー（既定 ubuntu）
#     BUILD_ID     ... ビルド識別子（manifest に記録）
#     BASE_SHA256  ... ベース rootfs の SHA256（manifest に記録）
#     LOG_PATH     ... WSL 側から見たログ出力先（例 /mnt/d/wsl_backup/logs/x.log）
#
#   設計メモ:
#     - 対話プロンプトを一切出さない（DEBIAN_FRONTEND / NEEDRESTART_MODE）
#     - sudoers は visudo ではなく /etc/sudoers.d/99-homepage を直接書く
#     - nvm は /etc/profile.d 経由で非対話ログインシェル（bash -lc）でも使えるようにする
#     - Docker は systemd を有効化したうえで systemctl で起動する
# =============================================================================
set -euo pipefail

DISTRO_USER="${DISTRO_USER:-ubuntu}"
APP_VERSION="${APP_VERSION:-}"
BUILD_ID="${BUILD_ID:-unknown}"
BASE_SHA256="${BASE_SHA256:-unknown}"
LOG_PATH="${LOG_PATH:-}"

if [ -n "$LOG_PATH" ]; then
  mkdir -p "$(dirname "$LOG_PATH")"
  exec > >(tee -a "$LOG_PATH") 2>&1
fi

say() { printf '\n=== [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=a

USER_HOME="/home/$DISTRO_USER"

# -----------------------------------------------------------------------------
# 1. wsl.conf（systemd 有効 / 既定ユーザー）
# -----------------------------------------------------------------------------
say "wsl.conf: systemd + default user"
if ! grep -Eq '^[[:space:]]*systemd[[:space:]]*=[[:space:]]*true' /etc/wsl.conf 2>/dev/null; then
  if grep -q '^\[boot\]' /etc/wsl.conf 2>/dev/null; then
    sed -i '/^\[boot\]/a systemd=true' /etc/wsl.conf
  else
    printf '[boot]\nsystemd=true\n' >> /etc/wsl.conf
  fi
fi
if ! grep -Eq "^[[:space:]]*default[[:space:]]*=[[:space:]]*$DISTRO_USER" /etc/wsl.conf 2>/dev/null; then
  printf '\n[user]\ndefault=%s\n' "$DISTRO_USER" >> /etc/wsl.conf
fi
cat /etc/wsl.conf

# -----------------------------------------------------------------------------
# 2. OS 更新（セキュリティ修正を確実に取り込む）
#    upgrade ではなく full-upgrade。依存変更を伴う修正を取りこぼさない。
# -----------------------------------------------------------------------------
say "apt: update + full-upgrade"
apt-get update
apt-get -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold full-upgrade

say "apt: base packages"
apt-get -y install --no-install-recommends \
  ca-certificates curl gnupg git unzip zip pigz \
  build-essential python3 make gcc

# -----------------------------------------------------------------------------
# 3. 配布ユーザー（ubuntu）と NOPASSWD sudo
#    visudo の対話編集は使わない。sudoers.d を直接書いて構文検証だけ行う。
# -----------------------------------------------------------------------------
say "user: $DISTRO_USER + sudoers"
if ! id -u "$DISTRO_USER" >/dev/null 2>&1; then
  useradd -m -s /bin/bash -G sudo "$DISTRO_USER"
fi
install -d -m 0755 /etc/sudoers.d
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$DISTRO_USER" > /etc/sudoers.d/99-homepage
chmod 0440 /etc/sudoers.d/99-homepage
visudo -cf /etc/sudoers.d/99-homepage

# -----------------------------------------------------------------------------
# 4. AWS CLI v2（setup 画面が aws CLI / SDK のクレデンシャル参照を前提にしている）
# -----------------------------------------------------------------------------
say "awscli v2"
tmpdir="$(mktemp -d)"
curl -fsSL --retry 3 -o "$tmpdir/awscliv2.zip" \
  "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip"
unzip -q "$tmpdir/awscliv2.zip" -d "$tmpdir"
"$tmpdir/aws/install" --update
rm -rf "$tmpdir"
aws --version

# -----------------------------------------------------------------------------
# 5. Node.js 24（nvm）
#    why: Next.js 16 / aws-cdk-lib の最新が要求する Node 20+ を満たす LTS。
#         22 系は CVE-2026-111497 の影響があるため 24 を採用する。
# -----------------------------------------------------------------------------
say "nvm + Node.js 24"
sudo -u "$DISTRO_USER" -H bash -lc '
  set -e
  if [ ! -s "$HOME/.nvm/nvm.sh" ]; then
    curl -fsSL --retry 3 https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.4/install.sh | bash
  fi
'
sudo -u "$DISTRO_USER" -H bash -lc '
  set -e
  export NVM_DIR="$HOME/.nvm"
  . "$NVM_DIR/nvm.sh"
  nvm install 24
  nvm alias default 24
'

# why: nvm の init は ~/.bashrc の「対話シェルのみ」ブロックに入るため、
#      bash -lc（非対話ログインシェル）では node が見えない。配布イメージの
#      更新スクリプト対策として profile.d で明示的に読み込む。
cat > /etc/profile.d/10-nvm.sh <<EOF
# nvm を非対話ログインシェル（bash -lc）でも利用可能にする
export NVM_DIR="\${NVM_DIR:-$USER_HOME/.nvm}"
if [ -s "\$NVM_DIR/nvm.sh" ]; then
  . "\$NVM_DIR/nvm.sh"
fi
EOF
chmod 0644 /etc/profile.d/10-nvm.sh

NODE_VERSION="$(sudo -u "$DISTRO_USER" -H bash -lc 'node -v')"
case "$NODE_VERSION" in
  v24.*) ;;
  *) echo "ERROR: unexpected Node.js version: $NODE_VERSION" >&2; exit 11 ;;
esac
echo "node: $NODE_VERSION"

# -----------------------------------------------------------------------------
# 6. Docker（npx cdk deploy の Lambda コンテナビルドで必須）
# -----------------------------------------------------------------------------
say "docker engine"
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  | gpg --batch --yes --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg
. /etc/os-release
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu %s stable\n' \
  "$(dpkg --print-architecture)" "$VERSION_CODENAME" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
# why: --no-install-recommends を付けない（iptables 等が推奨依存のため）
apt-get -y install docker-ce docker-ce-cli containerd.io

usermod -aG docker "$DISTRO_USER"
systemctl enable docker
systemctl start docker

for _ in $(seq 1 30); do
  if docker info >/dev/null 2>&1; then break; fi
  sleep 2
done
docker info >/dev/null || { echo "ERROR: docker daemon is not available" >&2; exit 12; }
echo "docker: $(docker version --format '{{.Server.Version}}')"

# -----------------------------------------------------------------------------
# 7. アプリ取得 + ビルド（main の fetch-app.sh を必ず使う）
#    why: 手元のコピーに依存せず、修正済みの挙動を必ず反映する。
#         --fresh は .env を env_template.txt から作る（配布物は未設定が正）。
#         --dist は setup を npm install → next build → prune --production。
# -----------------------------------------------------------------------------
say "fetch-app.sh --fresh --dist"
# why: --yes で「続行しますか? [y/N]」を抑止する。付け忘れると非対話ビルドが
#      プロンプトで止まる。stdin を /dev/null にして、想定外のプロンプトが出ても
#      "ハング" ではなく即失敗させる（既定は N で中止）。
sudo -u "$DISTRO_USER" -H bash -lc '
  set -euo pipefail
  curl -fsSL --retry 3 -o /tmp/fetch-app.sh \
    https://raw.githubusercontent.com/okamoto53515606/homepage/main/setup/scripts/fetch-app.sh
  bash -n /tmp/fetch-app.sh
  bash /tmp/fetch-app.sh --dir "$HOME/homepage" --fresh --dist --yes < /dev/null
'

chmod +x "$USER_HOME/homepage/setup/start.sh"

# -----------------------------------------------------------------------------
# 8. バージョン整合（画面に出る版 = イメージの中身）
#    why: NEXT_PUBLIC_APP_VERSION は next build 時に焼き込まれる。
#         package.json と違う版が焼かれていたら気付けるようにする。
# -----------------------------------------------------------------------------
say "version check"
APP_VERSION_ACTUAL="$(sed -n 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
  "$USER_HOME/homepage/package.json" | head -1)"
[ -n "$APP_VERSION_ACTUAL" ] || { echo "ERROR: cannot read version from package.json" >&2; exit 13; }
echo "package.json version: $APP_VERSION_ACTUAL"
if [ -n "$APP_VERSION" ] && [ "$APP_VERSION_ACTUAL" != "$APP_VERSION" ]; then
  echo "ERROR: version mismatch: expected=$APP_VERSION actual=$APP_VERSION_ACTUAL" >&2
  echo "       homepage リポジトリの package.json を更新して push してから再実行してください。" >&2
  exit 14
fi
if ! grep -rqsF "$APP_VERSION_ACTUAL" "$USER_HOME/homepage/setup/.next"; then
  echo "WARN: baked version '$APP_VERSION_ACTUAL' not found under setup/.next" >&2
fi

# -----------------------------------------------------------------------------
# 9. イメージ内マニフェスト（サポート時の切り分け用）
# -----------------------------------------------------------------------------
say "manifest: /etc/homepage-image.json"
AWS_VERSION="$(aws --version 2>&1 | awk '{print $1}')"
DOCKER_VERSION="$(docker version --format '{{.Server.Version}}')"
cat > /etc/homepage-image.json <<EOF
{
  "app_version": "$APP_VERSION_ACTUAL",
  "build_id": "$BUILD_ID",
  "built_at": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "base_rootfs_sha256": "$BASE_SHA256",
  "ubuntu": "$(. /etc/os-release && echo "$PRETTY_NAME")",
  "node": "$NODE_VERSION",
  "docker": "$DOCKER_VERSION",
  "awscli": "$AWS_VERSION"
}
EOF
cat /etc/homepage-image.json

say "provision done"

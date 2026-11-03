# newcleus CMS 配布用 WSL イメージの自動ビルド

> **対象:** 別プロジェクト `okamoto53515606/newcleus`（newcleus CMS）
> homepage-v2 用の自動化（`tools/build-wsl-image.ps1`）を newcleus 向けに調整したもの。
> 手順は homepage とほぼ同じで、**リポジトリ・アプリ配置・成果物名・distro 名だけが違う**。

## homepage 版との違い

| 項目 | homepage | newcleus |
|---|---|---|
| リポジトリ | `okamoto53515606/homepage` | `okamoto53515606/newcleus` |
| WSL 内のアプリ配置 | `~/homepage` | `~/newcleus` |
| 成果物 | `homepage-v2-latest.tar.gz` / `.sha256` | `newcleus-latest.tar.gz` / `.sha256` |
| build / verify distro | `homepage-v2-build` / `homepage-v2-verify` | `newcleus-build` / `newcleus-verify` |
| リリースノート | `homepage-release-notes-v<ver>.md` | `newcleus-release-notes-v<ver>.md` |
| 版の確認方法 | `package.json` + `.next` に焼き込んだ `NEXT_PUBLIC_APP_VERSION` | `package.json` + `setup/.next/BUILD_ID`（newcleus は版を焼き込まない） |
| ベース rootfs キャッシュ | `D:\wsl_backup\build\base` | 同じ（**共有**。二重ダウンロードしない） |

distro 名と成果物名が分かれているため、**同じ PC で homepage 版と併用できます**。

## 0. リリースノートの置き場所（最初にやること）

`okamoto53515606/newcleus` の `package.json` の `version` を更新して push したあと、次のパスに置く。

```text
D:\wsl_backup\newcleus-release-notes-v<version>.md
```

例（`package.json` の version が `1.0.6` のとき）:

```text
D:\wsl_backup\newcleus-release-notes-v1.0.6.md
```

| ルール | 内容 |
|---|---|
| ファイル名の `<version>` | newcleus の `package.json` の `version` と**完全一致**（`v` は付けない） |
| リリースタグ | 自動で `v<version>`（例: `v1.0.6`）になる |
| 本文 | そのまま GitHub Release の本文になる |
| 旧形式の互換 | `D:\wsl_backup\release-notes-v1.0.6.md` でも可 |
| 版なし | **不可**。`newcleus-release-notes.md` のように版が無いファイルは使いません（置いてあってもエラーになります） |
| 任意パス | `-NotesFile <path>` で明示指定も可 |

`-Version` を省略した場合は、`D:\wsl_backup` 内の `newcleus-release-notes-v*.md` /
`release-notes-v*.md` のうち**最も新しいバージョン**から自動決定する。

## 1. 実行

```powershell
cd D:\work\homepage-v2-installer

# 1) 生成 + 検証だけ（GitHub には何も作られない / 8〜9 分）
.\newcleus\build-wsl-image.ps1 -SkipRelease

# 2) 成果物を確認してから公開（再検証 + gh release create --latest / 2〜3 分）
.\newcleus\build-wsl-image.ps1 -SkipBuild
```

引数なしで実行すると **公開まで** 進みます（homepage 版と同じ挙動）。

> **why `--latest` を付けているか:** newcleus にはインストーラが無く、配布物は GitHub Releases の
> WSL イメージのみ。`--latest` を付けておくと
> `https://github.com/okamoto53515606/newcleus/releases/latest/download/newcleus-latest.tar.gz`
> で常に最新イメージを取れる（利用者に固定 URL を案内できる）。

### 前提

| 項目 | 要件 |
|---|---|
| WSL | 2.x（`wsl --version` が通る） |
| gh CLI | インストール済み + `gh auth login` 済み（`-SkipRelease` なら不要） |
| 空き容量 | `D:\` に 20GB 以上 |
| ネットワーク | cdimages.ubuntu.com / GitHub / Docker / AWS CLI / nvm |

## 2. 何が自動化されるか

`docs/_temp_newcleus_wsl.md`（手作業メモ）の手順との対応:

| 手作業の手順 | 自動化での扱い |
|---|---|
| 1. `wsl --install` + 対話ユーザー作成 | **廃止**。公式 rootfs を `wsl --import` し、`useradd ubuntu` を非対話で実行 |
| 2. `visudo` で NOPASSWD | `/etc/sudoers.d/99-newcleus` に直接書き、`visudo -cf` で検証 |
| 3. ツール導入（AWS CLI / Node 24 / Docker） | `wsl-image/provision.sh`（`DEBIAN_FRONTEND=noninteractive`） |
| 4. 軽量化 | `wsl-image/cleanup.sh`（順序は 更新 → ビルド → purge → 掃除） |
| 5. 環境チェック | `wsl-image/verify.sh` が import 後に自動実行 |
| 6. リポジトリ取得 + ビルド | `fetch-app.sh --fresh --dist --yes` を newcleus の main から取得して実行 |
| 7. 起動スクリプト確認 | `chmod +x` + `verify.sh` |
| 8. 起動テスト | 検証用 distro に import して `start.sh` → `http://localhost:3001/setup0` が 200 になるまでポーリング |
| 9. export | `wsl --export` → `newcleus-latest.tar` |
| 10. 圧縮 + sha256 | `pigz -9 -p $(nproc)` + PowerShell で SHA256（64 桁 1 行） |
| 11. `gh release create` | `--latest` / `--target <main の SHA>` 付きで自動実行 |

## 3. パラメータ

| パラメータ | 既定 | 説明 |
|---|---|---|
| `-Version` | ノートから推定 | `1.0.6` / `v1.0.6` どちらでも可 |
| `-NotesDir` | `D:\wsl_backup` | ノート探索ディレクトリ |
| `-NotesFile` | （自動解決） | ノートを明示指定 |
| `-WorkDir` | `D:\wsl_backup\build` | ベースイメージ・distro 実体・中間 tar |
| `-OutputDir` | `D:\wsl_backup` | tar.gz / .sha256 / logs |
| `-Repo` | `okamoto53515606/newcleus` | リリース先 |
| `-BaseUrl` | cdimages の noble `current` | ベース rootfs（日付固定にすると再現性が上がる） |
| `-SkipRelease` | off | 検証までで止める |
| `-SkipVerify` | off | import + 起動確認を省略（非推奨） |
| `-SkipBuild` | off | 既存 tar.gz を再利用（検証・公開の再実行用） |
| `-SkipBaseDownload` | off | ベースを再取得しない（キャッシュ必須） |
| `-SkipVersionCheck` | off | `package.json` との一致チェックを省略 |
| `-KeepBuildDistro` | off | build distro を残す（デバッグ） |

## 4. 軽量化・セキュリティ（homepage と同じ方針）

- `apt-get full-upgrade`（依存変更を伴うセキュリティ修正も取り込む）
- ベース rootfs は **SHA256SUMS と照合してから** import
- ベースは `noble`（24.04 LTS）。`/etc/wsl.conf` に `systemd=true` と `default=ubuntu`
- Docker は公式 apt リポジトリから導入し `systemctl enable docker`
- Node.js は nvm で 24 系（CVE-2026-111497 の影響を避ける）。`/etc/profile.d/10-nvm.sh` で `bash -lc` でも見えるようにする
- 軽量化: `snapd` / `cloud-init` / `unattended-upgrades` / `ubuntu-advantage-tools` / `landscape-common` の purge、
  `docker system prune`、`npm cache clean`、`.next/cache` 削除、`/var/lib/apt/lists/*`、docs/man/ロケール削除、
  `/var/log` の truncate（inode 維持）
- 秘匿情報: `~/.bash_history` / `~/.aws` / `~/.ssh` / `~/.npmrc` / `~/.docker/config.json` などを削除し、
  `~/newcleus/.env` に `AKIA...` / `aws_secret_access_key` / `ghp_...` が無いことを検査（ヒットしたら**ビルド失敗**）
- `prompt_history` を配布物から除外（重複対策として cleanup でも削除）
- `/etc/newcleus-image.json` に build_id / base SHA256 / Ubuntu / Node / Docker / AWS CLI / app version / BUILD_ID を記録

> **注意:** WSL のカーネル自体はイメージに含まれない。ホスト側は `wsl --update` で最新化する。

## 5. 検証（リリース前ゲート）

1. `gzip -t` で圧縮ファイルの健全性
2. サイズ < 2 GiB（GitHub Release の単一アセット上限）
3. 圧縮済み tar.gz を**本番と同じ手順で** `wsl --import` し、`verify.sh` を実行
   - `node -v` が v24 系 / `aws --version` が 2 系 / `docker info` 成功
   - `~/newcleus/setup/.next`・`BUILD_ID`・`node_modules`・`start.sh`・`.env` の存在
   - `prompt_history` が**無い**こと
   - `package.json` の version が期待値と一致
   - `sudo -n true`（NOPASSWD）
   - `~/.aws` 等の混入なし、`/etc/wsl.conf` の `default` と `systemd`
4. `start.sh` を起動し `http://localhost:3001/setup0` が 200 を返すまでポーリング
   （ポート 3001 が既に使われている場合はスキップして警告）
5. 検証用 distro を `--terminate` → `--unregister` で破棄

## 6. 失敗したとき

| 症状 | 対処 |
|---|---|
| `リリースノートが見つかりません` | §0 のパスに置く。ファイル名の version を確認 |
| `バージョン不一致` | newcleus の `package.json` を更新して push（raw はキャッシュされるので 1〜2 分待つ） |
| プロンプトで止まる（`続行しますか? [y/N]`） | `provision.sh` の `fetch-app.sh` に `--yes` が付いているか確認 |
| `docker info failed` | `D:\wsl_backup\logs\newcleus-provision-*.log` を確認。`wsl --update` |
| `setup0 が応答しません` | `start.sh` / `.next` を確認。検証 distro を残したい場合は `-KeepBuildDistro` ではなく import ログを参照 |
| 途中で止めたい | `wsl --unregister newcleus-build` / `newcleus-verify` |

ログ: `D:\wsl_backup\logs\newcleus-build-<日時>.log`、`newcleus-provision-*.log`、`newcleus-cleanup-*.log`

## 7. 既知の注意点

- **`wsl --shutdown` は使いません**（他のディストロを巻き込むため）。`wsl --terminate <name>` のみ。
- build / verify 用の distro 名は固定（`newcleus-build` / `newcleus-verify`）。実行前に既存があれば削除する。
- ベースイメージ（約 371MB）は homepage 版と共有キャッシュ。
- 実測時間は未計測（homepage と同構成のため **8〜9 分** の見込み）。計測したらこの表を更新する。
- GitHub ホストの Windows ランナーは WSL2 が動かないため、CI 化する場合はセルフホスト Windows ランナーが必要。

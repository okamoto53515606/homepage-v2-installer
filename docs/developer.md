# homepage-v2-installer

非エンジニアでも `homepage-v2`（AWSベースの個人メディアシステム）のセットアップ画面を簡単に起動できるよう、
WSL2 イメージのダウンロード・取り込み・起動・停止を GUI で行う Windows 用インストーラ。

## 仕組み

```
[配布物 .exe (Inno Setup)]
   ├─ [Code] WSL 状態チェック·自動インストール (UAC 昇格)
   ├─ [Code] tar.gz / sha256 を GitHub Releases からDL (CreateDownloadPage)
   │        キャッシュHIT時はスキップ
   ├─ install-wsl.ps1      ... SHA256検証 → wsl --import
   ├─ HomepageV2Tray.exe   ... タスクトレイ常駐 (起動/停止/バージョン確認/更新)
   └─ uninstall-wsl.ps1    ... アンインストール時に wsl --unregister
```

- WSL ディストリ名: `homepage-v2-latest`
- インストール先: `%LOCALAPPDATA%\HomepageV2`
  - `app\`   … 実行ファイル (トレイ .exe / スクリプト)
  - `wsl\`   … WSL VHDX（実体）
  - `cache\` … DL 済み tar.gz / sha256 キャッシュ
  - `logs\`  … インストール/起動ログ
- 配布 URL（GitHub Releases / 本体リポ `okamoto53515606/homepage` の latest）:
  - tar.gz : `https://github.com/okamoto53515606/homepage/releases/latest/download/homepage-v2-latest.tar.gz`
  - sha256 : `https://github.com/okamoto53515606/homepage/releases/latest/download/homepage-v2-latest.tar.gz.sha256`

## ディレクトリ構成

```
homepage-v2-installer/
├── installer/
│   ├── homepage-v2-installer.iss
│   └── scripts/
│       ├── install-wsl.ps1
│       ├── uninstall-wsl.ps1
│       └── update-wsl-app.ps1   ... バージョン差し替え + 再ビルドのワーカー
├── tray-app/
│   ├── HomepageV2Tray.ps1
│   └── build-exe.ps1
├── tools/
│   ├── make-sha256.ps1
│   ├── build-wsl-image.ps1     ... WSL イメージの生成〜検証〜リリースを 1 コマンド化
│   ├── wsl-image/
│   │   ├── provision.sh        ... build distro 内のツール導入
│   │   ├── cleanup.sh          ... 軽量化 + 秘匿情報スキャン
│   │   └── verify.sh           ... import 後のスモークテスト
│   ├── set-wsl-app-version.ps1 ... 更新テスト用に version を一時的に下げる
│   └── test-update-wsl-app.ps1  ... バージョン確認・更新の自動テスト
├── assets/
│   └── icon.ico   (別途用意)
├── build.ps1
└── README.md
```

## ツールチェーン（脆弱性対応）

| ツール | 要件 | 備考 |
|---|---|---|
| Inno Setup | **7.1.1 推奨**（最低 6.4） | `build.ps1` は Inno Setup 7 → 6 の順に探索。`ArchitecturesAllowed=x64compatible` のため 6.4 以上が必要 |
| ps2exe | **1.0.18 以上** | `tray-app\build-exe.ps1` が不足時に自動更新 |
| Windows PowerShell | 5.1（OS 同梱） | 別途 EOL はないが、ps2exe + WinForms の制約から PS7 へは移行しない |
| Node.js（WSL 内） | 24 LTS | `fetch-app.sh` が 24 未満で警告。イメージ側（本体リポ）で 24 系にする |

- `homepage-v2-installer.iss` の `MinVersion=10.0.22000` で Windows 11 未満を拒否する（README の動作環境と一致）
- 署名（コード署名証明書）は未対応。SmartScreen の警告は README の手順で回避する

## 配布側の手順（okamoがやること）

WSL イメージとインストーラ .exe は **リポジトリを分けてリリース** します。

| 種別 | リポジトリ | タグ例 | latest 指定 |
|---|---|---|---|
| WSL イメージ | `okamoto53515606/homepage` | `v2.0.0`, `v2.1.0`, ... | あり（常に最新を追従） |
| インストーラ（zip） | `okamoto53515606/homepage-v2-installer` | `v1.0.0`, `v1.0.1`, ... | 任意 |

### 1. WSL イメージの生成・圧縮・リリース（本体リポ）

> **自動化:** 以下の 1〜10 の手作業は `tools\build-wsl-image.ps1` で置き換え済み。
> 使い方とリリースノートの命名規則は [wsl-image-automation.md](./wsl-image-automation.md)、
> 手順を追って実行する場合は [wsl-image-release-runbook.md](./wsl-image-release-runbook.md) を参照。
>
> ```powershell
> # package.json を更新して push → D:\wsl_backup\homepage-release-notes-v2.1.2.md を置く →
> .\tools\build-wsl-image.ps1
> ```

WSL 側で tar を export したあと、gzip 圧縮して SHA256 を作成（サイズを約 1/3 に削減）。

```bash
# WSL/Linux 側
cd /mnt/d/wsl_backup
gzip -9 -k homepage-v2-latest.tar                              # -> homepage-v2-latest.tar.gz
sha256sum homepage-v2-latest.tar.gz > homepage-v2-latest.tar.gz.sha256
```

本体リポ `homepage` に **latest として** リリース作成（gh CLI 使用）。

```powershell
# PowerShell
gh release create v2.0.0 `
  D:\wsl_backup\homepage-v2-latest.tar.gz `
  D:\wsl_backup\homepage-v2-latest.tar.gz.sha256 `
  --repo okamoto53515606/homepage `
  --title "v2.0.0" `
  --notes "homepage-v2 リリース" `
  --latest
```

- `--latest` を付けると `releases/latest/download/...` URL がこのリリースを指します。
- インストーラ側は `MyReleaseTag = "latest"` なので、タグ名を意識せず自動追従します。

### 2. ビルド準備

```powershell
# ps2exe
Install-Module ps2exe -Scope CurrentUser

# Inno Setup 6 をインストール
# https://jrsoftware.org/isinfo.php
```

### 3. 一括ビルド

```powershell
.\build.ps1
# -> dist\homepage-v2-installer-setup.exe（インストーラ本体）
# -> dist\homepage-v2-installer-setup.zip（配布用・これをリリースに上げる）
```

### 4. インストーラ zip のリリース（インストーラリポ）

GitHub の Web UI からも OK、gh CLI でも OK。サイズが小さいので Web UI が手軽。

> **exe を直接アップロードしない。** セキュリティ製品やブラウザの制限でダウンロードできない事例が多いため、
> 配布物は必ず `homepage-v2-installer-setup.zip` にする（`build.ps1` が自動生成する）。

```powershell
# gh CLI 使用例
gh release create v1.2.0 `
  D:\work\homepage-v2-installer\dist\homepage-v2-installer-setup.zip `
  --repo okamoto53515606/homepage-v2-installer `
  --title "Installer v1.2.0" `
  --notes "インストーラ v1.2.0"
```

既存リリースの資産を差し替える場合:

```powershell
gh release upload v1.2.0 .\dist\homepage-v2-installer-setup.zip --repo okamoto53515606/homepage-v2-installer --clobber
gh release delete-asset v1.2.0 homepage-v2-installer-setup.exe --repo okamoto53515606/homepage-v2-installer --yes
```

### 5. 配布

上記リリースページの `homepage-v2-installer-setup.zip` のダウンロード URL をユーザーに案内。
利用者には「右クリック → すべて展開 → 中の exe を実行」を案内する。

---

## 設計上のポイント

- **WSL 自動インストール**: インストーラ起動時に WSL2 未導入を検出したら、自動で `wsl --install --no-distribution` を UAC 昇格で実行する（後述）
- **再実行に強い**: 既存ディストリがあれば import スキップ。`cache/` に tar と sha256 ファイルが残っていればダウンロードもスキップ
- **ダウンロード**: Inno Setup の `CreateDownloadPage` / `DownloadPage.Download` を使用（進捗バー表示付き）。`{tmp}` に DL 後、`%LOCALAPPDATA%\HomepageV2\cache` へコピーして再利用できるようにしている
- **整合性検証**: `install-wsl.ps1` 側で `Get-FileHash` による SHA256 検証。不一致時は tar を破棄
- **シングルインスタンス**: トレイは Mutex `Global\HomepageV2InstallerTray` で多重起動防止
- **起動時例外ログ**: `HomepageV2Tray.ps1` は最上部で `trap` を仕掛け、ps2exe ビルドでもスタックトレースを `tray.log` に記録
- **アンインストール**: `wsl --terminate` → `--unregister` → cache 削除。logs/wsl 配下は残す
- **ログ**: install / uninstall / tray それぞれ `%LOCALAPPDATA%\HomepageV2\logs` に出力

## WSL 自動インストールの実装詳細

### フロー (homepage-v2-installer.iss の [Code] セクション)

```
[インストーラ起動]
      ↓
InitializeSetup()
      ↓
IsWslAvailable()  → wsl.exe --status を ewWaitUntilTerminated で実行し ExitCode==0 判定
      ↓ false
TryInstallWsl()
      ├─ ユーザーにダイアログで同意を取る (MB_YESNO)
      ├─ ShellExec('runas', 'wsl.exe', '--install --no-distribution', ...)
      │     → UAC ダイアログ表示 (インストーラ本体は依然一般ユーザ権限のまま)
      ├─ 完了を待ち、再度 IsWslAvailable() で検出
      │     ├─ OK   → WslWasAutoInstalled := True; → インストール継続
      │     └─ NG   → 「再起動をして再試行」と案内しインストール中止
      └─ ユーザー拒否 / runas キャンセル / ExitCodeエラー → インストール中止
      ↓ (WSL使用可)
[ダウンロード → import → インストール完了]
      ↓
NeedRestart() → WslWasAutoInstalled を返す
      ↓ true
[完了画面に「今すぐ再起動 / 後で手動」ラジオ表示]
```

### 設計意図

- **インストーラ本体は `PrivilegesRequired=lowest`** のまま。全体を admin にすると `{localappdata}` が別ユーザーのパスを指す、アンインストーラも admin でしか走らない等の副作用が出るため、**「wsl --install の連邦部分だけ UAC 昇格」** というポリシー
- `wsl --install --no-distribution` を使うのは、不要な既定 Ubuntu を同梱せず WSL ランタイムのみ入れるため（Win10 22H2 / Win11 のみサポートされるオプション）。本インストーラは Windows 11 限定のため安全
- Microsoft 公式は「再起動推奨」としているが、Windows 11 では多くの場合再起動不要でそのまま import 可能。そのため「インストール直後に再度検出、使えたらそのまま進める」フローとし、**万一使えなかった場合のみ「再起動して再試行」を案内**
- `NeedRestart` で True を返すと Inno Setup が完了画面に「今すぐコンピューターを再起動する / 後で手動で再起動する」のラジオを出す。自動インストール経由で WSL を入れたユーザーにだけ表示され、万全を期して推奨させる

### 関連コード

- [installer/homepage-v2-installer.iss](../installer/homepage-v2-installer.iss) `IsWslAvailable` / `TryInstallWsl` / `InitializeSetup` / `NeedRestart`

### 今後トラブルが出た場合の切り分け

| ケース | 判定方法 | 対処 |
|---|---|---|
| Win10 1909 以前 | `--no-distribution` 未対応、ExitCode != 0 | README で Win11 限定と明記済み |
| BIOS で仮想化無効 | wsl --install 完了しても wsl --status エラー | 現状「再起動推奨」ダイアログに画一化。将来チェックを追加したい |
| 企業ポリシーで WSL 禁止 | wsl.exe 自体が起動しない | `Exec` が False 返し → エラー表示済み

## バージョン更新運用

- WSL イメージの更新は本体リポ `homepage` に新しいリリース（`v2.x.y`）を `--latest` 付きで作成するだけ
  - インストーラ側は `latest` を参照しているため、exe の再ビルド不要
- インストーラ .exe の更新は `okamoto53515606/homepage-v2-installer` に `v1.x.y` リリースを作成
- 利用者は**トレイ → 「アプリを更新...」**で WSL 内のアプリだけを更新できる（この機能）
  - Windows 側のインストーラ .exe 自体の更新は従来どおり新しい exe で再インストール
- 更新フローのテスト手順（「最新です」で試せないときのバージョン下げ方法を含む）は
  [update-test.md](./update-test.md) を参照

## バージョン確認・更新機能の設計

### フロー

```
[トレイ] アプリを更新...
   ↓
Show-UpdateDialog
   ├ Update-VersionState
   │   ├ Test-DistroExists           (wsl --list --quiet, UTF-16LE)
   │   ├ test -f ~/homepage/package.json  (bash -lc)
   │   ├ Get-AppVersionFromWsl       (node -p → 失敗時 cat + ConvertFrom-Json)
   │   └ Get-LatestRelease           (GitHub API → 失敗時 releases/latest の 302)
   ↓ 「更新する」+ 確認
   ├ Stop-Server                      (既存を再利用: ポーリング停止 + wsl --terminate)
   ├ powershell -File update-wsl-app.ps1 ... (別プロセス)
   │    ├ lock ファイルで二重実行を拒否
   │    ├ 前提チェック (distro / package.json / .env)
   │    ├ wsl --terminate (手動実行時も安全に)
   │    ├ (~) curl → bash -n → fetch-app.sh --update --build --yes --ref <tag>
   │    ├ 前後の .env SHA256 を記録
   │    └ RESULT=/APPLIED_VERSION=/BACKUP_DIR=/FAILURE_REASON= を出力
   ├ GUI は 200ms 間隔でログファイルをテール（リアルタイム表示）
   ├ 0 なら Start-Server（既存を再利用。ブラウザも開く）
   └ 失敗時: 原因要約 + ログパス + 切り戻し手順を表示
```

### 実装上の判断（ハマりどころ）

| 論点 | 判断 | 理由 |
|---|---|---|
| 進捗の受取 | **ログファイルのテール** | `Application.Run()` 中の PowerShell イベント（`Register-ObjectEvent`）は発火しないため、stdout のイベント購読は不可。子プロセスは UTF-8 のログを書き、GUI は `FileShare.ReadWrite` で差分を読む |
| 非同期処理 | すべて UI タイマ | `.NET` スレッドから TextBox を触らない（クロススレッド例外防止） |
| `wsl.exe` 引数 | `-d` は**引用符なし**、`bash -lc` のコマンドのみ `"` で囲む | `-d "distro"` は `WSL_E_DISTRO_NOT_FOUND` になる（実測） |
| 改行コード | bash に渡す前に CRLF → LF | CRLF のままだと `bash: $'\r': command not found` で即失敗する |
| バージョン取得 | `node -p` → 失敗時 `cat` + `ConvertFrom-Json` | nvm を `~/.bashrc` のみで初期化しているイメージでは `bash -lc` に node が入らない（`homepage-v2-test1` で実測） |
| 最新版の取得 | GitHub API → `releases/latest` の 302 | 未認証 API は 60 req/h で失敗し得るため |
| 比較 | 自前の semver パーサ | `[version]` はプレリリースを扱えず、文字列比較は `2.10.0 < 2.9.0` になる |
| `.env` の扱い | Windows 側にコピーしない（SHA256 のみ記録） | 秘密情報を配布 PC のディスクに増やさない |
| 中止 | 子プロセス Kill + `wsl --terminate` | WSL 内の bash / npm は子プロセスを Kill しても残るため |
| 二重実行 | `logs\update-wsl-app.lock`（PID + 時刻） | GUI 外から手動実行された場合も防ぐ。死んだ PID は自動解除 |
| 失敗時の再起動 | 差し替え前の失敗（`CREATED_BACKUP=0`）のみ自動再起動 | 差し替え後はビルド失敗の可能性があり、勝手に起動しない |

### テスト

```powershell
# 非破壊（semver / 正常系 / API 失敗 / WSL 不在 / 未セットアップ）
.\tools\test-update-wsl-app.ps1

# 更新失敗（fetch-app.sh の URL を 404 に差し替え。~/homepage は変更されない）
.\tools\test-update-wsl-app.ps1 -RunFailureCase

# サポート用: 画面を出さずに状態を JSON で出力（結果は logs\tray.log にも残る）
.\tray-app\HomepageV2Tray.exe -Diagnose -DistroName homepage-v2-test1
```

手動確認（実更新を伴うため任意）:

| ケース | 期待 |
|---|---|
| 最新版で「更新する」 | 「既に最新です…再適用しますか？」→ やめると何もしない |
| オフライン / API 制限 | 最新バージョン「不明」、更新ボタン無効 |
| 未セットアップ | 「未セットアップです」、更新ボタン無効 |
| 更新成功 | 適用後のバージョンが表示され、ヘッダの表示と一致 |
| 更新失敗 | 原因 / ログパス / `~/homepage.old-<ts>` の案内、`.env` は不変 |

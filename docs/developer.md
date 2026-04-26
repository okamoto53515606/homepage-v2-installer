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
   ├─ HomepageV2Tray.exe   ... タスクトレイ常駐 (起動/停止/ブラウザ起動)
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
│       └── uninstall-wsl.ps1
├── tray-app/
│   ├── HomepageV2Tray.ps1
│   └── build-exe.ps1
├── tools/
│   └── make-sha256.ps1
├── assets/
│   └── icon.ico   (別途用意)
├── build.ps1
└── README.md
```

## 配布側の手順（okamoがやること）

WSL イメージとインストーラ .exe は **リポジトリを分けてリリース** します。

| 種別 | リポジトリ | タグ例 | latest 指定 |
|---|---|---|---|
| WSL イメージ | `okamoto53515606/homepage` | `v2.0.0`, `v2.1.0`, ... | あり（常に最新を追従） |
| インストーラ .exe | `okamoto53515606/homepage-v2-installer` | `v1.0.0`, `v1.0.1`, ... | 任意 |

### 1. WSL イメージの生成・圧縮・リリース（本体リポ）

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
# -> dist\homepage-v2-installer-setup.exe
```

### 4. インストーラ .exe のリリース（インストーラリポ）

GitHub の Web UI からも OK、gh CLI でも OK。サイズが小さいので Web UI が手軽。

```powershell
# gh CLI 使用例
gh release create v1.0.0 `
  D:\work\homepage-v2-installer\dist\homepage-v2-installer-setup.exe `
  --repo okamoto53515606/homepage-v2-installer `
  --title "Installer v1.0.0" `
  --notes "インストーラ v1.0.0"
```

### 5. 配布

上記リリースページの `homepage-v2-installer-setup.exe` のダウンロード URL をユーザーに案内。

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
- ユーザー側は **アンインストール → 最新のインストーラ exe で再インストール** で更新
  - （将来的に「更新」ボタンをトレイに追加する余地あり）

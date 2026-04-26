# homepage-v2-installer

非エンジニアでも `homepage-v2`（AWSベースの個人メディアシステム）のセットアップ画面を簡単に起動できるよう、
WSL2 イメージのダウンロード・取り込み・起動・停止を GUI で行う Windows 用インストーラ。

## 仕組み

```
[配布物 .exe (Inno Setup)]
   └─ install-wsl.ps1      ... GitHub Releases から .tar.gz をDL → SHA256検証 → wsl --import
   └─ HomepageV2Tray.exe   ... タスクトレイ常駐 (起動/停止/ブラウザ起動)
   └─ uninstall-wsl.ps1    ... アンインストール時に wsl --unregister
```

- WSL ディストリ名: `homepage-v2-latest`
- インストール先: `%LOCALAPPDATA%\HomepageV2`
  - `app\`   … 実行ファイル
  - `wsl\`   … WSL VHDX（実体）
  - `cache\` … DL中の一時ファイル
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

## 配布側の手順（あなたがやること）

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

## ユーザー側の手順

1. `homepage-v2-installer-setup.exe` をダブルクリック
2. **Windows SmartScreen** が「認識されないアプリ」と警告 → **「詳細情報」→「実行」** をクリック
3. インストール完了（初回のみ約1.1GBのDL、数分程度）
4. スタートメニューから `homepage-v2-installer` を起動
5. タスクトレイのアイコンを右クリック → **「起動 (npm run dev)」**
6. しばらく待つと自動でブラウザが開く（`http://localhost:3001`）
7. 終了するときはトレイから **「停止」**

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| WSL がない | 管理者 PowerShell で `wsl --install` → 再起動 |
| ポート3001 が使用中 | 他のアプリを停止。トレイは「ブラウザを開く」のみ動作 |
| SHA256 不一致 | DL破損。トレイ終了→アンインストール→再インストール |
| 動かない | トレイ右クリック → 「ログフォルダを開く」で `%LOCALAPPDATA%\HomepageV2\logs` を確認 |

## 設計上のポイント

- **再実行に強い**: 既存ディストリがあれば import スキップ。tar キャッシュもハッシュ一致でDL省略
- **再開可能DL**: `Start-BitsTransfer` を使用。失敗時は `Invoke-WebRequest` にフォールバック
- **整合性検証**: 必ず SHA256 検証、不一致時は tar を破棄
- **シングルインスタンス**: トレイは Mutex `Global\HomepageV2InstallerTray` で多重起動防止
- **アンインストール**: `wsl --terminate` → `--unregister` → cache 削除。logs/wsl 配下は残す
- **ログ**: install / uninstall / tray それぞれ `%LOCALAPPDATA%\HomepageV2\logs` に出力

## バージョン更新運用

- WSL イメージの更新は本体リポ `homepage` に新しいリリース（`v2.x.y`）を `--latest` 付きで作成するだけ
  - インストーラ側は `latest` を参照しているため、exe の再ビルド不要
- インストーラ .exe の更新は `okamoto53515606/homepage-v2-installer` に `v1.x.y` リリースを作成
- ユーザー側は **アンインストール → 最新のインストーラ exe で再インストール** で更新
  - （将来的に「更新」ボタンをトレイに追加する余地あり）

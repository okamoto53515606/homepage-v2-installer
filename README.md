# homepage-v2-installer

非エンジニアでも `homepage-v2`（AWSベースの個人メディアシステム）のセットアップ画面を簡単に起動できるよう、
WSL2 イメージのダウンロード・取り込み・起動・停止を GUI で行う Windows 用インストーラ。

## 仕組み

```
[配布物 .exe (Inno Setup)]
   └─ install-wsl.ps1      ... R2 から .tar をDL → SHA256検証 → wsl --import
   └─ HomepageV2Tray.exe   ... タスクトレイ常駐 (起動/停止/ブラウザ起動)
   └─ uninstall-wsl.ps1    ... アンインストール時に wsl --unregister
```

- WSL ディストリ名: `homepage-v2-latest`
- インストール先: `%LOCALAPPDATA%\HomepageV2`
  - `app\`   … 実行ファイル
  - `wsl\`   … WSL VHDX（実体）
  - `cache\` … DL中の一時ファイル
  - `logs\`  … インストール/起動ログ
- 公開 URL（R2）:
  - tar    : `https://pub-a692d5b289c84f6991126101fe2d638d.r2.dev/homepage-v2-latest.tar`
  - sha256 : `https://pub-a692d5b289c84f6991126101fe2d638d.r2.dev/homepage-v2-latest.tar.sha256`

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

### 1. tar の SHA256 ハッシュを生成して R2 にアップ

```powershell
.\tools\make-sha256.ps1 -Tar D:\wsl_backup\homepage-v2-latest.tar
# -> homepage-v2-latest.tar.sha256 ができる
```

R2 バケットに以下2ファイルを配置（毎回更新時に両方差し替え）:
- `homepage-v2-latest.tar`
- `homepage-v2-latest.tar.sha256`

### 2. アイコンを用意

`assets\icon.ico` を配置（256×256 推奨）。無くてもビルド可。

### 3. ビルド準備

```powershell
# ps2exe
Install-Module ps2exe -Scope CurrentUser

# Inno Setup 6 をインストール
# https://jrsoftware.org/isinfo.php
```

### 4. 一括ビルド

```powershell
.\build.ps1
# -> dist\homepage-v2-installer-setup.exe
```

### 5. 配布

`dist\homepage-v2-installer-setup.exe` をユーザーに配布。

---

## ユーザー側の手順

1. `homepage-v2-installer-setup.exe` をダブルクリック
2. **Windows SmartScreen** が「認識されないアプリ」と警告 → **「詳細情報」→「実行」** をクリック
3. インストール完了（初回のみ約3GBのDL、数分〜10分程度）
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

- R2 の `homepage-v2-latest.tar` と `.sha256` を最新に差し替え
- 過去版は別名（例: `homepage-v2-2026-04-26.tar`）でアーカイブ
- ユーザー側は **アンインストール → 最新のインストーラ exe で再インストール** で更新
  - （将来的に「更新」ボタンをトレイに追加する余地あり）

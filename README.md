# homepage-v2-installer 利用者ガイド

## 概要

非エンジニアでも [homepage-v2（AWSベースの個人メディアシステム）](https://github.com/okamoto53515606/homepage)のセットアップ画面を簡単に起動できるよう、
WSL2 イメージのダウンロード・取り込み・起動・停止を GUI で行う Windows 用インストーラ。

- WSL ディストリ名: `homepage-v2-latest`
- インストール先: `%LOCALAPPDATA%\HomepageV2`
  - `app\`   … 実行ファイル
  - `wsl\`   … WSL VHDX（実体）
  - `cache\` … DL中の一時ファイル
  - `logs\`  … インストール/起動/更新ログ
- 配布 URL（GitHub Releases / 本体リポ `okamoto53515606/homepage` の latest）:
  - tar.gz : `https://github.com/okamoto53515606/homepage/releases/latest/download/homepage-v2-latest.tar.gz`
  - sha256 : `https://github.com/okamoto53515606/homepage/releases/latest/download/homepage-v2-latest.tar.gz.sha256`

## 動作環境

| 項目 | 要件 |
|---|---|
| OS | Windows 11（64bit） |
| CPU | x64 アーキテクチャ（仮想化支援機能が有効） |
| メモリ | 8 GB 以上推奨（4 GB でも動作可。WSL2 による追加消費あり） |
| ディスク空き | 10 GB 以上（DL中約1.1GB、VHDX 展開後数 GB） |
| WSL2 | 未導入の場合はインストーラが自動で `wsl --install --no-distribution` を実行（UAC 昇格あり、要 PC 再起動） |
| ネットワーク | GitHub Releases へアクセス可能（初回のみダウンロード；以降はシステム起動のみでオフライン可。**更新機能を使うときは再び接続が必要**） |
| ポート | TCP `3001` がローカルで利用可能であること |
| 権限 | 一般ユーザーで OK（インストーラ本体は管理者権限不要）。WSL 未導入時のみ `wsl --install` で UAC 昇格ダイアログが表示されます |

## 利用方法

### 1. インストール

> スクリーンショット付きの詳細手順: **[docs/installer-setup.md](docs/installer-setup.md)**

1. [Releases ページ](https://github.com/okamoto53515606/homepage-v2-installer/releases/latest) から `homepage-v2-installer-setup.zip` をダウンロード
2. 保存した zip を右クリック → **「すべて展開」**
3. 展開してできた `homepage-v2-installer-setup.exe` をダブルクリック
4. **Windows SmartScreen** が「認識されないアプリ」と警告した場合 → 「詳細情報」 → 「実行」 をクリック
5. ウィザードに従って「次へ」を進める
   - 初回は WSL2 イメージ（約 1.1GB / gzip 圧縮済み）をダウンロードします（回線速度により数分〜数十分）
   - SHA256 検証後、`wsl --import` で取り込みます
6. インストール完了と同時にタスクトレイにアイコンが常駐します

> exe を直接配布すると、セキュリティソフトやブラウザの制限でダウンロードできないことがあるため、
> **zip にまとめて配布**しています（中に `homepage-v2-installer-setup.exe` が入っています）。

### 2. 起動 / 停止

1. タスクトレイの `homepage-v2-installer` アイコンを右クリック
2. **「起動 (npm run dev)」** を選択
3. 数十秒待つと自動でブラウザが開き、セットアップ画面（`http://localhost:3001`）が表示されます
4. 作業を終えたらトレイを右クリック → **「停止」**
5. トレイごと終了したい場合は → **「終了」**（サーバー起動中は確認ダイアログが出ます）

### 3. その他のメニュー

| メニュー | 説明 |
|---|---|
| ブラウザを開く | すでに起動済みなら `http://localhost:3001` を開くだけ |
| アプリを更新... | WSL 内の homepage アプリを最新版に更新（後述） |
| ログフォルダを開く | `%LOCALAPPDATA%\HomepageV2\logs` を開く |
| トレイアイコンダブルクリック | ブラウザを開くショートカット |

### 4. アプリのバージョン確認・更新

> スクリーンショット付きの詳細手順: **[docs/installer-update.md](docs/installer-update.md)**

トレイを右クリック → **「アプリを更新...」** で、WSL 内のアプリ（`~/homepage`）の
現在のバージョンと最新バージョンを確認できます（セットアップ画面のアプリは起動しません）。

| 表示 | 意味 |
|---|---|
| 現在のバージョン | `~/homepage/package.json` の `version` |
| 最新バージョン | GitHub Releases の latest タグ（取得失敗時は「不明」） |
| 適用後のバージョン | 更新後の `version`（更新前は —） |

- 「最新です」：既に最新です。必要なら「再適用（修復）」できます
- 「更新があります」：「更新する」を押してください
- 未セットアップ（`~/homepage` が無い）/ 最新版が取得できない場合はボタンが無効になります

**更新の流れ**

1. 確認ダイアログ（所要 5〜20 分、ネットワーク必須、`.env` は保持）で「はい」
2. セットアップ画面を自動で停止 → 更新コマンドを実行 → 成功したら再起動
3. 進捗ログをリアルタイム表示（30 分でタイムアウト、途中で中止可能）
4. 完了後は「適用後のバージョン」が表示されます

> **重要**: 更新後、公開サイトのコードはまだ古い状態です。
> 完了メッセージの通り、セットアップ画面 → 運用メニュー → 「アプリコード更新」を実行してください。

ログは `%LOCALAPPDATA%\HomepageV2\logs\update-<日時>.log` に保存されます。
更新に失敗した場合、旧ファイルは WSL 内の `~/homepage.old-<timestamp>` に残ります
（画面に切り戻しコマンドが表示されます）。

### 5. アンインストール

- 「アプリと機能」または「インストールされたアプリ」から `homepage-v2-installer` をアンインストール
- WSL ディストリビューション（`homepage-v2-latest`）も自動で削除されます
- `logs\` 以外のキャッシュも削除されます。手動で残りを消したい場合は `%LOCALAPPDATA%\HomepageV2` フォルダごと削除してください

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `wsl --install` 後の再起動を求められる | 案内に従い PC を再起動してからインストーラを再実行 |
| SmartScreen にブロックされる | 「詳細情報」→「実行」をクリック |
| ダウンロードが途中で失敗する | エラー画面で「リトライ」。次回以降は `cache\` の SHA256 ファイルがあれば DL をスキップ |
| SHA256 不一致 | DL破損。`%LOCALAPPDATA%\HomepageV2\cache` フォルダを削除してインストーラ再実行 |
| ポート 3001 が使用中 | 他アプリを停止してから「起動」。すでに起動中の場合は「ブラウザを開く」のみ動作 |
| 「起動」クリックしてもブラウザが開かない | サーバ起動を最大 10 分ポーリングします。トレイ右クリック→「ログフォルダを開く」で `tray.log` を確認 |
| 更新ボタンが押せない | 未セットアップ（`~/homepage` 不在）、または最新バージョンを取得できていません。ネットワークを確認し「再確認」 |
| 更新に失敗した | 画面の「原因」とログを確認。旧ツリーは `~/homepage.old-<timestamp>` に残っています |
| 更新後の画面が古い | セットアップ画面 → 運用メニュー → 「アプリコード更新」を実行（更新コマンドは画像を差し替えません） |
| その他動作不良 | トレイ右クリック → 「ログフォルダを開く」で `%LOCALAPPDATA%\HomepageV2\logs` の `tray.log` / `install-*.log` / `update-*.log` を確認 |

## ドキュメント

### 利用者向け

| ドキュメント | 内容 |
|---|---|
| [docs/installer-setup.md](docs/installer-setup.md) | インストーラーによるセットアップ画面起動手順（スクリーンショット付き） |
| [docs/installer-update.md](docs/installer-update.md) | インストーラーによるアップデート手順（スクリーンショット付き） |

### 開発者向け

| ドキュメント | 内容 |
|---|---|
| [docs/developer.md](docs/developer.md) | ビルド・リリース・設計メモ |
| [docs/wsl-image-automation.md](docs/wsl-image-automation.md) | 配布用 WSL イメージの自動ビルド |
| [docs/wsl-image-release-runbook.md](docs/wsl-image-release-runbook.md) | WSL イメージのリリース実行手順 |
| [docs/update-test.md](docs/update-test.md) | アプリ更新（トレイ）のテスト方法 |
| [newcleus/README.md](newcleus/README.md) | newcleus CMS 用 WSL イメージの自動ビルド（別リポジトリ向け） |

## 開発者向け情報

ビルド・リリース・設計メモは [docs/developer.md](docs/developer.md) を参照してください。

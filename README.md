# homepage-v2-installer 利用者ガイド

## 概要

非エンジニアでも [homepage-v2（AWSベースの個人メディアシステム）](https://github.com/okamoto53515606/homepage)のセットアップ画面を簡単に起動できるよう、
WSL2 イメージのダウンロード・取り込み・起動・停止を GUI で行う Windows 用インストーラ。

- WSL ディストリ名: `homepage-v2-latest`
- インストール先: `%LOCALAPPDATA%\HomepageV2`
  - `app\`   … 実行ファイル
  - `wsl\`   … WSL VHDX（実体）
  - `cache\` … DL中の一時ファイル
  - `logs\`  … インストール/起動ログ
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
| WSL2 | 事前に `wsl --install` 済みであること（未セットアップの場合は下記参照） |
| ネットワーク | GitHub Releases へアクセス可能（初回のみダウンロード；以降はシステム起動のみでオフライン可） |
| ポート | TCP `3001` がローカルで利用可能であること |
| 権限 | 一般ユーザーで OK（管理者権限不要）。ただし WSL 未セットアップ時の `wsl --install` は管理者権限が必要 |

## 利用方法

### 0. 事前準備：WSL2 のセットアップ（未インストールの場合のみ）

既に WSL を使っている場合はこの手順はスキップして「1. インストール」へ進んでください。

WSL の有無が分からない場合も、念のため以下の手順を実施しておくことをおすすめします（既にインストール済みの場合は「既にインストールされています」と表示されるだけで害はありません）。

#### PowerShell を管理者として起動する

1. キーボードの **Windows キー** を押して、スタートメニューを開く
2. `powershell` と入力する
3. 検索結果に表示された **「Windows PowerShell」** を **右クリック**
4. **「管理者として実行」** を選択
5. 「ユーザーアカウント制御」のダイアログが出たら **「はい」** をクリック
6. 青い画面の PowerShell ウィンドウが開く（タイトルバーに「管理者:」と表示されていることを確認）

#### WSL をインストールする

7. 開いた PowerShell ウィンドウに以下のコマンドを入力して **Enter** を押す：

   ```powershell
   wsl --install
   ```

8. ダウンロードと有効化が始まります（数分かかります）
9. 完了メッセージが表示されたら **PC を再起動** する
10. 再起動後、初回ログインで Ubuntu のセットアップ画面が出ることがありますが、本インストーラでは使わないのでそのまま閉じて構いません（ユーザー名/パスワードを聞かれた場合は適当に入力して完了させても OK）

以上で WSL2 の準備は完了です。続けて下記「1. インストール」へ進んでください。

### 1. インストール

1. [Releases ページ](https://github.com/okamoto53515606/homepage-v2-installer/releases/latest) から `homepage-v2-installer-setup.exe` をダウンロード
2. ダブルクリックで起動
3. **Windows SmartScreen** が「認識されないアプリ」と警告した場合 → 「詳細情報」 → 「実行」 をクリック
4. ウィザードに従って「次へ」を進める
   - 初回は WSL2 イメージ（約 1.1GB / gzip 圧縮済み）をダウンロードします（回線速度により数分〜数十分）
   - SHA256 検証後、`wsl --import` で取り込みます
5. インストール完了と同時にタスクトレイにアイコンが常駐します

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
| ログフォルダを開く | `%LOCALAPPDATA%\HomepageV2\logs` を開く |
| トレイアイコンダブルクリック | ブラウザを開くショートカット |

### 4. アンインストール

- 「アプリと機能」または「インストールされたアプリ」から `homepage-v2-installer` をアンインストール
- WSL ディストリビューション（`homepage-v2-latest`）も自動で削除されます
- `logs\` 以外のキャッシュも削除されます。手動で残りを消したい場合は `%LOCALAPPDATA%\HomepageV2` フォルダごと削除してください

## トラブルシューティング

| 症状 | 対処 |
|---|---|
| `wsl --install` を求められる | 管理者 PowerShell で `wsl --install` を実行→PC 再起動→インストーラを再実行 |
| SmartScreen にブロックされる | 「詳細情報」→「実行」をクリック |
| ダウンロードが途中で失敗する | エラー画面で「リトライ」。次回以降は `cache\` の SHA256 ファイルがあれば DL をスキップ |
| SHA256 不一致 | DL破損。`%LOCALAPPDATA%\HomepageV2\cache` フォルダを削除してインストーラ再実行 |
| ポート 3001 が使用中 | 他アプリを停止してから「起動」。すでに起動中の場合は「ブラウザを開く」のみ動作 |
| 「起動」クリックしてもブラウザが開かない | 60秒でタイムアウトします。トレイ右クリック→「ログフォルダを開く」で `tray.log` を確認 |
| その他動作不良 | トレイ右クリック → 「ログフォルダを開く」で `%LOCALAPPDATA%\HomepageV2\logs` の `tray.log` / `install-*.log` を確認 |

## 開発者向け情報

ビルド・リリース・設計メモは [docs/developer.md](docs/developer.md) を参照してください。

# アプリ更新（トレイ）のテスト方法

> **why:** 配布イメージは既に最新版が入っているため、そのままだとトレイが「最新です」になり、
> 更新フロー（差し替え・再ビルド・切り戻し）を試せない。ここでは**今のイメージを壊さずに**
> 「更新があります」の状態を作る方法をまとめる。

## 判定の仕組み

トレイの「アプリを更新...」は 2 つを比較しているだけ。

| 表示 | 比較元 |
|---|---|
| 現在のバージョン | `~/homepage/package.json` の `version` |
| 最新バージョン | GitHub `okamoto53515606/homepage` の latest タグ |
| 適用後のバージョン | 更新コマンド実行後の `version` |

つまり **`package.json` の version を下げれば「更新があります」になる**。

---

## 方法 1: そのまま試す（今の状態で可能）

公開済み latest が `v2.1.2`、`homepage-v2-test1` が `2.1.1` なら、追加操作なしで更新できる。

```powershell
cd D:\work\homepage-v2-installer
.\tray-app\HomepageV2Tray.ps1 -DistroName homepage-v2-test1
```

トレイを右クリック → **「アプリを更新...」** → 「更新があります」を確認 → **更新する**。

> **exe 版のトレイは `homepage-v2-latest` 固定**（`-DistroName` を渡せない）。
> exe で試すときは、書き換える対象も `homepage-v2-latest` にすること。
>
> ```powershell
> .\tools\set-wsl-app-version.ps1 -DistroName homepage-v2-latest -Version 2.1.0
> ```
>
> どの distro を見ているかは `%LOCALAPPDATA%\HomepageV2\logs\tray.log` の
> `CurrentVersion=` / `LatestTag=` で確認できる。

## 方法 2: 何度でも試す（バージョンだけ下げる）

```powershell
# 1) 確認だけ（書き換えない）
.\tools\set-wsl-app-version.ps1 -Version 2.0.9 -DryRun

# 2) 実行（~/homepage/package.json の version だけ変更。ビルドや .next は触らない）
.\tools\set-wsl-app-version.ps1 -Version 2.0.9

# 3) GUI で更新を実行
.\tray-app\HomepageV2Tray.ps1 -DistroName homepage-v2-test1

# 4) 元に戻す（package.json.bak から）
.\tools\set-wsl-app-version.ps1 -Restore
```

- バックアップは `~/homepage/package.json.bak`（既存があれば上書きしない）
- **実際に更新すると** `fetch-app.sh --update` がツリーごと差し替えるので、偽のバージョンは自然に消える
- 画面ヘッダーの版（`NEXT_PUBLIC_APP_VERSION`）は `next build` 時に焼き込まれるため、
  `package.json` を書き換えても**ヘッダーは変わらない**（トレイの判定は `package.json` なので影響なし）

対象 distro を変える場合:

```powershell
.\tools\set-wsl-app-version.ps1 -DistroName homepage-v2-latest -Version 2.1.1
```

## 方法 3: 更新結果の確認ポイント

正常に更新できたかは次で判断する。

```powershell
wsl -d homepage-v2-test1 -u ubuntu -- bash -lc 'head -4 ~/homepage/package.json; ls -d ~/homepage.old-* 2>/dev/null; sha256sum ~/homepage/.env'
```

| 見るもの | 期待値 |
|---|---|
| `package.json` の version | 更新先の版（例 2.1.2） |
| `~/homepage.old-<timestamp>` | 存在する（切り戻し用の退避。確認後に削除してよい） |
| `.env` の sha256 | 更新前と同じ（AWS キー等が消えていない） |
| `~/homepage/setup/setup-state.json` | 残っている |
| `~/homepage/setup/.next` | 再ビルドされ、新しい版が焼き込まれている |
| `%LOCALAPPDATA%\HomepageV2\logs\update-*.log` | `RESULT=SUCCESS` / `APPLIED_VERSION=2.1.2` |

後片付け:

```powershell
wsl -d homepage-v2-test1 -u ubuntu -- bash -lc 'rm -rf ~/homepage.old-*'
```

## 方法 4: 失敗系を試す

`fetch-app.sh` の取得先を 404 に差し替えて「更新失敗 → 元のまま」を検証する。

```powershell
.\tools\test-update-wsl-app.ps1 -RunFailureCase
```

- `RESULT=FAILED` / `FAILURE_REASON=` がログに出る
- `.env` の sha256 が変化しない
- 画面に切り戻し（`~/homepage.old-<timestamp>`）の案内が出る

## 方法 5: 古いリリースのイメージから丸ごと試す

実運用に一番近い（古い `node_modules` / `.next` が入った状態から更新）。

```powershell
curl.exe -L -o D:\wsl_backup\old.tar.gz `
  https://github.com/okamoto53515606/homepage/releases/download/v2.1.0/homepage-v2-latest.tar.gz

wsl --import homepage-v2-test-old D:\wsl_backup\build\distros\homepage-v2-test-old D:\wsl_backup\old.tar.gz

.\tray-app\HomepageV2Tray.ps1 -DistroName homepage-v2-test-old
```

終わったら破棄:

```powershell
wsl --terminate homepage-v2-test-old
wsl --unregister homepage-v2-test-old
Remove-Item D:\wsl_backup\build\distros\homepage-v2-test-old -Recurse -Force
```

## 注意点

- **実環境（`homepage-v2-latest`）で試すと本当に更新される。** 戻したい場合は更新前ツリーが
  `~/homepage.old-<timestamp>` に残るので、そこから `cp -a` で戻すか、`fetch-app.sh --update --ref <旧タグ>` を再実行する。
- トレイの更新は 5〜20 分かかることがある（`next build` を含むため）。途中で止めたいときはダイアログの「中止」。
- `wsl --shutdown` は使わない（他のディストロを巻き込む）。停止は `wsl --terminate <name>`。

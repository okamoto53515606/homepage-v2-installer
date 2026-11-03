<#
.SYNOPSIS
  WSL 内アプリのバージョン表記を一時的に書き換えて「更新があります」状態を作る（更新機能のテスト用）

.DESCRIPTION
  トレイの「アプリを更新...」は、次の 2 つを比較して表示を決める。
    - 現在のバージョン : ~/homepage/package.json の version
    - 最新バージョン   : GitHub Releases の latest タグ

  すでに最新版が入っているイメージでは常に「最新です」になり、更新フローを試せない。
  このスクリプトは package.json の version だけを書き換えて、意図的に
  「更新があります」の状態を作る（ビルドや .next には触らない）。

  元に戻すときは -Restore（package.json.bak から復元）。
  なお、実際に更新を実行すると fetch-app.sh --update がツリーごと差し替えるため、
  偽のバージョンは自然に消える。

.PARAMETER DistroName
  対象のディストリビューション。既定はテスト用の homepage-v2-test1。
  インストール済み環境（homepage-v2-latest）で試す場合は明示的に指定する。

.PARAMETER Version
  書き込む偽のバージョン（例 2.0.9）。latest より小さい値を指定する。

.PARAMETER Restore
  package.json.bak から元に戻す。

.PARAMETER DryRun
  書き換え内容を表示するだけで、ファイルは変更しない。

.EXAMPLE
  .\tools\set-wsl-app-version.ps1 -Version 2.0.9 -DryRun

.EXAMPLE
  .\tools\set-wsl-app-version.ps1 -Version 2.0.9
  # → トレイを -DistroName homepage-v2-test1 で起動して「アプリを更新...」を試す

.EXAMPLE
  .\tools\set-wsl-app-version.ps1 -Restore

.NOTES
  このファイルは UTF-8 BOM 付きで保存すること（Windows PowerShell 5.1 の制約）。
#>

[CmdletBinding()]
param(
    [string]$DistroName = 'homepage-v2-test1',
    [string]$Version,
    [switch]$Restore,
    [switch]$DryRun,
    [string]$WslUser = 'ubuntu',
    [string]$ProjectRoot = '/home/ubuntu/homepage',
    [string]$Repo = 'okamoto53515606/homepage'
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Invoke-Wsl {
    param(
        [Parameter(Mandatory)][string[]]$WslArgs,
        [ValidateSet('utf8', 'unicode')][string]$Encoding = 'utf8'
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = (($WslArgs | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $enc = if ($Encoding -eq 'unicode') {
        New-Object System.Text.UnicodeEncoding($false, $false)
    } else {
        New-Object System.Text.UTF8Encoding($false)
    }
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEndAsync()
    $err = $proc.StandardError.ReadToEndAsync()
    $proc.WaitForExit()
    return [pscustomobject]@{ ExitCode = $proc.ExitCode; Output = $out.Result; Error = $err.Result }
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') { throw "WSL パスに変換できません: $Path" }
    return ('/mnt/{0}/{1}' -f $matches[1].ToLower(), ($matches[2] -replace '\\', '/'))
}

function Get-LatestTag {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -UseBasicParsing -TimeoutSec 20
        return [string]$rel.tag_name
    } catch {
        return $null
    }
}

function Compare-SemVerLocal {
    param([string]$A, [string]$B)
    $pa = (($A -split '[-+]')[0]) -split '\.'
    $pb = (($B -split '[-+]')[0]) -split '\.'
    for ($i = 0; $i -lt 3; $i++) {
        $x = 0; $y = 0
        if ($i -lt $pa.Count) { [void][int]::TryParse($pa[$i], [ref]$x) }
        if ($i -lt $pb.Count) { [void][int]::TryParse($pb[$i], [ref]$y) }
        if ($x -lt $y) { return -1 }
        if ($x -gt $y) { return 1 }
    }
    return 0
}

# --- 前提チェック -------------------------------------------------------------
$distros = @((Invoke-Wsl -WslArgs @('--list', '--quiet') -Encoding 'unicode').Output -split "`r?`n" |
    ForEach-Object { $_.Trim() } | Where-Object { $_ })
if ($distros -notcontains $DistroName) {
    throw "ディストリビューション '$DistroName' が見つかりません。`n利用可能: $($distros -join ', ')"
}

$pkgPath = "$ProjectRoot/package.json"
$bakPath = "$ProjectRoot/package.json.bak"

# --- 復元モード ---------------------------------------------------------------
if ($Restore) {
    $exists = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'test', '-f', $bakPath)
    if ($exists.ExitCode -ne 0) { throw "バックアップがありません: $bakPath" }
    $cp = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cp', '-p', $bakPath, $pkgPath)
    if ($cp.ExitCode -ne 0) { throw "復元に失敗しました: $($cp.Error)" }
    $ver = ((Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cat', $pkgPath)).Output | ConvertFrom-Json).version
    if (-not $ver) { throw '復元後の package.json を解釈できませんでした。' }
    # why: 復元できたら用済み。残すと次回の -n（上書きしない）バックアップが古い内容のまま固定される。
    $null = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'rm', '-f', $bakPath)
    Write-Host "[OK] 復元しました: $DistroName の package.json = $ver （package.json.bak は削除）" -ForegroundColor Green
    return
}

# --- 書き換えモード -----------------------------------------------------------
if (-not $Version) { throw '-Version（例: 2.0.9）を指定するか、-Restore を使ってください。' }
$ver = ($Version.Trim() -replace '^[vV]', '')
if ($ver -notmatch '^\d+\.\d+\.\d+') { throw "バージョンの形式が不正です: $Version" }

$read = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cat', $pkgPath)
if ($read.ExitCode -ne 0) { throw "package.json を読めません: $pkgPath`n$($read.Error)" }
$json = $read.Output
$current = ($json | ConvertFrom-Json).version
Write-Host "現在の version: $current ($DistroName)"

# why: 行頭の "version" だけを 1 箇所置換する（依存関係内の同名キーを巻き込まない）。
$rx = New-Object System.Text.RegularExpressions.Regex '(?m)^(?<pre>[ \t]*"version"[ \t]*:[ \t]*")[^"]*(?<post>")'
$new = $rx.Replace($json, ('${pre}' + $ver + '${post}'), 1)
if ($new -eq $json) { throw 'package.json の version 行を特定できませんでした（形式が想定外です）。' }

$parsed = $null
try { $parsed = $new | ConvertFrom-Json } catch { throw "書き換え後の JSON が不正です: $($_.Exception.Message)" }
if ($parsed.version -ne $ver) { throw "書き換え結果が想定と違います: $($parsed.version) != $ver" }

if ($DryRun) {
    Write-Host "[DryRun] version: $current -> $ver" -ForegroundColor Yellow
} else {
    # バックアップ（既存の .bak は上書きしない = 元の状態を保持）
    $null = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cp', '-p', '-n', $pkgPath, $bakPath)

    $tmp = Join-Path $env:TEMP ("homepage-pkg-{0}.json" -f [guid]::NewGuid().ToString('N').Substring(0, 8))
    [System.IO.File]::WriteAllText($tmp, $new, $script:Utf8NoBom)
    try {
        $cp = Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cp', (ConvertTo-WslPath $tmp), $pkgPath)
        if ($cp.ExitCode -ne 0) { throw "書き込みに失敗しました: $($cp.Error)" }
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }

    $after = ((Invoke-Wsl -WslArgs @('-d', $DistroName, '-u', $WslUser, '--', 'cat', $pkgPath)).Output | ConvertFrom-Json).version
    if ($after -ne $ver) { throw "書き込み後の version が $after になっています（期待: $ver）" }
    Write-Host "[OK] version: $current -> $ver （バックアップ: $bakPath）" -ForegroundColor Green
}

# --- トレイ表示の予測 ---------------------------------------------------------
$latest = Get-LatestTag
if ($latest) {
    $latestNum = ($latest -replace '^[vV]', '')
    $cmp = Compare-SemVerLocal $ver $latestNum
    $state = if ($cmp -lt 0) { '更新があります（更新ボタン有効）' } else { '最新です（更新ボタンは「再適用」）' }
    Write-Host "GitHub latest: $latest → トレイ表示の予測: $state"
} else {
    Write-Host 'GitHub latest を取得できませんでした（オフライン？）。トレイ側も「不明」になります。' -ForegroundColor Yellow
}

Write-Host ''
Write-Host 'GUI で試す場合（インストール済み環境を汚さない）:' -ForegroundColor Cyan
Write-Host ("  .\tray-app\HomepageV2Tray.ps1 -DistroName {0}" -f $DistroName)
Write-Host '  → 右クリック → 「アプリを更新...」→ 更新する'
Write-Host ''
if ($DistroName -ine 'homepage-v2-latest' -and ($distros -contains 'homepage-v2-latest')) {
    Write-Host '注意: インストール済みの exe トレイは「homepage-v2-latest」を見ます（-DistroName は指定できません）。' -ForegroundColor Yellow
    Write-Host '      exe で試すなら: .\tools\set-wsl-app-version.ps1 -DistroName homepage-v2-latest -Version <ver>' -ForegroundColor Yellow
    Write-Host ''
}
Write-Host ("元に戻す: .\tools\set-wsl-app-version.ps1 -DistroName {0} -Restore" -f $DistroName)

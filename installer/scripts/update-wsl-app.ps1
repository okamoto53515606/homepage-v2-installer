<#
.SYNOPSIS
  homepage-v2-installer: WSL 内 homepage アプリの更新（バージョン差し替え + 再ビルド）
.DESCRIPTION
  HomepageV2Tray.exe の「アプリを更新」ダイアログから起動されるワーカー。
  進捗は UTF-8 のログファイルへ追記し、GUI がそのファイルをテールして表示する。
  サポート時の切り分けのため、単体でも実行できる。

  実行内容（仕様固定・変更しないこと）:
    (
      set -euo pipefail
      curl -fsSL --retry 3 -o /tmp/fetch-app.sh \
        https://raw.githubusercontent.com/okamoto53515606/homepage/main/setup/scripts/fetch-app.sh
      bash -n /tmp/fetch-app.sh
      bash /tmp/fetch-app.sh --dir "$HOME/homepage" --update --build --yes --ref <tag>
    )

  事故防止の要点:
    - --fresh は絶対に使わない（.env を env_template.txt から作り直してしまい、
      AWS キー・独自ドメイン設定が消える）
    - installer 側で rm -rf ~/homepage をしない。旧ツリーの退避は fetch-app.sh の
      --update が行う（~/homepage.old-<timestamp>）
    - fetch-app.sh は WSL に同梱されている保証がないため、毎回 raw URL から取得する。
      取得に失敗したら古いスクリプトで続行せず中断する
    - --ref には画面に表示した最新タグを渡す（表示した版と実際に入る版を一致させる）
    - --build 必須（setup の next build をしないと画面が旧版のまま残る）
.PARAMETER TargetVersion
  適用するタグ（例: v2.1.1）。--ref にそのまま渡す。
.PARAMETER ScriptUrl
  fetch-app.sh の取得元。テスト（404 を返す URL に差し替え）用に上書き可能。
.PARAMETER LogFile
  GUI から明示指定されるログファイル。省略時は LogDir 配下に自動採番。
.NOTES
  終了コード:
    0 成功 / 1 更新失敗 / 2 前提エラー（ディストリ不在・未セットアップ）/ 3 二重実行
  出力マーカー（GUI が解析する）:
    RESULT=SUCCESS|FAILED, EXIT_CODE=<n>, APPLIED_VERSION=<x>, BACKUP_DIR=<path>,
    CREATED_BACKUP=0|1, FAILURE_REASON=<text>
#>

[CmdletBinding()]
param(
    [string]$DistroName    = 'homepage-v2-latest',
    [string]$WslUser       = 'ubuntu',
    [Parameter(Mandatory)]
    [string]$TargetVersion,
    [string]$ProjectRoot   = '/home/ubuntu/homepage',
    [string]$ScriptUrl     = 'https://raw.githubusercontent.com/okamoto53515606/homepage/main/setup/scripts/fetch-app.sh',
    [string]$LogDir        = (Join-Path $env:LOCALAPPDATA 'HomepageV2\logs'),
    [string]$LogFile,
    [switch]$SkipStop
)

$ErrorActionPreference = 'Stop'

# --- ログ ---------------------------------------------------------------------
if (-not $LogFile) {
    if (-not (Test-Path -LiteralPath $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }
    $LogFile = Join-Path $LogDir ('update-{0:yyyyMMdd-HHmmss-fff}.log' -f (Get-Date))
}
if (-not (Test-Path -LiteralPath (Split-Path -Parent $LogFile))) {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogFile) -Force | Out-Null
}
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try {
        [System.IO.File]::AppendAllText($LogFile, $line + "`r`n", $script:Utf8NoBom)
    } catch {}
    # 子プロセスは GUI から CreateNoWindow で起動されるため、ここは主に手動実行用。
    # 出力エンコーディングを UTF-8 にしておく（手動リダイレクト時の文字化け対策）。
    try { [Console]::OutputEncoding = $script:Utf8NoBom } catch {}
    Write-Host $line
}

trap {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    try { Write-Log $_.ScriptStackTrace 'ERROR' } catch {}
    Write-Log 'RESULT=FAILED'
    Write-Log 'EXIT_CODE=1'
    Write-Log ("FAILURE_REASON=" + $_.Exception.Message)
    try {
        if ($LockFile) { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue }
    } catch {}
    exit 1
}

# --- ロック（二重実行防止） ----------------------------------------------------
$LockFile = Join-Path (Split-Path -Parent $LogFile) 'update-wsl-app.lock'
if (Test-Path -LiteralPath $LockFile) {
    $stale = $true
    try {
        $info = Get-Content -LiteralPath $LockFile -Raw -ErrorAction Stop | ConvertFrom-Json
        if ($info.Pid) {
            $alive = Get-Process -Id ([int]$info.Pid) -ErrorAction SilentlyContinue
            if ($alive) {
                # 24 時間以上前のロックは PID 再利用の可能性が高いので無視する
                $age = (Get-Date) - [datetime]$info.Started
                if ($age.TotalHours -lt 24) { $stale = $false }
            }
        }
    } catch {
        # 壊れたロックは無視して上書きする
    }
    if (-not $stale) {
        Write-Log "既に更新が実行中です (PID=$($info.Pid))。二重実行はできません。" 'ERROR'
        Write-Log 'RESULT=FAILED'
        Write-Log 'EXIT_CODE=3'
        Write-Log 'FAILURE_REASON=別の更新処理が実行中です。完了を待ってから再実行してください。'
        exit 3
    }
    Write-Log "古いロックファイルを無視します: $LockFile" 'WARN'
    Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
}
try {
    $lockBody = [pscustomobject]@{ Pid = $PID; Started = (Get-Date).ToString('o'); TargetVersion = $TargetVersion } | ConvertTo-Json -Compress
    Set-Content -LiteralPath $LockFile -Value $lockBody -Encoding ASCII
} catch {
    Write-Log "ロックファイルを作成できません（続行します）: $($_.Exception.Message)" 'WARN'
}

function Remove-LockFile {
    try { Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue } catch {}
}

# --- WSL 呼び出しヘルパ --------------------------------------------------------
# wsl.exe は -d の値を引用符付きで渡すと解決できない（WSL_E_DISTRO_NOT_FOUND）。
# ディストリ名・ユーザー名は引用せず、bash -lc に渡すコマンドだけを 1 引数として
# ダブルクォートし、内部の " は \" にエスケープする。
function New-WslBashArgs {
    param([string]$BashCommand)
    $escaped = $BashCommand -replace '"', '\"'
    return '-d {0} -u {1} -- bash -lc "{2}"' -f $DistroName, $WslUser, $escaped
}

function Invoke-WslBashCapture {
    param([string]$BashCommand, [int]$TimeoutSec = 60)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $psi.Arguments              = New-WslBashArgs -BashCommand $BashCommand
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding  = $script:Utf8NoBom
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        return @{ ExitCode = -1; Output = ''; Error = "タイムアウト ($TimeoutSec 秒)" }
    }
    return @{ ExitCode = $proc.ExitCode; Output = $outTask.Result; Error = $errTask.Result }
}

function Get-WslDistroNames {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $psi.Arguments              = '--list --quiet'
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    # wsl.exe 自身の制御メッセージは UTF-16LE
    $psi.StandardOutputEncoding = New-Object System.Text.UnicodeEncoding($false, $false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $out = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    return @($out -split "`r?`n" | ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } | Where-Object { $_ })
}

function Get-AppVersion {
    # 第一候補: 仕様どおり node -p（login shell で nvm の node を拾う）
    $node = Invoke-WslBashCapture -BashCommand "node -p `"require('$ProjectRoot/package.json').version`"" -TimeoutSec 60
    if ($node.ExitCode -eq 0 -and $node.Output.Trim()) {
        $v = ($node.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1).Trim()
        if ($v) { return $v }
    }
    # フォールバック: nvm が ~/.bashrc のみのイメージでは bash -lc で node が見つからない
    $cat = Invoke-WslBashCapture -BashCommand "cat $ProjectRoot/package.json" -TimeoutSec 60
    if ($cat.ExitCode -eq 0 -and $cat.Output.Trim()) {
        try { return [string](($cat.Output | ConvertFrom-Json).version) } catch {}
    }
    return $null
}

function Get-EnvHash {
    $r = Invoke-WslBashCapture -BashCommand "sha256sum $ProjectRoot/.env 2>/dev/null | cut -d' ' -f1" -TimeoutSec 60
    if ($r.ExitCode -eq 0) { return $r.Output.Trim() }
    return $null
}

function Get-BackupDirs {
    $r = Invoke-WslBashCapture -BashCommand "ls -1d $ProjectRoot.old-* 2>/dev/null || true" -TimeoutSec 60
    if ($r.ExitCode -ne 0) { return @() }
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Get-FailureSummary {
    param([string[]]$Lines)
    $patterns = @(
        @{ Re = 'Could not resolve host|curl: \(6\)';                     Msg = 'ネットワークに接続できません（DNS 解決失敗）。回線状況を確認してください。' },
        @{ Re = 'curl: \(7\)|Failed to connect|Connection refused';        Msg = 'ネットワークに接続できません（接続拒否）。プロキシ/ファイアウォールを確認してください。' },
        @{ Re = 'curl: \(22\)|404: Not Found';                             Msg = '取得先が見つかりません（URL または --ref のタグが誤っている可能性）。' },
        @{ Re = 'curl: \(35\)|SSL|TLS';                                    Msg = 'TLS 接続に失敗しました。証明書/プロキシを確認してください。' },
        @{ Re = 'npm ERR!|ERESOLVE|ETIMEDOUT';                             Msg = 'npm install / next build に失敗しました。ログの npm ERR! を確認してください。' },
        @{ Re = '\.env がありません';                                       Msg = '~/homepage/.env が見つかりません（未セットアップ）。' },
        @{ Re = 'npm が見つかりません';                                      Msg = 'WSL 内に npm がありません（Node.js 24 系の導入が必要）。' },
        @{ Re = '\[エラー\]';                                               Msg = 'fetch-app.sh がエラーを返しました。ログの [エラー] 行を確認してください。' }
    )
    for ($i = $Lines.Count - 1; $i -ge 0; $i--) {
        $line = $Lines[$i]
        if (-not $line) { continue }
        foreach ($p in $patterns) {
            if ($line -match $p.Re) { return $p.Msg + ' 詳細: ' + $line.Trim() }
        }
    }
    $last = $Lines | Where-Object { $_.Trim() } | Select-Object -Last 1
    if ($last) { return ('最後の出力: ' + $last.Trim()) }
    return '原因を特定できませんでした。ログ全体を確認してください。'
}

# --- メイン --------------------------------------------------------------------
Write-Log '=== update-wsl-app.ps1 ==='
Write-Log "Distro        : $DistroName"
Write-Log "WslUser       : $WslUser"
Write-Log "TargetVersion : $TargetVersion"
Write-Log "ScriptUrl     : $ScriptUrl"
Write-Log "ProjectRoot   : $ProjectRoot"
Write-Log "LogFile       : $LogFile"

if ($TargetVersion -notmatch '^[vV]?\d+\.\d+\.\d+([-+][0-9A-Za-z.\-]+)?$') {
    Write-Log "TargetVersion の形式が不正です: '$TargetVersion'（例: v2.1.1）" 'ERROR'
    Write-Log 'RESULT=FAILED'; Write-Log 'EXIT_CODE=2'
    Write-Log 'FAILURE_REASON=最新バージョンの形式が不正です。'
    Remove-LockFile
    exit 2
}

# 1) ディストリの存在
$distros = @()
try { $distros = Get-WslDistroNames } catch {}
if (-not ($distros | Where-Object { $_ -eq $DistroName })) {
    Write-Log "WSL ディストリビューション '$DistroName' が見つかりません。インストーラを再実行してください。" 'ERROR'
    Write-Log 'RESULT=FAILED'; Write-Log 'EXIT_CODE=2'
    Write-Log 'FAILURE_REASON=WSL ディストリビューションが見つかりません。'
    Remove-LockFile
    exit 2
}

# 2) 未セットアップ判定
$probe = Invoke-WslBashCapture -BashCommand "test -f $ProjectRoot/package.json && echo YES || echo NO" -TimeoutSec 120
if ($probe.ExitCode -ne 0 -or $probe.Output.Trim() -ne 'YES') {
    Write-Log "$ProjectRoot が見つかりません（未セットアップ）。" 'ERROR'
    if ($probe.Error) { Write-Log $probe.Error 'ERROR' }
    Write-Log 'RESULT=FAILED'; Write-Log 'EXIT_CODE=2'
    Write-Log 'FAILURE_REASON=~/homepage が存在しません（未セットアップ）。'
    Remove-LockFile
    exit 2
}
$envProbe = Invoke-WslBashCapture -BashCommand "test -f $ProjectRoot/.env && echo YES || echo NO" -TimeoutSec 120
if ($envProbe.Output.Trim() -ne 'YES') {
    Write-Log "$ProjectRoot/.env がありません。--update は .env 必須のため中止します。" 'ERROR'
    Write-Log 'RESULT=FAILED'; Write-Log 'EXIT_CODE=2'
    Write-Log 'FAILURE_REASON=~/homepage/.env がありません（更新には .env が必要です）。'
    Remove-LockFile
    exit 2
}

# 3) 事前状態の記録（.env は内容を出さずハッシュのみ）
$envHashBefore = Get-EnvHash
$backupsBefore = Get-BackupDirs
Write-Log "ENV_SHA256_BEFORE=$envHashBefore"
if ($backupsBefore.Count -gt 0) { Write-Log ("BACKUPS_BEFORE=" + ($backupsBefore -join ',')) }

# 4) 旧アプリを停止（手動実行時も安全にする。GUI 側でも停止済み）
if (-not $SkipStop) {
    Write-Log "既存プロセスを停止します: wsl --terminate $DistroName"
    try {
        & wsl.exe --terminate $DistroName 2>&1 | ForEach-Object { Write-Log ("terminate: " + $_) }
    } catch {
        Write-Log "wsl --terminate に失敗（続行します）: $($_.Exception.Message)" 'WARN'
    }
}

# 5) 更新コマンド（仕様固定）
$bashCommand = @"
(
  set -euo pipefail
  curl -fsSL --retry 3 -o /tmp/fetch-app.sh $ScriptUrl
  bash -n /tmp/fetch-app.sh
  bash /tmp/fetch-app.sh --dir "`$HOME/homepage" --update --build --yes --ref $TargetVersion
) 2>&1
"@

# Windows の改行（CRLF）が混ざると bash が `$'\r': command not found` で落ちるため LF に正規化する
$bashCommand = $bashCommand -replace "`r`n", "`n"
Write-Log '--- 更新コマンドを実行します ---'
Write-Log $bashCommand.Trim()

$updateLines = New-Object System.Collections.Generic.List[string]
$exitCode = 1
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName               = 'wsl.exe'
$psi.Arguments              = New-WslBashArgs -BashCommand $bashCommand
$psi.UseShellExecute        = $false
$psi.CreateNoWindow         = $true
$psi.RedirectStandardOutput = $true
# stderr は bash 側で 2>&1 により stdout に統合している。
# 未読の stderr パイプが詰まる事故を避けるため、こちらは受けない。
$psi.RedirectStandardError  = $false
$psi.StandardOutputEncoding = $script:Utf8NoBom

$proc = $null
try {
    $proc = [System.Diagnostics.Process]::Start($psi)
} catch {
    Write-Log "wsl.exe を起動できません: $($_.Exception.Message)" 'ERROR'
    Write-Log 'RESULT=FAILED'; Write-Log 'EXIT_CODE=1'
    Write-Log ("FAILURE_REASON=wsl.exe を起動できません: " + $_.Exception.Message)
    Remove-LockFile
    exit 1
}

# 行情報を逐次ログへ流す（GUI はこのファイルをテールする）
while ($true) {
    $line = $proc.StandardOutput.ReadLine()
    if ($null -eq $line) { break }
    $updateLines.Add($line)
    Write-Log $line
}
$proc.WaitForExit()
$exitCode = $proc.ExitCode

Write-Log "--- 更新コマンド終了 (ExitCode=$exitCode) ---"

# 6) 事後状態
$envHashAfter = Get-EnvHash
$backupsAfter = Get-BackupDirs
$createdBackups = @($backupsAfter | Where-Object { $backupsBefore -notcontains $_ })
$backupDir = $null
if ($createdBackups.Count -gt 0) { $backupDir = $createdBackups[-1] }
Write-Log "ENV_SHA256_AFTER=$envHashAfter"
if ($envHashBefore -and $envHashAfter) {
    if ($envHashBefore -eq $envHashAfter) { Write-Log '.env は更新前後で同一です（引き継ぎ成功）' }
    else { Write-Log '.env のハッシュが変化しました。内容を確認してください。' 'WARN' }
}

$appliedVersion = $null
if ($exitCode -eq 0) {
    $appliedVersion = Get-AppVersion
    Write-Log "APPLIED_VERSION=$appliedVersion"
    Write-Log ("CREATED_BACKUP=" + $(if ($createdBackups.Count -gt 0) { 1 } else { 0 }))
    if ($backupDir) { Write-Log "BACKUP_DIR=$backupDir" }
    Write-Log 'RESULT=SUCCESS'
    Write-Log 'EXIT_CODE=0'
    Write-Log ''
    Write-Log '完了しました。'
    if ($appliedVersion) { Write-Log "適用後のバージョン: v$appliedVersion" }
    if ($backupDir) { Write-Log "旧ツリー: $backupDir （動作確認後に削除してください: rm -rf '$backupDir'）" }
    Write-Log '※ 公開サイトのコードはまだ古いので、セットアップ画面 → 運用メニュー → 「アプリコード更新」を実行してください。'
    Remove-LockFile
    exit 0
}

# 7) 失敗時の要約
$reason = Get-FailureSummary -Lines $updateLines.ToArray()
Write-Log '' 
Write-Log "[失敗] 更新に失敗しました (ExitCode=$exitCode)" 'ERROR'
Write-Log ("[原因の要約] " + $reason) 'ERROR'
Write-Log ("ログ: " + $LogFile) 'ERROR'
Write-Log ("CREATED_BACKUP=" + $(if ($createdBackups.Count -gt 0) { 1 } else { 0 }))
if ($backupDir) {
    Write-Log "BACKUP_DIR=$backupDir"
    Write-Log "切り戻しは $backupDir に残っています。" 'ERROR'
    Write-Log "切り戻しコマンド: rm -rf $ProjectRoot && mv '$backupDir' $ProjectRoot" 'ERROR'
} else {
    Write-Log '旧ツリーは差し替え前のため、~/homepage は変更されていません。' 'ERROR'
}
Write-Log 'RESULT=FAILED'
Write-Log "EXIT_CODE=$exitCode"
Write-Log ("FAILURE_REASON=" + $reason)
Remove-LockFile
exit $exitCode

<#
.SYNOPSIS
  「WSL 内アプリのバージョン確認・更新」の自動テスト
.DESCRIPTION
  以下を検証する（既定は非破壊。更新の成功実行はしない）:
    1. semver 比較（2.10.0 > 2.9.0、プレリリース等）
    2. 正常系のバージョン取得（homepage-v2-test1 等の検証用ディストリ）
    3. GitHub API 失敗時に「不明」になり更新不可になること
    4. WSL 未取り込み時に nodistro になること
    5. ~/homepage 不在時に notsetup になること
    6. 更新コマンド失敗時に RESULT=FAILED / 切り戻し表示 / .env 不変であること（-RunFailureCase）
.PARAMETER DistroName
  検証に使うディストリ。既定は homepage-v2-test1（未導入なら -DistroName で指定）。
.PARAMETER RunFailureCase
  fetch-app.sh の取得先を 404 に差し替えて「更新失敗」を再現する。
  失敗は curl の時点で止まるため、~/homepage は変更されない。
.EXAMPLE
  .\tools\test-update-wsl-app.ps1 -RunFailureCase
#>

[CmdletBinding()]
param(
    [string]$DistroName = 'homepage-v2-test1',
    [switch]$RunFailureCase,
    [int]$TimeoutSec = 300
)

$ErrorActionPreference = 'Stop'
$repoRoot   = Split-Path -Parent $PSScriptRoot
$trayScript = Join-Path $repoRoot 'tray-app\HomepageV2Tray.ps1'
$updatePs1  = Join-Path $repoRoot 'installer\scripts\update-wsl-app.ps1'

$script:Pass = 0
$script:Fail = 0

function Assert-Equal {
    param($Expected, $Actual, [string]$Name)
    if ($Expected -eq $Actual) {
        $script:Pass++
        Write-Host ("  [PASS] {0} = {1}" -f $Name, $Actual) -ForegroundColor Green
    } else {
        $script:Fail++
        Write-Host ("  [FAIL] {0}: expected=[{1}] actual=[{2}]" -f $Name, $Expected, $Actual) -ForegroundColor Red
    }
}

function Invoke-Diagnose {
    param([string[]]$ExtraArgs = @())
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $trayScript, '-Diagnose') + $ExtraArgs
    $json = & powershell.exe @argList 2>&1 | Out-String
    try {
        return ($json | ConvertFrom-Json)
    } catch {
        Write-Host "  [FAIL] 診断モードの出力を JSON として解釈できません:" -ForegroundColor Red
        Write-Host $json
        $script:Fail++
        return $null
    }
}

function Invoke-WslCaptureText {
    param([string]$BashCommand)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $escaped                    = $BashCommand -replace '"', '\"'
    $psi.Arguments              = '-d {0} -u ubuntu -- bash -lc "{1}"' -f $DistroName, $escaped
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
    $psi.StandardErrorEncoding  = New-Object System.Text.UTF8Encoding($false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit(60 * 1000)) { try { $proc.Kill() } catch {} ; return @{ ExitCode = -1; Output = ''; Error = 'timeout' } }
    return @{ ExitCode = $proc.ExitCode; Output = $outTask.Result; Error = $errTask.Result }
}

# --- 1. semver ---------------------------------------------------------------
Write-Host '=== [1/6] semver 比較 ===' -ForegroundColor Cyan
$tokens = $null
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($trayScript, [ref]$tokens, [ref]$parseErrors)
if ($parseErrors.Count -gt 0) {
    throw "トレイスクリプトの構文エラー: $($parseErrors[0].Message)"
}
$wanted = @('ConvertTo-SemVer', 'Compare-SemVer')
foreach ($fn in $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)) {
    if ($wanted -contains $fn.Name) {
        . ([scriptblock]::Create($fn.Extent.Text))
    }
}
if (-not (Get-Command Compare-SemVer -ErrorAction SilentlyContinue)) {
    throw 'Compare-SemVer をトレイスクリプトから読み出せませんでした。'
}
Assert-Equal 1 (Compare-SemVer '2.10.0' '2.9.0') 'Compare-SemVer 2.10.0 vs 2.9.0'
Assert-Equal -1 (Compare-SemVer '2.9.0' '2.10.0') 'Compare-SemVer 2.9.0 vs 2.10.0'
Assert-Equal 0 (Compare-SemVer 'v2.1.1' '2.1.1') 'Compare-SemVer v2.1.1 vs 2.1.1'
Assert-Equal 0 (Compare-SemVer '2.1' '2.1.0') 'Compare-SemVer 2.1 vs 2.1.0'
Assert-Equal -1 (Compare-SemVer '2.1.1-beta.1' '2.1.1') 'Compare-SemVer prerelease < release'
Assert-Equal -1 (Compare-SemVer '2.1.1-beta.2' '2.1.1-beta.10') 'Compare-SemVer beta.2 < beta.10'
Assert-Equal 0 (Compare-SemVer '2.1.1+build.5' '2.1.1') 'Compare-SemVer build metadata 無視'
Assert-Equal $null (Compare-SemVer 'not-a-version' '1.0.0') 'Compare-SemVer 不正値は $null'

# --- 2. 正常系 ----------------------------------------------------------------
Write-Host '=== [2/6] 正常系（バージョン取得） ===' -ForegroundColor Cyan
$normal = Invoke-Diagnose -ExtraArgs @('-DistroName', $DistroName)
if ($normal) {
    Assert-Equal $true  $normal.DistroExists   'DistroExists'
    Assert-Equal $true  $normal.HomepageExists 'HomepageExists'
    Write-Host ("  CurrentVersion={0} LatestVersion={1} Source={2} Comparison={3}" -f `
        $normal.CurrentVersion, $normal.LatestVersion, $normal.LatestSource, $normal.Comparison) -ForegroundColor DarkGray
    if ($normal.CurrentVersion -and $normal.LatestVersion) {
        $expected = if ((Compare-SemVer $normal.CurrentVersion $normal.LatestVersion) -lt 0) { 'update' } else { 'uptodate' }
        Assert-Equal $expected $normal.Comparison 'Comparison'
    }
}

# --- 3. GitHub API 失敗 -------------------------------------------------------
Write-Host '=== [3/6] GitHub API 失敗（オフライン / レート制限） ===' -ForegroundColor Cyan
$bad = Invoke-Diagnose -ExtraArgs @(
    '-DistroName', $DistroName,
    '-GitHubApiUrl', 'https://127.0.0.1:1/nope',
    '-ReleasesLatestUrl', 'https://127.0.0.1:1/nope')
if ($bad) {
    Assert-Equal $null   $bad.LatestVersion 'LatestVersion（不明）'
    Assert-Equal $false  $bad.CanUpdate     'CanUpdate（更新ボタン無効）'
    Assert-Equal 'unknown' $bad.Comparison  'Comparison'
}

# --- 4. WSL 未取り込み --------------------------------------------------------
Write-Host '=== [4/6] WSL 未取り込み ===' -ForegroundColor Cyan
$noDistro = Invoke-Diagnose -ExtraArgs @('-DistroName', '__no_such_distro__')
if ($noDistro) {
    Assert-Equal $false $noDistro.DistroExists 'DistroExists'
    Assert-Equal 'nodistro' $noDistro.Comparison 'Comparison'
    Assert-Equal $false $noDistro.CanUpdate 'CanUpdate'
}

# --- 5. ~/homepage 不在 -------------------------------------------------------
Write-Host '=== [5/6] ~/homepage 不在（未セットアップ） ===' -ForegroundColor Cyan
$notSetup = Invoke-Diagnose -ExtraArgs @('-DistroName', $DistroName, '-ProjectRoot', '/home/ubuntu/__none__')
if ($notSetup) {
    Assert-Equal $true  $notSetup.DistroExists   'DistroExists'
    Assert-Equal $false $notSetup.HomepageExists 'HomepageExists'
    Assert-Equal 'notsetup' $notSetup.Comparison 'Comparison'
    Assert-Equal $false $notSetup.CanUpdate      'CanUpdate'
}

# --- 6. 更新失敗（curl 404）---------------------------------------------------
if ($RunFailureCase) {
    Write-Host '=== [6/6] 更新コマンド失敗（ScriptUrl を 404 に差し替え） ===' -ForegroundColor Cyan
    $before = Invoke-WslCaptureText -BashCommand 'sha256sum $HOME/homepage/.env 2>/dev/null | cut -d" " -f1'
    $logDir = Join-Path $env:TEMP ('homepage-v2-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
    $logFile = Join-Path $logDir 'update-test.log'

    $argList = @(
        '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $updatePs1,
        '-DistroName', $DistroName,
        '-TargetVersion', 'v0.0.0-test',
        '-ScriptUrl', 'https://raw.githubusercontent.com/okamoto53515606/homepage/main/setup/scripts/__not_found__.sh',
        '-LogDir', $logDir, '-LogFile', $logFile, '-SkipStop'
    )
    $proc = Start-Process -FilePath 'powershell.exe' -ArgumentList $argList -Wait -PassThru -NoNewWindow
    Assert-Equal $true ($proc.ExitCode -ne 0) '終了コードが非 0'
    $content = if (Test-Path $logFile) {
        [System.IO.File]::ReadAllText($logFile, (New-Object System.Text.UTF8Encoding($false)))
    } else { '' }
    Assert-Equal $true ($content -match 'RESULT=FAILED') 'RESULT=FAILED が記録される'
    Assert-Equal $true ($content -match 'FAILURE_REASON=') 'FAILURE_REASON が記録される'
    Assert-Equal $true ($content -match '変更されていません|に残っています') '切り戻し/無変更の案内が記録される'

    $after = Invoke-WslCaptureText -BashCommand 'sha256sum $HOME/homepage/.env 2>/dev/null | cut -d" " -f1'
    Assert-Equal $before.Output.Trim() $after.Output.Trim() '.env が変化していない'
    Write-Host ("  ログ: {0}" -f $logFile) -ForegroundColor DarkGray
} else {
    Write-Host '=== [6/6] 更新失敗ケースは -RunFailureCase 指定時に実行します ===' -ForegroundColor DarkYellow
}

Write-Host ''
Write-Host ("結果: PASS={0} FAIL={1}" -f $script:Pass, $script:Fail) -ForegroundColor $(if ($script:Fail -eq 0) { 'Green' } else { 'Red' })
if ($script:Fail -ne 0) { exit 1 }
exit 0

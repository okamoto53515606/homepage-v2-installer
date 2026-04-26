<#
.SYNOPSIS
  homepage-v2-installer: WSL2 イメージの検証・インポート
.DESCRIPTION
  Inno Setup の [Run] セクションから呼び出される想定。
  ダウンロードは Inno Setup 側 (CreateDownloadPage) で進捗表示付きで実施済み。
  本スクリプトは以下を担当:
    - SHA256 検証
    - 既存ディストリ判定 (再実行に強い)
    - wsl --import
.PARAMETER TarFile
  ダウンロード済み tar ファイルのフルパス
.PARAMETER ExpectedSha256
  期待される SHA256 (16進64文字, 小文字)
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string]$TarFile,
    [Parameter(Mandatory)] [string]$ExpectedSha256,
    [string]$DistroName = 'homepage-v2-latest',
    [string]$BaseDir    = (Join-Path $env:LOCALAPPDATA 'HomepageV2'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

$WslDir = Join-Path $BaseDir 'wsl'
$LogDir = Join-Path $BaseDir 'logs'
foreach ($d in @($BaseDir, $WslDir, $LogDir)) {
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$LogFile = Join-Path $LogDir ('install-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

trap {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    Write-Log $_.ScriptStackTrace 'ERROR'
    exit 1
}

Write-Log "=== install-wsl.ps1 ==="
Write-Log "Distro      : $DistroName"
Write-Log "TarFile     : $TarFile"
Write-Log "ExpectedSHA : $ExpectedSha256"

if (-not (Test-Path $TarFile)) {
    throw "tar が見つかりません: $TarFile"
}
$ExpectedSha256 = $ExpectedSha256.ToLower().Trim()
if ($ExpectedSha256 -notmatch '^[0-9a-f]{64}$') {
    throw "ExpectedSha256 の形式が不正: '$ExpectedSha256'"
}

# --- WSL 利用可能チェック -----------------------------------------------------
try {
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wsl --status が失敗 (ExitCode=$LASTEXITCODE)" }
} catch {
    Write-Log "WSL が利用できません。`wsl --install` 実施後に再起動してください。" 'ERROR'
    throw
}

# --- 既存ディストリ判定 -------------------------------------------------------
$prev = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $list = (& wsl.exe --list --quiet) 2>$null
} finally {
    [Console]::OutputEncoding = $prev
}
$exists = $false
if ($list) { $exists = ($list | Where-Object { $_.Trim() -eq $DistroName }).Count -gt 0 }

if ($exists -and -not $Force) {
    Write-Log "既存ディストリ '$DistroName' を検出。インポートをスキップします。"
    exit 0
}

if ($exists -and $Force) {
    Write-Log "Force 指定: 既存 '$DistroName' を解除します"
    & wsl.exe --terminate $DistroName | Out-Null
    & wsl.exe --unregister $DistroName
    if ($LASTEXITCODE -ne 0) { throw "wsl --unregister 失敗" }
}

# --- SHA256 検証 --------------------------------------------------------------
Write-Log "SHA256 検証中..."
$actual = (Get-FileHash -LiteralPath $TarFile -Algorithm SHA256).Hash.ToLower()
Write-Log "Actual   SHA256: $actual"
if ($actual -ne $ExpectedSha256) {
    try { Remove-Item $TarFile -Force -ErrorAction SilentlyContinue } catch {}
    throw "SHA256 不一致。ダウンロード破損の可能性。インストーラを再実行してください。"
}
Write-Log "SHA256 検証 OK"

# --- wsl --import -------------------------------------------------------------
Write-Log "wsl --import 実行中... ($WslDir)"
& wsl.exe --import $DistroName $WslDir $TarFile --version 2
if ($LASTEXITCODE -ne 0) {
    throw "wsl --import 失敗 (ExitCode=$LASTEXITCODE)"
}
Write-Log "import 完了"

# 容量節約: tar は削除
try {
    Remove-Item $TarFile -Force
    Write-Log "キャッシュ tar を削除しました"
} catch {
    Write-Log "tar 削除に失敗: $($_.Exception.Message)" 'WARN'
}

Write-Log "=== インストール完了 ==="
exit 0

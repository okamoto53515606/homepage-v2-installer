<#
.SYNOPSIS
  homepage-v2-installer: WSL2 イメージのダウンロード・検証・インポート
.DESCRIPTION
  Inno Setup の [Run] セクションから呼び出される想定。
  - %LOCALAPPDATA%\HomepageV2 配下にイメージを展開
  - R2 から tar と .sha256 をダウンロード（BITS 利用）
  - SHA256 検証
  - wsl --import で取り込み
  - 既存ディストリがあればスキップ（再実行に強い）
#>

[CmdletBinding()]
param(
    [string]$DistroName  = 'homepage-v2-latest',
    [string]$TarUrl      = 'https://pub-a692d5b289c84f6991126101fe2d638d.r2.dev/homepage-v2-latest.tar',
    [string]$Sha256Url   = 'https://pub-a692d5b289c84f6991126101fe2d638d.r2.dev/homepage-v2-latest.tar.sha256',
    [string]$BaseDir     = (Join-Path $env:LOCALAPPDATA 'HomepageV2'),
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- ディレクトリ準備 ---------------------------------------------------------
$WslDir   = Join-Path $BaseDir 'wsl'
$CacheDir = Join-Path $BaseDir 'cache'
$LogDir   = Join-Path $BaseDir 'logs'
foreach ($d in @($BaseDir, $WslDir, $CacheDir, $LogDir)) {
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

Write-Log "=== homepage-v2-installer / install-wsl.ps1 ==="
Write-Log "Distro     : $DistroName"
Write-Log "BaseDir    : $BaseDir"
Write-Log "TarUrl     : $TarUrl"

# --- WSL 利用可能チェック -----------------------------------------------------
try {
    $null = & wsl.exe --status 2>&1
    if ($LASTEXITCODE -ne 0) { throw "wsl --status が失敗しました (ExitCode=$LASTEXITCODE)" }
} catch {
    Write-Log "WSL が利用できません。`n  PowerShell を管理者で開き、`wsl --install` を実行後にPCを再起動してから本インストーラを再実行してください。" 'ERROR'
    throw
}

# --- 既存ディストリの判定 -----------------------------------------------------
# wsl --list の出力は UTF-16LE。PowerShell 側で正しくデコードする
$prevEncoding = [Console]::OutputEncoding
try {
    [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
    $list = (& wsl.exe --list --quiet) 2>$null
} finally {
    [Console]::OutputEncoding = $prevEncoding
}
$exists = $false
if ($list) {
    $exists = ($list | Where-Object { $_.Trim() -eq $DistroName }).Count -gt 0
}

if ($exists -and -not $Force) {
    Write-Log "既存ディストリ '$DistroName' を検出。インポートをスキップします。"
    Write-Log "（再取得したい場合は --Force もしくはアンインストール→再インストールしてください）"
    exit 0
}

if ($exists -and $Force) {
    Write-Log "Force 指定: 既存 '$DistroName' を解除します"
    & wsl.exe --terminate $DistroName | Out-Null
    & wsl.exe --unregister $DistroName
    if ($LASTEXITCODE -ne 0) { throw "wsl --unregister 失敗" }
}

# --- tar ダウンロード（BITS、再開可能） ---------------------------------------
$TarFile    = Join-Path $CacheDir 'homepage-v2-latest.tar'
$Sha256File = Join-Path $CacheDir 'homepage-v2-latest.tar.sha256'

function Invoke-Download {
    param([string]$Url, [string]$Dest)
    Write-Log "Downloading: $Url -> $Dest"
    try {
        # BITS は大容量・再開対応に最適
        Import-Module BitsTransfer -ErrorAction Stop
        Start-BitsTransfer -Source $Url -Destination $Dest -Description 'homepage-v2-installer' -DisplayName 'WSL イメージをダウンロード中'
    } catch {
        Write-Log "BITS が使えないため Invoke-WebRequest にフォールバック: $($_.Exception.Message)" 'WARN'
        $ProgressPreference = 'SilentlyContinue'
        Invoke-WebRequest -Uri $Url -OutFile $Dest -UseBasicParsing
    }
}

# .sha256 は毎回最新を取得（latest は更新される前提）
if (Test-Path $Sha256File) { Remove-Item $Sha256File -Force }
Invoke-Download -Url $Sha256Url -Dest $Sha256File

$expectedHash = (Get-Content -LiteralPath $Sha256File -Raw).Trim().Split()[0].ToLower()
if ($expectedHash -notmatch '^[0-9a-f]{64}$') {
    throw "SHA256 ファイルの内容が不正: '$expectedHash'"
}
Write-Log "Expected SHA256: $expectedHash"

# 既存 tar のキャッシュチェック
$needDownload = $true
if (Test-Path $TarFile) {
    Write-Log "既存 tar を検出。ハッシュ検証中..."
    $cur = (Get-FileHash -LiteralPath $TarFile -Algorithm SHA256).Hash.ToLower()
    if ($cur -eq $expectedHash) {
        Write-Log "キャッシュ済み tar が一致。ダウンロードをスキップします。"
        $needDownload = $false
    } else {
        Write-Log "ハッシュ不一致のため tar を再取得します。"
        Remove-Item $TarFile -Force
    }
}

if ($needDownload) {
    Invoke-Download -Url $TarUrl -Dest $TarFile
    $actual = (Get-FileHash -LiteralPath $TarFile -Algorithm SHA256).Hash.ToLower()
    Write-Log "Actual   SHA256: $actual"
    if ($actual -ne $expectedHash) {
        Remove-Item $TarFile -Force -ErrorAction SilentlyContinue
        throw "SHA256 不一致。ダウンロード破損の可能性。再実行してください。"
    }
    Write-Log "SHA256 検証 OK"
}

# --- wsl --import ------------------------------------------------------------
Write-Log "wsl --import 実行中... ($WslDir)"
& wsl.exe --import $DistroName $WslDir $TarFile --version 2
if ($LASTEXITCODE -ne 0) {
    throw "wsl --import 失敗 (ExitCode=$LASTEXITCODE)"
}
Write-Log "import 完了"

# 容量節約: tar は削除（次回更新時は再DLされる）
try {
    Remove-Item $TarFile -Force
    Write-Log "キャッシュ tar を削除しました"
} catch {
    Write-Log "tar 削除に失敗: $($_.Exception.Message)" 'WARN'
}

Write-Log "=== インストール完了 ==="
exit 0

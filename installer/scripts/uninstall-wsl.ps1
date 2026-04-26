<#
.SYNOPSIS
  homepage-v2-installer: WSL ディストリの登録解除
.DESCRIPTION
  Inno Setup の [UninstallRun] から呼び出される想定。
  ディストリが存在しない場合でもエラーを返さない（ベストエフォート）。
#>

[CmdletBinding()]
param(
    [string]$DistroName = 'homepage-v2-latest',
    [string]$BaseDir    = (Join-Path $env:LOCALAPPDATA 'HomepageV2'),
    [switch]$KeepCache
)

$ErrorActionPreference = 'Continue'

$LogDir  = Join-Path $BaseDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir ('uninstall-{0:yyyyMMdd-HHmmss}.log' -f (Get-Date))

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    Write-Host $line
}

Write-Log "=== homepage-v2-installer / uninstall-wsl.ps1 ==="
Write-Log "Distro : $DistroName"

# 実行中なら停止
& wsl.exe --terminate $DistroName 2>&1 | ForEach-Object { Write-Log $_ }

# 登録解除
& wsl.exe --unregister $DistroName 2>&1 | ForEach-Object { Write-Log $_ }
if ($LASTEXITCODE -ne 0) {
    Write-Log "wsl --unregister は非ゼロ終了 (ExitCode=$LASTEXITCODE) — 既に未登録の可能性。続行します。" 'WARN'
}

# キャッシュ削除
if (-not $KeepCache) {
    $cache = Join-Path $BaseDir 'cache'
    if (Test-Path $cache) {
        try {
            Remove-Item -LiteralPath $cache -Recurse -Force
            Write-Log "cache を削除しました: $cache"
        } catch {
            Write-Log "cache 削除に失敗: $($_.Exception.Message)" 'WARN'
        }
    }
}

Write-Log "=== アンインストール処理 完了 ==="
exit 0

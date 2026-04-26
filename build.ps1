<#
.SYNOPSIS
  homepage-v2-installer 全体ビルド (tray .exe -> Inno Setup .exe)
.NOTES
  事前準備:
    1. PowerShell:  Install-Module ps2exe -Scope CurrentUser
    2. Inno Setup 6 を https://jrsoftware.org/isinfo.php からインストール
       (既定: C:\Program Files (x86)\Inno Setup 6\ISCC.exe)
    3. assets\icon.ico を配置（無くてもビルドは通る）
#>

[CmdletBinding()]
param(
    [string]$IsccPath = 'C:\Program Files (x86)\Inno Setup 6\ISCC.exe'
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 1. tray .exe ビルド
Write-Host "==> [1/2] tray .exe ビルド" -ForegroundColor Cyan
& (Join-Path $root 'tray-app\build-exe.ps1')

# 2. Inno Setup コンパイル
Write-Host "==> [2/2] Inno Setup コンパイル" -ForegroundColor Cyan
if (-not (Test-Path $IsccPath)) {
    throw "ISCC.exe が見つかりません: $IsccPath`nInno Setup 6 をインストールしてください。"
}
$iss = Join-Path $root 'installer\homepage-v2-installer.iss'
& $IsccPath $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (ExitCode=$LASTEXITCODE)" }

$dist = Join-Path $root 'dist'
Write-Host "==> 完了: $dist" -ForegroundColor Green
Get-ChildItem $dist -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime

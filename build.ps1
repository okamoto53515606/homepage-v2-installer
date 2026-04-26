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
    [string]$IsccPath
)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot

# 1. tray .exe ビルド
Write-Host "==> [1/2] tray .exe ビルド" -ForegroundColor Cyan
& (Join-Path $root 'tray-app\build-exe.ps1')

# 2. Inno Setup コンパイル
Write-Host "==> [2/2] Inno Setup コンパイル" -ForegroundColor Cyan
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 6\ISCC.exe',
        'C:\Program Files\Inno Setup 6\ISCC.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 6\ISCC.exe'),
        (Join-Path $env:USERPROFILE 'AppData\Local\Programs\Inno Setup 6\ISCC.exe')
    )
    $IsccPath = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $IsccPath) {
        $cmd = Get-Command ISCC.exe -ErrorAction SilentlyContinue
        if ($cmd) { $IsccPath = $cmd.Source }
    }
    if (-not $IsccPath) {
        throw "ISCC.exe が見つかりません。Inno Setup 6 をインストールするか -IsccPath を指定してください。`n探索パス:`n  $($candidates -join "`n  ")"
    }
}
Write-Host "ISCC: $IsccPath" -ForegroundColor DarkGray
$iss = Join-Path $root 'installer\homepage-v2-installer.iss'
& $IsccPath $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (ExitCode=$LASTEXITCODE)" }

$dist = Join-Path $root 'dist'
Write-Host "==> 完了: $dist" -ForegroundColor Green
Get-ChildItem $dist -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime

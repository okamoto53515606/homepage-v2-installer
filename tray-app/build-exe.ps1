<#
.SYNOPSIS
  HomepageV2Tray.ps1 を ps2exe で .exe 化する
.NOTES
  事前: PowerShell で `Install-Module ps2exe -Scope CurrentUser` 実行
#>

[CmdletBinding()]
param(
    [string]$Source,
    [string]$Output,
    [string]$IconPath
)

$ErrorActionPreference = 'Stop'

# 注意: [CmdletBinding()] 付きスクリプトでは param 既定値の評価時に
# $PSScriptRoot がまだ空になるため、既定値は本文で組み立てる。
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Source)   { $Source   = Join-Path $here 'HomepageV2Tray.ps1' }
if (-not $Output)   { $Output   = Join-Path $here 'HomepageV2Tray.exe' }
if (-not $IconPath) { $IconPath = Join-Path (Split-Path -Parent $here) 'assets\icon.ico' }

# ps2exe は脆弱性修正を含む最新版を使う（1.0.18 未満は不可）
$MinPs2ExeVersion = [version]'1.0.18'
$installed = Get-Module -ListAvailable -Name ps2exe | Sort-Object Version -Descending | Select-Object -First 1
if (-not $installed) {
    Write-Host 'ps2exe モジュールが見つかりません。インストールします...'
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
} elseif ($installed.Version -lt $MinPs2ExeVersion) {
    Write-Host "ps2exe $($installed.Version) は古いため最新版へ更新します..."
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe -MinimumVersion $MinPs2ExeVersion

$args = @{
    inputFile  = $Source
    outputFile = $Output
    noConsole  = $true
    STA        = $true
    title      = 'homepage-v2-installer'
    company    = 'homepage-v2'
    product    = 'homepage-v2-installer'
    version    = '1.1.0.0'
}
if (Test-Path $IconPath) { $args.iconFile = $IconPath }

Write-Host "ps2exe -> $Output"
Invoke-ps2exe @args

if (-not (Test-Path $Output)) { throw 'ビルド失敗: 出力 .exe が存在しません' }
Write-Host 'ビルド完了'

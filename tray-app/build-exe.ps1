<#
.SYNOPSIS
  HomepageV2Tray.ps1 を ps2exe で .exe 化する
.NOTES
  事前: PowerShell で `Install-Module ps2exe -Scope CurrentUser` 実行
#>

[CmdletBinding()]
param(
    [string]$Source  = (Join-Path $PSScriptRoot 'HomepageV2Tray.ps1'),
    [string]$Output  = (Join-Path $PSScriptRoot 'HomepageV2Tray.exe'),
    [string]$IconPath = (Join-Path (Split-Path -Parent $PSScriptRoot) 'assets\icon.ico')
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable -Name ps2exe)) {
    Write-Host 'ps2exe モジュールが見つかりません。インストールします...'
    Install-Module ps2exe -Scope CurrentUser -Force -AllowClobber
}
Import-Module ps2exe

$args = @{
    inputFile  = $Source
    outputFile = $Output
    noConsole  = $true
    STA        = $true
    title      = 'homepage-v2-installer'
    company    = 'homepage-v2'
    product    = 'homepage-v2-installer'
    version    = '1.0.0.0'
}
if (Test-Path $IconPath) { $args.iconFile = $IconPath }

Write-Host "ps2exe -> $Output"
Invoke-ps2exe @args

if (-not (Test-Path $Output)) { throw 'ビルド失敗: 出力 .exe が存在しません' }
Write-Host 'ビルド完了'

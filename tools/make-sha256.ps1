<#
.SYNOPSIS
  homepage-v2-latest.tar の SHA256 ハッシュファイルを生成する
.DESCRIPTION
  R2 バケットに tar と一緒にアップロードしてください:
    homepage-v2-latest.tar
    homepage-v2-latest.tar.sha256   <-- このスクリプトで生成
.EXAMPLE
  .\make-sha256.ps1 -Tar D:\wsl_backup\homepage-v2-latest.tar
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$Tar,
    [string]$Out
)

$ErrorActionPreference = 'Stop'
if (-not (Test-Path $Tar)) { throw "tar が見つかりません: $Tar" }
if (-not $Out) { $Out = "$Tar.sha256" }

Write-Host "Computing SHA256: $Tar"
$hash = (Get-FileHash -LiteralPath $Tar -Algorithm SHA256).Hash.ToLower()

# 1行で書き出す（インストーラ側は先頭64桁のみを参照）
Set-Content -LiteralPath $Out -Value $hash -Encoding ASCII -NoNewline
Write-Host "Wrote: $Out"
Write-Host "Hash : $hash"
Write-Host ""
Write-Host "次の2ファイルを R2 にアップロードしてください:"
Write-Host "  $Tar"
Write-Host "  $Out"

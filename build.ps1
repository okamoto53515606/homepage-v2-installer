<#
.SYNOPSIS
  homepage-v2-installer 全体ビルド (tray .exe -> Inno Setup .exe -> 配布用 zip)
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
Write-Host "==> [1/3] tray .exe ビルド" -ForegroundColor Cyan
& (Join-Path $root 'tray-app\build-exe.ps1')

# 2. Inno Setup コンパイル
Write-Host "==> [2/3] Inno Setup コンパイル" -ForegroundColor Cyan
if (-not $IsccPath -or -not (Test-Path $IsccPath)) {
    # Inno Setup 7 を優先（6 系はメンテナンスのみ）。
    # ArchitecturesAllowed=x64compatible のため 6.4 以上が必要。
    $candidates = @(
        'C:\Program Files (x86)\Inno Setup 7\ISCC.exe',
        'C:\Program Files\Inno Setup 7\ISCC.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\Inno Setup 7\ISCC.exe'),
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
        throw "ISCC.exe が見つかりません。Inno Setup 7.1.1 以上（6.4 以上でも可）をインストールするか -IsccPath を指定してください。`n探索パス:`n  $($candidates -join "`n  ")"
    }
}
Write-Host "ISCC: $IsccPath" -ForegroundColor DarkGray
$iss = Join-Path $root 'installer\homepage-v2-installer.iss'
& $IsccPath $iss
if ($LASTEXITCODE -ne 0) { throw "ISCC failed (ExitCode=$LASTEXITCODE)" }

$dist = Join-Path $root 'dist'
$exe  = Join-Path $dist 'homepage-v2-installer-setup.exe'
if (-not (Test-Path -LiteralPath $exe)) { throw "インストーラが見つかりません: $exe" }

# 3. 配布用 zip の作成
# why: exe を Release に直接置くと、セキュリティ製品やブラウザの制限でDLできない事例が多い。
#      配布物は zip に統一し、展開後の exe を実行してもらう（インストーラ本体はそのまま）。
Write-Host "==> [3/3] 配布用 zip 作成" -ForegroundColor Cyan
$zip = Join-Path $dist 'homepage-v2-installer-setup.zip'
if (Test-Path -LiteralPath $zip) { Remove-Item -LiteralPath $zip -Force }
Compress-Archive -LiteralPath $exe -DestinationPath $zip -CompressionLevel Optimal
Write-Host ("zip: {0:N0} bytes" -f (Get-Item -LiteralPath $zip).Length)

Write-Host "==> 完了: $dist" -ForegroundColor Green
Write-Host "    配布するのは zip のみ（exe は zip の中に入っています）" -ForegroundColor DarkGray
Get-ChildItem $dist -ErrorAction SilentlyContinue | Format-Table Name, Length, LastWriteTime

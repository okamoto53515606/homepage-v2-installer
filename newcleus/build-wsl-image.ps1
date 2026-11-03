<#
.SYNOPSIS
  newcleus CMS 配布用 WSL イメージの「生成 → 軽量化 → 圧縮 → 検証 → リリース」を
  1 コマンドで実行する。

.DESCRIPTION
  okamoto53515606/newcleus 専用のオーケストレータ。homepage 版
  (tools/build-wsl-image.ps1) を newcleus 向けに調整したもので、以下を自動化する。

    1. リリースノート / バージョン / タグ / 空き容量の事前チェック
    2. Ubuntu WSL rootfs の取得と SHA256 検証（homepage とキャッシュ共有）
    3. wsl --import で専用の build distro（newcleus-build）を作成
    4. newcleus/wsl-image/provision.sh（apt 更新 / AWS CLI / Node 24 / Docker / アプリ）
    5. newcleus/wsl-image/cleanup.sh（軽量化 + クレデンシャル混入チェック）
    6. wsl --export → pigz → sha256
    7. 圧縮済み tar.gz を検証用 distro（newcleus-verify）に import し、スモークテスト + 画面起動確認
    8. gh release create（--latest / ビルドしたコミットにタグを打つ）

  リリースノートの置き場所（既定）:
    D:\wsl_backup\newcleus-release-notes-v<version>.md
    例: D:\wsl_backup\newcleus-release-notes-v1.0.6.md
    ※ <version> は newcleus の package.json の version（v は付けない）

.PARAMETER Version
  1.0.6 / v1.0.6 のどちらでも可。省略時は NotesDir 内の最新ノートから推定する。

.PARAMETER NotesFile
  リリースノートを明示指定する（省略時は NotesDir から命名規則で解決）。

.PARAMETER SkipRelease
  検証までで止める（gh release create を実行しない）。

.PARAMETER SkipBuild
  既存の tar.gz を再利用し、生成〜圧縮をスキップする（検証/リリースの再実行用）。

.PARAMETER SkipVerify
  import + 起動テストを省略する（非推奨）。

.PARAMETER KeepBuildDistro
  成功後も build distro を残す（デバッグ用）。

.EXAMPLE
  .\newcleus\build-wsl-image.ps1 -SkipRelease

.EXAMPLE
  .\newcleus\build-wsl-image.ps1 -Version 1.0.6

.NOTES
  - このファイルは UTF-8 BOM 付きで保存すること（Windows PowerShell 5.1 の制約）。
  - gh CLI の認証（gh auth login）と、D ドライブに 20GB 以上の空きが必要。
  - homepage 版とは distro 名・成果物名・リポジトリが独立しているので、同じ PC で併用できる。
#>

[CmdletBinding()]
param(
    [string]$Version,
    [string]$NotesDir = 'D:\wsl_backup',
    [string]$NotesFile,
    [string]$WorkDir = 'D:\wsl_backup\build',
    [string]$OutputDir = 'D:\wsl_backup',
    [string]$BaseUrl = 'https://cdimages.ubuntu.com/ubuntu-wsl/noble/daily-live/current/noble-wsl-amd64.wsl',
    [string]$Repo = 'okamoto53515606/newcleus',
    [string]$BuildDistro = 'newcleus-build',
    [string]$VerifyDistro = 'newcleus-verify',
    [string]$DistroUser = 'ubuntu',
    [int]$MinFreeGB = 20,
    [int]$ServerTimeoutSec = 600,
    [switch]$SkipRelease,
    [switch]$SkipVerify,
    [switch]$SkipBuild,
    [switch]$SkipBaseDownload,
    [switch]$SkipVersionCheck,
    [switch]$KeepBuildDistro
)

$ErrorActionPreference = 'Stop'
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# ---------------------------------------------------------------------------
# 汎用ヘルパー
# ---------------------------------------------------------------------------
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR', 'OK')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if ($script:LogFile) {
        try { [System.IO.File]::AppendAllText($script:LogFile, $line + "`r`n", $script:Utf8NoBom) } catch { }
    }
    switch ($Level) {
        'ERROR' { Write-Host $line -ForegroundColor Red }
        'WARN'  { Write-Host $line -ForegroundColor Yellow }
        'OK'    { Write-Host $line -ForegroundColor Green }
        default { Write-Host $line }
    }
}

function ConvertTo-WslPath {
    param([Parameter(Mandatory)][string]$Path)
    $full = [System.IO.Path]::GetFullPath($Path)
    if ($full -notmatch '^([A-Za-z]):\\(.*)$') {
        throw "WSL パスに変換できません（ドライブレター付きパスのみ対応）: $Path"
    }
    return ('/mnt/{0}/{1}' -f $matches[1].ToLower(), ($matches[2] -replace '\\', '/'))
}

function Invoke-WslCapture {
    param(
        [Parameter(Mandatory)][string[]]$WslArgs,
        [ValidateSet('utf8', 'unicode')][string]$Encoding = 'utf8',
        [int]$TimeoutSec = 600
    )
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = 'wsl.exe'
    $psi.Arguments = (($WslArgs | ForEach-Object { if ($_ -match '\s') { '"{0}"' -f $_ } else { $_ } }) -join ' ')
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    if ($Encoding -eq 'unicode') {
        $enc = New-Object System.Text.UnicodeEncoding($false, $false)
    } else {
        $enc = New-Object System.Text.UTF8Encoding($false)
    }
    $psi.StandardOutputEncoding = $enc
    $psi.StandardErrorEncoding = $enc

    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch { }
        throw "wsl がタイムアウトしました ($TimeoutSec s): wsl $($psi.Arguments)"
    }
    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        Output   = $outTask.Result
        Error    = $errTask.Result
    }
}

function Invoke-WslRun {
    # why: 長時間処理（apt / next build / 圧縮）は出力をそのままコンソールへ流す。
    #      ログは WSL 側の tee（LOG_PATH）が担当する。
    param(
        [Parameter(Mandatory)][string[]]$WslArgs,
        [Parameter(Mandatory)][string]$Phase
    )
    Write-Log "$Phase ..."
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & wsl.exe @WslArgs
    $code = $LASTEXITCODE
    $sw.Stop()
    if ($code -ne 0) {
        throw "$Phase が失敗しました (ExitCode=$code / $([int]$sw.Elapsed.TotalSeconds)s)。ログ: $script:LogFile"
    }
    Write-Log ("{0} 完了 ({1}s)" -f $Phase, [int]$sw.Elapsed.TotalSeconds) 'OK'
}

function Get-WslDistroNames {
    $r = Invoke-WslCapture -WslArgs @('--list', '--quiet') -Encoding 'unicode'
    if ($r.ExitCode -ne 0) { return @() }
    return @($r.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Test-WslDistroExists {
    param([Parameter(Mandatory)][string]$Name)
    foreach ($n in (Get-WslDistroNames)) {
        if ($n -ieq $Name) { return $true }
    }
    return $false
}

function Remove-WslDistro {
    param([Parameter(Mandatory)][string]$Name)
    if (-not (Test-WslDistroExists $Name)) { return }
    Write-Log "既存ディストリ '$Name' を削除します (wsl --terminate / --unregister)" 'WARN'
    try { & wsl.exe --terminate $Name 2>$null | Out-Null } catch { }
    try { & wsl.exe --unregister $Name 2>$null | Out-Null } catch { }
}

function Invoke-NativeQuiet {
    <#
      why: PowerShell 5.1 は「2>&1 でリダイレクトしたネイティブ コマンドの stderr」を
           ErrorRecord に変換するため、$ErrorActionPreference='Stop' だと trap が発火する。
           `gh release view` の "release not found" のような**正常系の失敗**で例外にしないよう、
           この関数内だけ EAP を Continue にして終了コードと出力を返す。
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$Arguments = @()
    )
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & $FilePath @Arguments 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $prev
    }
    return [pscustomobject]@{ ExitCode = $code; Output = $out.Trim() }
}

function Get-VersionParts {
    param([Parameter(Mandatory)][string]$Value)
    $core = ($Value -split '[-+]')[0]
    $p = $core.Split('.')
    $out = @(0, 0, 0)
    for ($i = 0; $i -lt 3 -and $i -lt $p.Count; $i++) {
        $n = 0
        if ([int]::TryParse($p[$i], [ref]$n)) { $out[$i] = $n }
    }
    return $out
}

function Compare-VersionString {
    param([string]$Left, [string]$Right)
    $a = Get-VersionParts $Left
    $b = Get-VersionParts $Right
    for ($i = 0; $i -lt 3; $i++) {
        if ($a[$i] -lt $b[$i]) { return -1 }
        if ($a[$i] -gt $b[$i]) { return 1 }
    }
    return 0
}

function Get-NotesCandidates {
    param([Parameter(Mandatory)][string]$Dir)
    $result = @()
    if (-not (Test-Path -LiteralPath $Dir)) { return $result }
    foreach ($f in (Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue)) {
        if ($f.Name -match '^(?:newcleus-)?release-notes-v(?<ver>\d+\.\d+\.\d+[^\\/]*)\.md$') {
            $result += [pscustomobject]@{ Version = $matches['ver']; Path = $f.FullName }
        }
    }
    return $result
}

function Test-PortListening {
    param([int]$Port)
    try {
        $conn = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction Stop
        return [bool]$conn
    } catch {
        return $false
    }
}

function Get-Sha256 {
    param([Parameter(Mandatory)][string]$Path)
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLower()
}

# ---------------------------------------------------------------------------
# ログ初期化
# ---------------------------------------------------------------------------
foreach ($d in @($OutputDir, $WorkDir, (Join-Path $WorkDir 'base'), (Join-Path $WorkDir 'distros'))) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}
$logDir = Join-Path $OutputDir 'logs'
if (-not (Test-Path -LiteralPath $logDir)) { New-Item -ItemType Directory -Path $logDir -Force | Out-Null }
$script:LogFile = Join-Path $logDir ("newcleus-build-{0}.log" -f $script:Stamp)

trap {
    Write-Log "FATAL: $($_.Exception.Message)" 'ERROR'
    try { Write-Log $_.ScriptStackTrace 'ERROR' } catch { }
    exit 1
}

Write-Log ('=' * 68)
Write-Log 'newcleus CMS WSL イメージ ビルド'
Write-Log "ログ: $script:LogFile"

$scriptDir   = $PSScriptRoot
$wslImageDir = Join-Path $scriptDir 'wsl-image'
foreach ($s in @('provision.sh', 'cleanup.sh', 'verify.sh')) {
    $p = Join-Path $wslImageDir $s
    if (-not (Test-Path -LiteralPath $p)) { throw "スクリプトが見つかりません: $p" }
}
$wslImageDirWsl = ConvertTo-WslPath $wslImageDir

$gzPath   = Join-Path $OutputDir 'newcleus-latest.tar.gz'
$shaPath  = "$gzPath.sha256"
$tarPath  = Join-Path $OutputDir 'newcleus-latest.tar'
$baseFile = Join-Path $WorkDir  'base\noble-wsl-amd64.wsl'
$sumsFile = Join-Path $WorkDir  'base\SHA256SUMS'

# ===========================================================================
# 1. 事前チェック（長いビルドの前に落とす）
# ===========================================================================
Write-Log '--- [1/9] 事前チェック ---'

if (-not (Get-Command wsl.exe -ErrorAction SilentlyContinue)) { throw 'wsl.exe が見つかりません。' }
# why: wsl.exe --version / --list の出力は UTF-16LE（WSL 内コマンドの出力は UTF-8）。
$wslVersion = (Invoke-WslCapture -WslArgs @('--version') -Encoding 'unicode').Output
Write-Log ("WSL: " + (($wslVersion -split "`r?`n")[0]))

$driveRoot = [System.IO.Path]::GetPathRoot([System.IO.Path]::GetFullPath($OutputDir))
if ($driveRoot -notmatch '^([A-Za-z]):') { throw "出力先はローカルドライブを指定してください: $OutputDir" }
$freeGB = [math]::Round((Get-PSDrive -Name $matches[1]).Free / 1GB, 1)
if ($freeGB -lt $MinFreeGB) {
    throw "${OutputDir} の空きが ${freeGB}GB です。${MinFreeGB}GB 以上必要です（中間 tar が数GBになります）。"
}
Write-Log "空き容量: ${freeGB}GB"

# --- バージョン / リリースノート -------------------------------------------
$candidates = @(Get-NotesCandidates -Dir $NotesDir)
if (-not $Version) {
    if ($candidates.Count -eq 0) {
        Write-Log 'リリースノートが見つかりません。次のいずれかに置いてください:' 'ERROR'
        Write-Log "  $(Join-Path $NotesDir 'newcleus-release-notes-v<version>.md')" 'ERROR'
        Write-Log "  $(Join-Path $NotesDir 'release-notes-v<version>.md')" 'ERROR'
        throw 'リリースノートが見つからないためバージョンを決定できません。-Version を指定してください。'
    }
    $best = $candidates[0]
    foreach ($c in $candidates) {
        if ((Compare-VersionString $c.Version $best.Version) -gt 0) { $best = $c }
    }
    $Version = $best.Version
    Write-Log "バージョンはリリースノートから推定: $Version ($($best.Path))"
}
$ver = ($Version.Trim() -replace '^[vV]', '')
if ($ver -notmatch '^\d+\.\d+\.\d+') { throw "バージョンの形式が不正です: $Version" }
$tag = "v$ver"

# --- リリースノートの解決 ---------------------------------------------------
$resolvedNotes = $null
if ($NotesFile) {
    if (-not (Test-Path -LiteralPath $NotesFile)) { throw "指定されたリリースノートがありません: $NotesFile" }
    $resolvedNotes = (Resolve-Path -LiteralPath $NotesFile).Path
} else {
    foreach ($c in @(
            (Join-Path $NotesDir "newcleus-release-notes-v$ver.md"),
            (Join-Path $NotesDir "release-notes-v$ver.md"))) {
        if (Test-Path -LiteralPath $c) { $resolvedNotes = (Resolve-Path -LiteralPath $c).Path; break }
    }
    if (-not $resolvedNotes) {
        Write-Log 'リリースノートが見つかりません（版なしの newcleus-release-notes.md は使いません）。' 'ERROR'
        Write-Log '次のいずれかに置いてください:' 'ERROR'
        Write-Log "  $(Join-Path $NotesDir "newcleus-release-notes-v$ver.md")" 'ERROR'
        Write-Log "  $(Join-Path $NotesDir "release-notes-v$ver.md")" 'ERROR'
        Write-Log 'または -NotesFile で明示指定してください。' 'ERROR'
        throw 'リリースノートが見つかりません。'
    }
}
Write-Log "リリースノート: $resolvedNotes"

# --- newcleus の package.json と一致しているか ------------------------------
if (-not $SkipVersionCheck) {
    $rawUrl = "https://raw.githubusercontent.com/$Repo/main/package.json"
    try {
        $pkg = Invoke-RestMethod -Uri $rawUrl -UseBasicParsing -TimeoutSec 30
    } catch {
        throw "package.json を取得できません: $rawUrl ($($_.Exception.Message))"
    }
    $remoteVersion = [string]$pkg.version
    if ($remoteVersion -ne $ver) {
        throw ("バージョン不一致: リリースノート/タグ=$ver, $Repo main の package.json=$remoteVersion" + "`n" +
               '        先に newcleus リポジトリの package.json を更新して push してください。')
    }
    Write-Log "本体 package.json version: $remoteVersion (一致)" 'OK'
}

# --- gh / タグ ---------------------------------------------------------------
$appSha = $null
if (-not $SkipRelease) {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { throw 'gh CLI が見つかりません（winget install --id GitHub.cli）。' }

    $auth = Invoke-NativeQuiet -FilePath 'gh' -Arguments @('auth', 'status')
    if ($auth.ExitCode -ne 0) { throw 'gh が未認証です。gh auth login を実行してください。' }

    # why: タグが未作成のとき gh は stderr に "release not found" を出して終了コード 1 を返す（正常系）。
    $existing = Invoke-NativeQuiet -FilePath 'gh' -Arguments @('release', 'view', $tag, '--repo', $Repo)
    if ($existing.ExitCode -eq 0) { throw "リリース $tag は既に存在します（タグは作り直せません）。" }

    $shaRes = Invoke-NativeQuiet -FilePath 'gh' -Arguments @('api', "repos/$Repo/commits/main", '--jq', '.sha')
    if ($shaRes.ExitCode -ne 0 -or -not $shaRes.Output) {
        throw "main のコミット SHA を取得できません: $Repo ($($shaRes.Output))"
    }
    $appSha = $shaRes.Output
    Write-Log "アプリのビルド元コミット: $appSha"
}

Write-Log "対象: $tag / 出力先: $OutputDir" 'OK'

# ===========================================================================
# 2. ベースイメージ（公式 rootfs + SHA256 検証）
# ===========================================================================
Write-Log '--- [2/9] ベースイメージ ---'

if (-not (Test-Path -LiteralPath $sumsFile)) {
    $sumsUrl = $BaseUrl.Substring(0, $BaseUrl.LastIndexOf('/') + 1) + 'SHA256SUMS'
    Write-Log "SHA256SUMS を取得: $sumsUrl"
    & curl.exe -fsSL --retry 3 -o $sumsFile $sumsUrl
    if ($LASTEXITCODE -ne 0) { throw "SHA256SUMS を取得できません: $sumsUrl" }
}
$expectedLine = Get-Content -LiteralPath $sumsFile |
    Where-Object { $_ -match [regex]::Escape([System.IO.Path]::GetFileName($baseFile)) } |
    Select-Object -First 1
if (-not $expectedLine) { throw "SHA256SUMS に $(Split-Path -Leaf $baseFile) の記載がありません。" }
$expectedBaseSha = ($expectedLine -split '\s+')[0].ToLower()

$baseSha = $null
if (Test-Path -LiteralPath $baseFile) {
    $baseSha = Get-Sha256 $baseFile
    Write-Log "キャッシュ済み: $baseFile"
}

if ($baseSha -ne $expectedBaseSha) {
    if ($SkipBaseDownload) { throw "-SkipBaseDownload ですが、ベースイメージが無いか SHA256 が不一致です: $baseFile" }
    Write-Log "ベースイメージを取得: $BaseUrl"
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    & curl.exe -fsSL --retry 3 -o $baseFile $BaseUrl
    if ($LASTEXITCODE -ne 0) { throw "ベースイメージを取得できません: $BaseUrl" }
    $sw.Stop()
    $baseSha = Get-Sha256 $baseFile
    Write-Log ("ダウンロード完了 ({0}s, {1:N1}MB)" -f [int]$sw.Elapsed.TotalSeconds, ((Get-Item $baseFile).Length / 1MB)) 'OK'
}

if ($baseSha -ne $expectedBaseSha) {
    throw "ベースイメージの SHA256 が一致しません: actual=$baseSha expected=$expectedBaseSha"
}
Write-Log "ベース SHA256 検証 OK: $baseSha" 'OK'

# ===========================================================================
# 3-6. build distro 作成 + プロビジョニング + 軽量化 + export/圧縮
# ===========================================================================
if ($SkipBuild) {
    Write-Log '--- [3-6/9] ビルドは -SkipBuild のためスキップ ---' 'WARN'
    if (-not (Test-Path -LiteralPath $gzPath)) { throw "-SkipBuild ですが $gzPath がありません。" }
} else {
    Write-Log '--- [3/9] build distro 作成 (wsl --import) ---'
    Remove-WslDistro -Name $BuildDistro
    $buildDistroDir = Join-Path $WorkDir "distros\$BuildDistro"
    if (Test-Path -LiteralPath $buildDistroDir) { Remove-Item -LiteralPath $buildDistroDir -Recurse -Force }
    New-Item -ItemType Directory -Path $buildDistroDir -Force | Out-Null

    Invoke-WslRun -Phase "ベースイメージを import ($BuildDistro)" -WslArgs @('--import', $BuildDistro, $buildDistroDir, $baseFile)
    if (-not (Test-WslDistroExists $BuildDistro)) { throw "build distro の作成に失敗しました: $BuildDistro" }

    # --- provision ---
    Write-Log '--- [4/9] プロビジョニング ---'
    $provisionLog = ConvertTo-WslPath (Join-Path $logDir "newcleus-provision-$script:Stamp.log")
    Invoke-WslRun -Phase 'provision.sh' -WslArgs @(
        '-d', $BuildDistro, '-u', 'root', '--',
        'env',
        "DISTRO_USER=$DistroUser",
        "APP_VERSION=$ver",
        "BUILD_ID=$script:Stamp",
        "BASE_SHA256=$baseSha",
        "LOG_PATH=$provisionLog",
        'bash', "$wslImageDirWsl/provision.sh"
    )

    # --- cleanup（軽量化） ---
    Write-Log '--- [5/9] 軽量化 + 混入チェック ---'
    $cleanupLog = ConvertTo-WslPath (Join-Path $logDir "newcleus-cleanup-$script:Stamp.log")
    Invoke-WslRun -Phase 'cleanup.sh' -WslArgs @(
        '-d', $BuildDistro, '-u', 'root', '--',
        'env',
        "DISTRO_USER=$DistroUser",
        "LOG_PATH=$cleanupLog",
        'bash', "$wslImageDirWsl/cleanup.sh"
    )

    # --- export ---
    Write-Log '--- [6/9] export + 圧縮 ---'
    try { & wsl.exe --terminate $BuildDistro 2>$null | Out-Null } catch { }
    if (Test-Path -LiteralPath $tarPath) { Remove-Item -LiteralPath $tarPath -Force }
    Invoke-WslRun -Phase "wsl --export → $tarPath" -WslArgs @('--export', $BuildDistro, $tarPath)
    Write-Log ("tar サイズ: {0:N2}GB" -f ((Get-Item -LiteralPath $tarPath).Length / 1GB))

    # why: pigz は gzip 完全互換。9 = 最高圧縮、-p で全コア使用。
    $tarWsl = ConvertTo-WslPath $tarPath
    $gzWsl = ConvertTo-WslPath $gzPath
    $zipCmd = "pigz -9 -p `$(nproc) -f '$tarWsl' && gzip -t '$gzWsl'"
    Invoke-WslRun -Phase 'pigz -9 + gzip -t' -WslArgs @('-d', $BuildDistro, '-u', 'root', '--', 'bash', '-c', $zipCmd)

    if (-not (Test-Path -LiteralPath $gzPath)) { throw "圧縮後のファイルがありません: $gzPath" }
    # why: pigz -f は元の tar を置き換える（＝既に消えている）ので存在確認してから消す。
    if (Test-Path -LiteralPath $tarPath) { Remove-Item -LiteralPath $tarPath -Force }

    $hash = Get-Sha256 $gzPath
    [System.IO.File]::WriteAllText($shaPath, $hash, $script:Utf8NoBom)
    $sizeGB = (Get-Item -LiteralPath $gzPath).Length / 1GB
    Write-Log ("gzip サイズ: {0:N2}GB / sha256: {1}" -f $sizeGB, $hash)
    if ($sizeGB -ge 2) { throw ("GitHub Release の単一アセット上限 2GB を超えています: {0:N2}GB" -f $sizeGB) }
}

# 既存成果物のハッシュを必ず実測し直す（-SkipBuild でも整合性を保証する）
$gzSha       = Get-Sha256 $gzPath
$recordedSha = if (Test-Path -LiteralPath $shaPath) { (Get-Content -LiteralPath $shaPath -Raw).Trim() } else { '' }
if ($recordedSha -ne $gzSha) {
    [System.IO.File]::WriteAllText($shaPath, $gzSha, $script:Utf8NoBom)
    Write-Log "sha256 ファイルを更新しました: $gzSha" 'WARN'
}
Write-Log ("アセット: $gzPath ({0:N2}GB)" -f ((Get-Item -LiteralPath $gzPath).Length / 1GB)) 'OK'

# ===========================================================================
# 7. 検証（本番と同じ手順で import し、起動まで確認）
# ===========================================================================
if ($SkipVerify) {
    Write-Log '--- [7/9] 検証は -SkipVerify のためスキップ ---' 'WARN'
} else {
    Write-Log '--- [7/9] 検証 (import → スモークテスト → 起動確認) ---'
    Remove-WslDistro -Name $VerifyDistro
    $verifyDir = Join-Path $WorkDir "distros\$VerifyDistro"
    if (Test-Path -LiteralPath $verifyDir) { Remove-Item -LiteralPath $verifyDir -Recurse -Force }
    New-Item -ItemType Directory -Path $verifyDir -Force | Out-Null

    $serverProc = $null
    try {
        Invoke-WslRun -Phase "tar.gz を import ($VerifyDistro)" -WslArgs @('--import', $VerifyDistro, $verifyDir, $gzPath)

        Invoke-WslRun -Phase 'verify.sh' -WslArgs @(
            '-d', $VerifyDistro, '-u', $DistroUser, '--',
            'env', "EXPECTED_VERSION=$ver",
            'bash', "$wslImageDirWsl/verify.sh"
        )

        if (Test-PortListening -Port 3001) {
            Write-Log 'ポート 3001 が既に使用中のため起動確認をスキップします（verify.sh は成功）' 'WARN'
        } else {
            Write-Log ("setup 画面の起動確認 (最大 {0}s) ..." -f $ServerTimeoutSec)
            $startArgs = @('-d', $VerifyDistro, '-u', $DistroUser, '--', 'bash', '-i', "/home/$DistroUser/newcleus/setup/start.sh")
            $serverProc = Start-Process -FilePath 'wsl.exe' -ArgumentList $startArgs -PassThru -WindowStyle Hidden

            $deadline = (Get-Date).AddSeconds($ServerTimeoutSec)
            $ready = $false
            while ((Get-Date) -lt $deadline) {
                try {
                    $res = Invoke-WebRequest -Uri 'http://localhost:3001/setup0' -UseBasicParsing -TimeoutSec 5
                    if ($res.StatusCode -ge 200 -and $res.StatusCode -lt 400) { $ready = $true; break }
                } catch { }
                if ($serverProc.HasExited) { break }
                Start-Sleep -Seconds 5
            }
            if (-not $ready) {
                throw "http://localhost:3001/setup0 が応答しません（タイムアウト or サーバー終了）。start.sh / .next を確認してください。"
            }
            Write-Log 'HTTP 200: setup 画面が起動しました' 'OK'
        }
    } finally {
        if ($serverProc -and -not $serverProc.HasExited) {
            try { Stop-Process -Id $serverProc.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        try { & wsl.exe --terminate $VerifyDistro 2>$null | Out-Null } catch { }
        Remove-WslDistro -Name $VerifyDistro
    }
}

# ===========================================================================
# 8. 後片付け（build distro）
# ===========================================================================
if ($KeepBuildDistro) {
    Write-Log "build distro を残します: $BuildDistro" 'WARN'
} else {
    Remove-WslDistro -Name $BuildDistro
    $buildDistroDir = Join-Path $WorkDir "distros\$BuildDistro"
    if (Test-Path -LiteralPath $buildDistroDir) { Remove-Item -LiteralPath $buildDistroDir -Recurse -Force -ErrorAction SilentlyContinue }
}

# ===========================================================================
# 9. リリース
# ===========================================================================
Write-Log '--- [8/9] リリース ---'
if ($SkipRelease) {
    Write-Log 'リリースは -SkipRelease のためスキップ。成果物を確認してください:' 'WARN'
    Write-Log "  $gzPath"
    Write-Log "  $shaPath"
    Write-Log "  $resolvedNotes"
} else {
    Write-Log "gh release create $tag --latest (--target $appSha)"
    & gh release create $tag $gzPath $shaPath `
        --repo $Repo `
        --title $tag `
        --notes-file $resolvedNotes `
        --target $appSha `
        --latest
    if ($LASTEXITCODE -ne 0) { throw "gh release create が失敗しました (ExitCode=$LASTEXITCODE)" }
    Write-Log "リリース完了: https://github.com/$Repo/releases/tag/$tag" 'OK'
}

# ===========================================================================
# サマリ
# ===========================================================================
Write-Log '--- [9/9] 完了 ---' 'OK'
Write-Log ("  バージョン : {0}" -f $tag)
Write-Log ("  アセット   : {0:N2}GB" -f ((Get-Item -LiteralPath $gzPath).Length / 1GB))
Write-Log ("  sha256     : {0}" -f $gzSha)
Write-Log ("  ノート     : {0}" -f $resolvedNotes)
Write-Log ("  ログ       : {0}" -f $script:LogFile)

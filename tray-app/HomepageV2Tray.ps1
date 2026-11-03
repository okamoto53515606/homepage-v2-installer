<#
.SYNOPSIS
  homepage-v2-installer: タスクトレイ常駐 起動/停止UI
.DESCRIPTION
  - シングルインスタンス（Mutex）
  - NotifyIcon メニュー: 起動 / 停止 / ブラウザを開く / ログ / 終了
  - 起動: wsl -d <distro> -u <user> --cd <path> -- bash -lc "npm run dev"
  - 停止: wsl --terminate <distro>
  - サーバ準備完了をポーリングして自動でブラウザを開く

  ps2exe で .exe 化することを想定（-noConsole -STA）。
#>

[CmdletBinding()]
param(
    [string]$DistroName  = 'homepage-v2-latest',
    [string]$WslUser     = 'ubuntu',
    [string]$ProjectPath = '/home/ubuntu/homepage/setup',
    [string]$StartScript = '/home/ubuntu/homepage/setup/start.sh',
    [string]$ProjectRoot = '/home/ubuntu/homepage',
    [int]   $Port        = 3001,
    [string]$BaseDir     = (Join-Path $env:LOCALAPPDATA 'HomepageV2'),
    [string]$AppName     = 'homepage-v2-installer',
    # バージョン確認・更新
    [string]$GitHubApiUrl      = 'https://api.github.com/repos/okamoto53515606/homepage/releases/latest',
    [string]$ReleasesLatestUrl = 'https://github.com/okamoto53515606/homepage/releases/latest',
    [string]$UpdateScriptPath,
    [int]   $UpdateTimeoutMinutes = 30,
    [switch]$AutoStart,
    # 画面を出さずにバージョン状態を JSON で出力する（サポート・自動テスト用）
    [switch]$Diagnose
)

# --- 早期ログ初期化 (起動時例外を確実に拾うため、最上部で定義) -----------------
$script:EarlyLogDir  = Join-Path $BaseDir 'logs'
if (-not (Test-Path $script:EarlyLogDir)) {
    try { New-Item -ItemType Directory -Path $script:EarlyLogDir -Force | Out-Null } catch {}
}
$script:EarlyLogFile = Join-Path $script:EarlyLogDir 'tray.log'
function Write-EarlyLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $script:EarlyLogFile -Value $line -Encoding UTF8 } catch {}
}
trap {
    Write-EarlyLog "FATAL: $($_.Exception.Message)" 'ERROR'
    try { Write-EarlyLog $_.ScriptStackTrace 'ERROR' } catch {}
    if (-not $Diagnose) {
        try {
            Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
            [System.Windows.Forms.MessageBox]::Show(
                "起動時エラー:`n$($_.Exception.Message)`n`n詳細は次のログを参照してください:`n$script:EarlyLogFile",
                'homepage-v2-installer', 'OK', 'Error') | Out-Null
        } catch {}
    }
    exit 1
}
$ErrorActionPreference = 'Stop'
Write-EarlyLog "=== Tray 起動開始 (PID=$PID) ==="
Write-EarlyLog ("PSCommandPath='{0}' PSScriptRoot='{1}'" -f $PSCommandPath, $PSScriptRoot)

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# --- シングルインスタンス -----------------------------------------------------
$mutexName = 'Global\HomepageV2InstallerTray'
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    if (-not $Diagnose) {
        [System.Windows.Forms.MessageBox]::Show('homepage-v2-installer は既に起動中です。', $AppName) | Out-Null
    }
    Write-EarlyLog '既に起動中のため終了します。'
    exit 0
}

# --- 共通 ---------------------------------------------------------------------
$LogDir = Join-Path $BaseDir 'logs'
if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
$LogFile = Join-Path $LogDir 'tray.log'

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch {}
}

function Test-PortOpen {
    param([int]$Port)
    # IPv4(127.0.0.1) と IPv6(::1) の両方を試す。
    # BeginConnect は EndConnect を呼ぶまで Connected が false のままなので、
    # WaitOne 後に EndConnect の成否で接続可否を判定する。
    foreach ($addr in @('127.0.0.1', '[::1]')) {
        $client = $null
        try {
            $client = New-Object System.Net.Sockets.TcpClient
            $iar = $client.BeginConnect($addr.Trim('[',']'), $Port, $null, $null)
            $ok = $iar.AsyncWaitHandle.WaitOne(500, $false)
            if ($ok) {
                try {
                    $client.EndConnect($iar)
                    if ($client.Connected) { return $true }
                } catch {}
            }
        } catch {
        } finally {
            if ($client) { try { $client.Close() } catch {} }
        }
    }
    return $false
}

function Get-WslDistroList {
    # wsl.exe 自身の制御メッセージは UTF-16LE、WSL 内コマンドの出力は UTF-8。
    # --list は UTF-16LE なので、コンソールのエンコーディング設定に依存せず
    # ProcessStartInfo で明示的にデコードする（ps2exe -noConsole でも安全）。
    param([switch]$Running)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $psi.Arguments              = if ($Running) { '--list --running --quiet' } else { '--list --quiet' }
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = New-Object System.Text.UnicodeEncoding($false, $false)
    $proc = [System.Diagnostics.Process]::Start($psi)
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    # WSL サービス起動直後は数秒〜数十秒かかることがある。無期限に待たない。
    if (-not $proc.WaitForExit(30000)) {
        try { $proc.Kill() } catch {}
        return @()
    }
    $out = $outTask.Result
    return @($out -split "`r?`n" |
        ForEach-Object { $_.Trim().TrimStart([char]0xFEFF) } |
        Where-Object { $_ })
}

function Test-DistroExists {
    return (@(Get-WslDistroList) -contains $DistroName)
}

function Test-DistroRunning {
    return (@(Get-WslDistroList -Running) -contains $DistroName)
}

# --- バージョン確認 / 更新 ----------------------------------------------------
# 画面（このファイル）→ ワーカー（installer\scripts\update-wsl-app.ps1）の 2 層。
# 起動・停止は既存の Start-Server / Stop-Server をそのまま再利用する。
$script:Utf8NoBom = New-Object System.Text.UTF8Encoding($false)

$script:UpdateRunning    = $false
$script:UpdateDialogOpen = $false
$script:UpdateProc       = $null
$script:UpdateLogFile    = $null
$script:UpdateLogPos     = 0
$script:UpdateLogDecoder = $null
$script:UpdateStopwatch  = $null
$script:UpdateBackupDir  = $null

$script:Ver = @{
    DistroExists   = $false
    HomepageExists = $false
    CurrentVersion = $null
    LatestTag      = $null
    LatestVersion  = $null
    LatestSource   = $null
    LatestError    = $null
    Comparison     = 'unknown'   # nodistro | notsetup | unknown | uptodate | update | newer
    CanUpdate      = $false
    AppliedVersion = $null
}

function Get-AppDir {
    # ps2exe で .exe 化されると $PSCommandPath は空になるため、複数のソースを順に試す
    $here = $null
    if ($PSCommandPath) { $here = Split-Path -Parent $PSCommandPath }
    if (-not $here -and $PSScriptRoot) { $here = $PSScriptRoot }
    if (-not $here) {
        try {
            $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($exePath) { $here = Split-Path -Parent $exePath }
        } catch {}
    }
    if (-not $here) { $here = (Get-Location).Path }
    return $here
}

function Get-WslArgumentString {
    param([string]$BashCommand)
    # wsl.exe は -d の値を引用符付きで渡すと解決できない（実測: WSL_E_DISTRO_NOT_FOUND）。
    # ディストリ名・ユーザー名は引用せず、bash -lc に渡すコマンドだけを 1 引数として
    # ダブルクォートし、内部の " を \" にエスケープする。
    $escaped = $BashCommand -replace '"', '\"'
    return '-d {0} -u {1} -- bash -lc "{2}"' -f $DistroName, $WslUser, $escaped
}

function Invoke-WslBash {
    param([string]$BashCommand, [int]$TimeoutSec = 60)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName               = 'wsl.exe'
    $psi.Arguments              = Get-WslArgumentString -BashCommand $BashCommand
    $psi.UseShellExecute        = $false
    $psi.CreateNoWindow         = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true
    $psi.StandardOutputEncoding = $script:Utf8NoBom
    $psi.StandardErrorEncoding  = $script:Utf8NoBom
    $proc = $null
    try {
        $proc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        return @{ ExitCode = -1; Output = ''; Error = $_.Exception.Message }
    }
    $outTask = $proc.StandardOutput.ReadToEndAsync()
    $errTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
        try { $proc.Kill() } catch {}
        return @{ ExitCode = -1; Output = ''; Error = "タイムアウト ($TimeoutSec 秒)" }
    }
    return @{ ExitCode = $proc.ExitCode; Output = $outTask.Result; Error = $errTask.Result }
}

function Get-AppVersionFromWsl {
    # 第一候補: 仕様どおり node -p（login shell で nvm の node を拾う）。アプリは起動しない。
    $node = Invoke-WslBash -BashCommand "node -p `"require('$ProjectRoot/package.json').version`"" -TimeoutSec 60
    if ($node.ExitCode -eq 0 -and $node.Output.Trim()) {
        $v = ($node.Output -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -First 1)
        if ($v) { return $v.Trim() }
    }
    # フォールバック: nvm を ~/.bashrc のみで初期化しているイメージでは bash -lc で
    # node が見つからないため、package.json を直接読んで解析する。
    $cat = Invoke-WslBash -BashCommand "cat $ProjectRoot/package.json" -TimeoutSec 60
    if ($cat.ExitCode -eq 0 -and $cat.Output.Trim()) {
        try { return [string](($cat.Output | ConvertFrom-Json).version) } catch {}
    }
    return $null
}

function ConvertTo-SemVer {
    param([string]$Text)
    if (-not $Text) { return $null }
    $s = $Text.Trim()
    if ($s -match '^[vV]') { $s = $s.Substring(1) }
    # build metadata は比較に影響しない
    $s = ($s -split '\+')[0]
    $pre = $null
    $core = $s
    $dash = $s.IndexOf('-')
    if ($dash -ge 0) {
        $core = $s.Substring(0, $dash)
        $pre  = $s.Substring($dash + 1)
    }
    if ($core -notmatch '^\d+(\.\d+){0,2}$') { return $null }
    $nums = @($core.Split('.') | ForEach-Object { [int]$_ })
    while ($nums.Count -lt 3) { $nums += 0 }
    return [pscustomobject]@{
        Major = $nums[0]
        Minor = $nums[1]
        Patch = $nums[2]
        Pre   = $pre
    }
}

function Compare-SemVer {
    # 戻り値: -1 (A<B) / 0 (A=B) / 1 (A>B) / $null (比較不能)
    param([string]$A, [string]$B)
    $x = ConvertTo-SemVer $A
    $y = ConvertTo-SemVer $B
    if (-not $x -or -not $y) { return $null }
    foreach ($f in @('Major', 'Minor', 'Patch')) {
        if ($x.$f -lt $y.$f) { return -1 }
        if ($x.$f -gt $y.$f) { return 1 }
    }
    # プレリリースがある方が「古い」（1.0.0-beta < 1.0.0）
    if (-not $x.Pre -and $y.Pre) { return 1 }
    if ($x.Pre -and -not $y.Pre) { return -1 }
    if (-not $x.Pre -and -not $y.Pre) { return 0 }
    $pa = $x.Pre.Split('.')
    $pb = $y.Pre.Split('.')
    $n = [Math]::Max($pa.Count, $pb.Count)
    for ($i = 0; $i -lt $n; $i++) {
        if ($i -ge $pa.Count) { return -1 }
        if ($i -ge $pb.Count) { return 1 }
        $ia = 0
        $ib = 0
        $aNum = [int]::TryParse($pa[$i], [ref]$ia)
        $bNum = [int]::TryParse($pb[$i], [ref]$ib)
        if ($aNum -and $bNum) {
            if ($ia -lt $ib) { return -1 }
            if ($ia -gt $ib) { return 1 }
            continue
        }
        if ($aNum) { return -1 }
        if ($bNum) { return 1 }
        $c = [string]::CompareOrdinal($pa[$i], $pb[$i])
        if ($c -lt 0) { return -1 }
        if ($c -gt 0) { return 1 }
    }
    return 0
}

function Get-LatestRelease {
    # 1) GitHub API（tag_name）。失敗したら
    # 2) https://github.com/<repo>/releases/latest の 302 Location を HEAD で追う。
    #    API は未認証 60 req/h の制限があるため、フォールバックを用意する。
    $apiError = $null
    try {
        [System.Net.ServicePointManager]::SecurityProtocol = [System.Net.SecurityProtocolType]::Tls12
        $r = Invoke-RestMethod -Uri $GitHubApiUrl `
            -Headers @{ 'User-Agent' = 'homepage-v2-installer'; 'Accept' = 'application/vnd.github+json' } `
            -TimeoutSec 10 -ErrorAction Stop
        if ($r -and $r.tag_name) {
            return @{ Tag = [string]$r.tag_name; Source = 'GitHub API'; Error = $null }
        }
    } catch {
        $apiError = $_.Exception.Message
    }
    try {
        $req = [System.Net.HttpWebRequest]::Create($ReleasesLatestUrl)
        $req.Method           = 'HEAD'
        $req.AllowAutoRedirect = $false
        $req.Timeout          = 10000
        $req.UserAgent        = 'homepage-v2-installer'
        $resp = $req.GetResponse()
        $loc  = $resp.Headers['Location']
        $resp.Close()
        if ($loc -and ($loc -match '/tag/(?<tag>[^/?#]+)')) {
            return @{ Tag = [string]$Matches['tag']; Source = 'GitHub (redirect)'; Error = $null }
        }
    } catch {
        if (-not $apiError) { $apiError = $_.Exception.Message }
    }
    return @{ Tag = $null; Source = $null; Error = $apiError }
}

function Update-VersionState {
    Write-Log 'バージョン状態を確認中...'
    $script:Ver.DistroExists   = Test-DistroExists
    Write-Log "DistroExists=$($script:Ver.DistroExists)"
    $script:Ver.HomepageExists = $false
    $script:Ver.CurrentVersion = $null
    $script:Ver.LatestTag      = $null
    $script:Ver.LatestVersion  = $null
    $script:Ver.LatestSource   = $null
    $script:Ver.LatestError    = $null
    $script:Ver.Comparison     = 'unknown'
    $script:Ver.CanUpdate      = $false

    if (-not $script:Ver.DistroExists) {
        $script:Ver.Comparison = 'nodistro'
        return
    }

    $probe = Invoke-WslBash -BashCommand "test -f $ProjectRoot/package.json && echo YES || echo NO" -TimeoutSec 60
    $script:Ver.HomepageExists = ($probe.ExitCode -eq 0 -and $probe.Output.Trim() -eq 'YES')
    Write-Log "HomepageExists=$($script:Ver.HomepageExists) (exit=$($probe.ExitCode))"
    if ($script:Ver.HomepageExists) {
        $script:Ver.CurrentVersion = Get-AppVersionFromWsl
        Write-Log "CurrentVersion=$($script:Ver.CurrentVersion)"
    }

    $rel = Get-LatestRelease
    Write-Log "LatestTag=$($rel.Tag) source=$($rel.Source)"
    $script:Ver.LatestError = $rel.Error
    if ($rel.Tag) {
        $script:Ver.LatestTag     = $rel.Tag
        $script:Ver.LatestSource  = $rel.Source
        $script:Ver.LatestVersion = ($rel.Tag -replace '^[vV]', '')
    }

    if (-not $script:Ver.HomepageExists) { $script:Ver.Comparison = 'notsetup'; return }
    if (-not $script:Ver.CurrentVersion) { $script:Ver.Comparison = 'unknown'; return }
    if (-not $script:Ver.LatestVersion) { $script:Ver.Comparison = 'unknown'; return }

    $cmp = Compare-SemVer $script:Ver.CurrentVersion $script:Ver.LatestVersion
    if ($null -eq $cmp) { $script:Ver.Comparison = 'unknown'; return }
    if ($cmp -lt 0)     { $script:Ver.Comparison = 'update' }
    elseif ($cmp -eq 0) { $script:Ver.Comparison = 'uptodate' }
    else                { $script:Ver.Comparison = 'newer' }
    $script:Ver.CanUpdate = $true
}

function Get-BackupPathFromLog {
    # 中止や強制終了で最後まで走らなかった場合でも、ログ中の退避ディレクトリを拾う。
    # （BACKUPS_BEFORE= の一覧を誤検知しないよう、案内行のパスだけを見る）
    param([string]$Text)
    if (-not $Text) { return $null }
    if ($Text -match '(?m)(?:旧ツリー[:：]\s*|切り戻しは\s*|BACKUP_DIR=)(?<path>/\S+\.old-\d{8}-\d{6})') {
        return $Matches['path']
    }
    return $null
}

function Get-UpdateScriptPath {
    if ($UpdateScriptPath -and (Test-Path -LiteralPath $UpdateScriptPath)) {
        return (Resolve-Path -LiteralPath $UpdateScriptPath).Path
    }
    $here = Get-AppDir
    $candidates = @(
        (Join-Path $here 'scripts\update-wsl-app.ps1'),
        (Join-Path $env:LOCALAPPDATA 'HomepageV2\app\scripts\update-wsl-app.ps1'),
        (Join-Path $here '..\installer\scripts\update-wsl-app.ps1')
    )
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

# --- 更新ダイアログ ------------------------------------------------------------
function Add-DlgLabel {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 300, [int]$H = 20,
          [string]$FontName = 'Segoe UI', [float]$FontSize = 9, [switch]$Bold)
    $lbl = New-Object System.Windows.Forms.Label
    $lbl.Text     = $Text
    $lbl.Location = New-Object System.Drawing.Point($X, $Y)
    $lbl.Size     = New-Object System.Drawing.Size($W, $H)
    $style = if ($Bold) { [System.Drawing.FontStyle]::Bold } else { [System.Drawing.FontStyle]::Regular }
    $lbl.Font = New-Object System.Drawing.Font($FontName, $FontSize, $style)
    [void]$Parent.Controls.Add($lbl)
    return $lbl
}

function Add-DlgButton {
    param($Parent, [string]$Text, [int]$X, [int]$Y, [int]$W = 110)
    $btn = New-Object System.Windows.Forms.Button
    $btn.Text     = $Text
    $btn.Location = New-Object System.Drawing.Point($X, $Y)
    $btn.Size     = New-Object System.Drawing.Size($W, 32)
    $btn.UseVisualStyleBackColor = $true
    [void]$Parent.Controls.Add($btn)
    return $btn
}

function Set-DlgRunningState {
    param([bool]$Running)
    if (-not $script:DlgForm) { return }
    $script:DlgBtnUpdate.Enabled  = ((-not $Running) -and $script:Ver.CanUpdate)
    $script:DlgBtnRefresh.Enabled = (-not $Running)
    $script:DlgBtnClose.Enabled   = (-not $Running)
    $script:DlgBtnCancel.Visible  = $Running
    $script:DlgBtnCancel.Enabled  = $Running
}

function Read-NewUpdateLogText {
    # 子プロセスが書く UTF-8 ログの差分だけを読む。
    # Application.Run 中は PowerShell のイベント（Register-ObjectEvent）が発火しないため、
    # stdout のイベント購読ではなくファイルのテールでリアルタイム表示する。
    if (-not $script:UpdateLogFile) { return '' }
    if (-not (Test-Path -LiteralPath $script:UpdateLogFile)) { return '' }
    $fs = $null
    $sb = New-Object System.Text.StringBuilder
    try {
        $fs = New-Object System.IO.FileStream(
            $script:UpdateLogFile,
            [System.IO.FileMode]::Open,
            [System.IO.FileAccess]::Read,
            ([System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete))
        if ($fs.Length -lt $script:UpdateLogPos) { $script:UpdateLogPos = 0 }
        if ($fs.Length -eq $script:UpdateLogPos) { return '' }
        [void]$fs.Seek($script:UpdateLogPos, [System.IO.SeekOrigin]::Begin)
        $buffer = New-Object byte[] 8192
        $chars  = New-Object char[] 8193
        while (($read = $fs.Read($buffer, 0, $buffer.Length)) -gt 0) {
            $script:UpdateLogPos += $read
            $count = $script:UpdateLogDecoder.GetChars($buffer, 0, $read, $chars, 0)
            [void]$sb.Append($chars, 0, $count)
        }
    } catch {
        # 書き込み中で一瞬開けない等。次の Tick で読み直す
    } finally {
        if ($fs) { try { $fs.Dispose() } catch {} }
    }
    return $sb.ToString()
}

function Refresh-UpdateDialog {
    if (-not $script:DlgForm) { return }
    $v = $script:Ver

    $currentText = '—'
    if ($v.CurrentVersion) { $currentText = 'v' + $v.CurrentVersion }
    elseif ($v.HomepageExists) { $currentText = '取得できません' }
    $script:DlgLblCurrent.Text = $currentText

    if ($v.LatestVersion) {
        $src = ''
        if ($v.LatestSource) { $src = "（$($v.LatestSource)）" }
        $script:DlgLblLatest.Text = 'v' + $v.LatestVersion + ' ' + $src
    } else {
        $script:DlgLblLatest.Text = '不明（取得できません）'
    }

    $status = ''
    switch ($v.Comparison) {
        'nodistro' {
            $status = "WSL ディストリビューション「$DistroName」が見つかりません。`r`nインストーラを再実行してください。"
        }
        'notsetup' {
            $status = "未セットアップです（$ProjectRoot がありません）。`r`nセットアップを完了してから更新してください。"
        }
        'unknown' {
            $status = "バージョン情報を取得できませんでした（オフライン / GitHub API のレート制限など）。`r`n時間をおいて「再確認」を押してください。"
            if ($v.LatestError) { $status += "`r`n詳細: " + $v.LatestError }
        }
        'uptodate' { $status = '最新です。' }
        'update'   { $status = "更新があります（v$($v.CurrentVersion) → v$($v.LatestVersion)）。" }
        'newer'    { $status = '現在のバージョンが最新リリースより新しいようです（開発版の可能性）。再適用はできます。' }
        default    { $status = '' }
    }
    if (-not $script:UpdateRunning) {
        $script:DlgLblStatus.Text = $status
        $script:DlgBtnUpdate.Text = if ($v.Comparison -eq 'uptodate') { '再適用する' } else { '更新する' }
    }
    Set-DlgRunningState -Running $script:UpdateRunning
}

function Show-UpdateDialog {
    if ($script:UpdateDialogOpen) { return }
    $script:UpdateDialogOpen = $true
    try {
        $form = New-Object System.Windows.Forms.Form
        $form.Text            = 'アプリのバージョン確認・更新'
        $form.ClientSize      = New-Object System.Drawing.Size(700, 620)
        $form.StartPosition   = [System.Windows.Forms.FormStartPosition]::CenterScreen
        $form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
        $form.MaximizeBox     = $false
        $form.MinimizeBox     = $false
        $form.Font            = New-Object System.Drawing.Font('Segoe UI', 9)
        $form.Add_FormClosing({
            param($sender, $e)
            if ($script:UpdateRunning) {
                $e.Cancel = $true
                [System.Windows.Forms.MessageBox]::Show(
                    '更新の実行中は閉じられません。中止する場合は「中止する」を押してください。',
                    $AppName, 'OK', 'Information') | Out-Null
            }
        })
        $form.Add_FormClosed({
            try { if ($script:DlgTimer) { $script:DlgTimer.Stop(); $script:DlgTimer.Dispose() } } catch {}
            try { if ($script:DlgInitTimer) { $script:DlgInitTimer.Stop(); $script:DlgInitTimer.Dispose() } } catch {}
            $script:DlgTimer = $null
            $script:DlgInitTimer = $null
            $script:DlgForm = $null
        })
        $script:DlgForm = $form

        [void](Add-DlgLabel $form '現在のバージョン' 16 18 150)
        [void](Add-DlgLabel $form '最新バージョン' 16 46 150)
        [void](Add-DlgLabel $form '適用後のバージョン' 16 74 150)

        $script:DlgLblCurrent = Add-DlgLabel $form '確認中...' 170 16 510 -FontName 'Consolas' -FontSize 10 -Bold
        $script:DlgLblLatest  = Add-DlgLabel $form '確認中...' 170 44 510 -FontName 'Consolas' -FontSize 10 -Bold
        $script:DlgLblApplied = Add-DlgLabel $form '—'        170 72 510 -FontName 'Consolas' -FontSize 10 -Bold
        if ($script:Ver.AppliedVersion) { $script:DlgLblApplied.Text = 'v' + $script:Ver.AppliedVersion }

        $script:DlgLblStatus = Add-DlgLabel $form 'バージョンを確認しています...' 16 104 668 80 -FontSize 10

        [void](Add-DlgLabel $form '進捗ログ（実行中はリアルタイムに更新されます）' 16 190 420)
        $script:DlgLblElapsed = Add-DlgLabel $form '' 480 190 204
        $script:DlgLblElapsed.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight

        $log = New-Object System.Windows.Forms.TextBox
        $log.Multiline  = $true
        $log.ReadOnly   = $true
        $log.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
        $log.WordWrap   = $false
        $log.Location   = New-Object System.Drawing.Point(16, 212)
        $log.Size       = New-Object System.Drawing.Size(668, 290)
        $log.Font       = New-Object System.Drawing.Font('Consolas', 9)
        $log.BackColor  = [System.Drawing.Color]::FromArgb(30, 30, 30)
        $log.ForeColor  = [System.Drawing.Color]::Gainsboro
        $form.Controls.Add($log)
        $script:DlgLog = $log

        $script:DlgBtnRefresh = Add-DlgButton $form '再確認'   16 516 110
        $script:DlgBtnUpdate  = Add-DlgButton $form '更新する' 286 516 130
        $script:DlgBtnCancel  = Add-DlgButton $form '中止する' 426 516 110
        $script:DlgBtnClose   = Add-DlgButton $form '閉じる'   580 516 104
        $script:DlgBtnCancel.Visible = $false

        $link = New-Object System.Windows.Forms.LinkLabel
        $link.Text     = 'ログフォルダを開く'
        $link.Location = New-Object System.Drawing.Point(16, 560)
        $link.AutoSize = $true
        $link.Add_LinkClicked({ Open-LogFolder })
        $form.Controls.Add($link)
        $script:DlgLblLogPath = Add-DlgLabel $form '' 150 560 534

        $script:DlgBtnRefresh.Add_Click({
            if ($script:UpdateRunning) { return }
            $script:DlgLblStatus.Text = 'バージョンを確認しています...'
            $script:DlgBtnUpdate.Enabled = $false
            $script:DlgBtnRefresh.Enabled = $false
            [System.Windows.Forms.Application]::DoEvents()
            Update-VersionState
            Refresh-UpdateDialog
        })
        $script:DlgBtnUpdate.Add_Click({ Start-AppUpdate })
        $script:DlgBtnCancel.Add_Click({ Stop-AppUpdate -Reason 'user' })
        $script:DlgBtnClose.Add_Click({ if ($script:DlgForm) { $script:DlgForm.Close() } })

        # 進捗ログのテール + 経過時間 + タイムアウト監視
        $script:DlgTimer = New-Object System.Windows.Forms.Timer
        $script:DlgTimer.Interval = 200
        $script:DlgTimer.Add_Tick({ Invoke-UpdateDialogTick })

        # 初回のバージョン確認は画面表示後に実行する（WSL 呼び出しで数秒固まるため）
        $script:DlgInitTimer = New-Object System.Windows.Forms.Timer
        $script:DlgInitTimer.Interval = 120
        $script:DlgInitTimer.Add_Tick({
            try { $script:DlgInitTimer.Stop(); $script:DlgInitTimer.Dispose() } catch {}
            $script:DlgInitTimer = $null
            Update-VersionState
            Refresh-UpdateDialog
        })
        $form.Add_Shown({ if ($script:DlgInitTimer) { $script:DlgInitTimer.Start() } })

        [void]$form.ShowDialog()
    } finally {
        $script:UpdateDialogOpen = $false
    }
}

function Start-AppUpdate {
    if ($script:UpdateRunning) { return }
    if (-not $script:Ver.CanUpdate) { return }

    $v       = $script:Ver
    $tag     = if ($v.LatestTag) { $v.LatestTag } else { 'v' + $v.LatestVersion }
    $curText = if ($v.CurrentVersion) { 'v' + $v.CurrentVersion } else { '（不明）' }
    $newText = 'v' + $v.LatestVersion

    $common = "・所要時間: 5〜20 分（回線速度により変動）`r`n" +
              "・ネットワーク接続が必要です`r`n" +
              "・更新のためセットアップ画面を停止します（完了後に再起動します）`r`n" +
              "・.env（AWS キー・独自ドメイン設定）と setup/setup-state.json は引き継がれます`r`n" +
              "・旧ファイルは ~/homepage.old-<timestamp> に残ります"
    $msg = if ($v.Comparison -eq 'uptodate') {
        "既に最新です（$newText）。`r`n`r`n同じバージョンを再適用（修復）しますか？`r`n`r`n$common`r`n`r`n続行しますか？"
    } else {
        "アプリを $curText → $newText に更新します。`r`n`r`n$common`r`n`r`n続行しますか？"
    }
    $answer = [System.Windows.Forms.MessageBox]::Show(
        $msg, $AppName, [System.Windows.Forms.MessageBoxButtons]::YesNo,
        [System.Windows.Forms.MessageBoxIcon]::Question)
    if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }

    $scriptPath = Get-UpdateScriptPath
    if (-not $scriptPath) {
        [System.Windows.Forms.MessageBox]::Show(
            "更新スクリプトが見つかりません。`nインストーラを再実行してください。`n`n探索場所: $(Get-AppDir)\scripts",
            $AppName, 'OK', 'Error') | Out-Null
        Write-Log 'update-wsl-app.ps1 が見つかりません' 'ERROR'
        return
    }

    $script:UpdateRunning   = $true
    $script:Ver.AppliedVersion = $null
    $script:UpdateBackupDir = $null
    $script:UpdateLogFile   = Join-Path $LogDir ('update-{0:yyyyMMdd-HHmmss-fff}.log' -f (Get-Date))
    $script:UpdateLogPos    = 0
    $script:UpdateLogDecoder = [System.Text.Encoding]::UTF8.GetDecoder()

    $script:DlgLog.Clear()
    $script:DlgLblApplied.Text    = '—'
    $script:DlgLblElapsed.Text    = '経過: 0:00'
    $script:DlgLblLogPath.Text    = Split-Path -Leaf $script:UpdateLogFile
    $script:DlgLblStatus.Text     = "更新を実行しています...（$curText → $newText）"
    $script:DlgBtnCancel.Visible  = $true
    $script:DlgBtnCancel.Enabled  = $true
    Set-DlgRunningState -Running $true
    Update-MenuState

    # 更新は ~/homepage を丸ごと差し替えるため、next start を止めてから実行する
    try { Stop-Server } catch { Write-Log "更新前の停止に失敗: $($_.Exception.Message)" 'WARN' }

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'powershell.exe'
    $psi.Arguments = ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" ' +
                      '-DistroName "{1}" -WslUser "{2}" -TargetVersion "{3}" ' +
                      '-LogDir "{4}" -LogFile "{5}"') -f `
                      $scriptPath, $DistroName, $WslUser, $tag, $LogDir, $script:UpdateLogFile
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true

    try {
        $script:UpdateProc = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Log "更新プロセスを起動できません: $($_.Exception.Message)" 'ERROR'
        $script:UpdateRunning = $false
        Set-DlgRunningState -Running $false
        Update-MenuState
        # 更新自体が始まっていないので、停止したアプリを戻す
        try { Start-Server } catch {}
        [System.Windows.Forms.MessageBox]::Show(
            "更新処理を起動できませんでした: $($_.Exception.Message)`n`nログ: $LogFile",
            $AppName, 'OK', 'Error') | Out-Null
        return
    }

    $script:UpdateStopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    try { $script:DlgTimer.Start() } catch {}
    Write-Log "更新開始: ref=$tag script=$scriptPath log=$($script:UpdateLogFile)"
    $script:NotifyIcon.ShowBalloonTip(2000, $AppName, 'アプリを更新しています（5〜20 分）', 'Info')
}

function Invoke-UpdateDialogTick {
    $text = Read-NewUpdateLogText
    if ($text -and $script:DlgLog) {
        $script:DlgLog.AppendText($text)
        $script:DlgLog.SelectionStart = $script:DlgLog.TextLength
        $script:DlgLog.ScrollToCaret()
    }
    if (-not $script:UpdateRunning) { return }
    if ($script:UpdateStopwatch) {
        $e = $script:UpdateStopwatch.Elapsed
        if ($script:DlgLblElapsed) {
            $script:DlgLblElapsed.Text = ('経過: {0:0}:{1:00}' -f [Math]::Floor($e.TotalMinutes), $e.Seconds)
        }
        if ($e.TotalMinutes -ge $UpdateTimeoutMinutes) {
            Stop-AppUpdate -Reason 'timeout'
            return
        }
    }
    if ($script:UpdateProc -and $script:UpdateProc.HasExited) {
        Complete-AppUpdate
    }
}

function Complete-AppUpdate {
    $proc = $script:UpdateProc
    if (-not $proc) { return }
    $code = $proc.ExitCode
    # 子プロセスの最終書き込みを拾う
    Start-Sleep -Milliseconds 250
    $tail = Read-NewUpdateLogText
    if ($tail -and $script:DlgLog) { $script:DlgLog.AppendText($tail) }

    try { if ($script:DlgTimer) { $script:DlgTimer.Stop() } } catch {}
    $script:UpdateProc    = $null
    $script:UpdateRunning = $false
    Remove-Item -LiteralPath (Join-Path $LogDir 'update-wsl-app.lock') -Force -ErrorAction SilentlyContinue

    $content = if ($script:DlgLog) { $script:DlgLog.Text } else { '' }
    if ($content -match '(?m)^APPLIED_VERSION=(.+)$') { $script:Ver.AppliedVersion = $Matches[1].Trim() }
    if ($content -match '(?m)^BACKUP_DIR=(.+)$')      { $script:UpdateBackupDir = $Matches[1].Trim() }
    if (-not $script:UpdateBackupDir) { $script:UpdateBackupDir = Get-BackupPathFromLog -Text $content }
    $createdBackup = ($content -match '(?m)^CREATED_BACKUP=1') -or [bool]$script:UpdateBackupDir
    $failed = ($code -ne 0) -or ($content -match '(?m)^RESULT=FAILED')

    if (-not $failed) {
        $applied = $script:Ver.AppliedVersion
        if (-not $applied) { $applied = Get-AppVersionFromWsl }
        $script:Ver.AppliedVersion = $applied
        if ($applied) { $script:Ver.CurrentVersion = $applied }
        if ($script:DlgLblApplied) {
            $script:DlgLblApplied.Text = if ($applied) { 'v' + $applied } else { '取得できません' }
        }
        $cmp = Compare-SemVer $applied $script:Ver.LatestVersion
        if ($cmp -eq 0)     { $script:Ver.Comparison = 'uptodate' }
        elseif ($null -ne $cmp -and $cmp -lt 0) { $script:Ver.Comparison = 'update' }
        elseif ($null -ne $cmp) { $script:Ver.Comparison = 'newer' }

        $notice = '更新が完了しました。' + "`r`n`r`n" +
                  '公開サイトのコードはまだ古いので、セットアップ画面 → 運用メニュー → 「アプリコード更新」を実行してください。'
        $appliedText = if ($script:Ver.AppliedVersion) { 'v' + $script:Ver.AppliedVersion } else { '（取得できません）' }
        Write-Log "更新成功: applied=$($script:Ver.AppliedVersion) backup=$($script:UpdateBackupDir)"
        Set-DlgRunningState -Running $false
        Refresh-UpdateDialog
        if ($script:DlgLblStatus) {
            $script:DlgLblStatus.Text = "更新が完了しました（$appliedText）。アプリを再起動します。`r`n" + $notice
        }
        Update-MenuState
        # 終了コード 0 のときだけアプリを再起動する（既存の起動処理を再利用）
        try { Start-Server } catch { Write-Log "再起動に失敗: $($_.Exception.Message)" 'ERROR' }
        [System.Windows.Forms.MessageBox]::Show($notice, $AppName, 'OK', 'Information') | Out-Null
        return
    }

    $reason = '詳細はログを確認してください。'
    if ($content -match '(?m)^FAILURE_REASON=(.+)$') { $reason = $Matches[1].Trim() }
    if ($reason.Length -gt 160) { $reason = $reason.Substring(0, 160) + '…' }

    $rollback = '旧ツリーは差し替え前のため、~/homepage は変更されていません。'
    if ($script:UpdateBackupDir) {
        $rollback = "切り戻しは $($script:UpdateBackupDir) に残っています。`r`n戻す場合: rm -rf ~/homepage && mv '$($script:UpdateBackupDir)' ~/homepage"
    }
    # 画面内の表示は簡潔にし、詳細（ログパス含む）はダイアログで見せる
    $inline = "更新に失敗しました。`r`n原因: $reason`r`n$rollback"
    $summary = "更新に失敗しました。`r`n`r`n原因: $reason`r`n`r`nログ: $($script:UpdateLogFile)`r`n$rollback"
    Write-Log "更新失敗: exit=$code reason=$reason" 'ERROR'
    Set-DlgRunningState -Running $false
    Refresh-UpdateDialog
    if ($script:DlgLblStatus) { $script:DlgLblStatus.Text = $inline }
    Update-MenuState

    # 差し替え前の失敗なら旧バージョンは無傷なので、画面を復旧させる
    if (-not $createdBackup) {
        try { Start-Server } catch { Write-Log "再起動に失敗: $($_.Exception.Message)" 'ERROR' }
    }
    [System.Windows.Forms.MessageBox]::Show($summary, $AppName, 'OK', 'Error') | Out-Null
}

function Stop-AppUpdate {
    param([ValidateSet('user', 'timeout')][string]$Reason = 'user')
    if (-not $script:UpdateRunning) { return }

    if ($Reason -eq 'user') {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "更新を中止しますか？`r`n`r`n途中で中止すると ~/homepage が中途半端な状態になる可能性があります。",
            $AppName, [System.Windows.Forms.MessageBoxButtons]::YesNo,
            [System.Windows.Forms.MessageBoxIcon]::Warning)
        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) { return }
    }

    Write-Log "更新を中止します (reason=$Reason)" 'WARN'
    try {
        if ($script:UpdateProc -and -not $script:UpdateProc.HasExited) { $script:UpdateProc.Kill() }
    } catch {}
    # 子プロセスを止めても WSL 内の bash / npm は残るため、ディストリを終了させる
    try { & wsl.exe --terminate $DistroName 2>&1 | ForEach-Object { Write-Log $_ } } catch {}
    Remove-Item -LiteralPath (Join-Path $LogDir 'update-wsl-app.lock') -Force -ErrorAction SilentlyContinue

    Start-Sleep -Milliseconds 300
    $tail = Read-NewUpdateLogText
    if ($tail -and $script:DlgLog) { $script:DlgLog.AppendText($tail) }

    try { if ($script:DlgTimer) { $script:DlgTimer.Stop() } } catch {}
    $script:UpdateProc    = $null
    $script:UpdateRunning = $false

    $content = if ($script:DlgLog) { $script:DlgLog.Text } else { '' }
    if ($content -match '(?m)^BACKUP_DIR=(.+)$') { $script:UpdateBackupDir = $Matches[1].Trim() }
    if (-not $script:UpdateBackupDir) { $script:UpdateBackupDir = Get-BackupPathFromLog -Text $content }
    $createdBackup = ($content -match '(?m)^CREATED_BACKUP=1') -or [bool]$script:UpdateBackupDir

    $headline = if ($Reason -eq 'timeout') {
        "更新が $UpdateTimeoutMinutes 分を超えたため中止しました。"
    } else {
        '更新を中止しました。'
    }
    $rollback = '旧ツリーは差し替え前のため、~/homepage は変更されていません。'
    if ($script:UpdateBackupDir) {
        $rollback = "切り戻しは $($script:UpdateBackupDir) に残っています。" +
                    "`r`n戻す場合: rm -rf ~/homepage && mv '$($script:UpdateBackupDir)' ~/homepage"
    }
    $summary = "$headline`r`n`r`nログ: $($script:UpdateLogFile)`r`n$rollback"
    Write-Log "更新中止: reason=$Reason" 'WARN'
    Set-DlgRunningState -Running $false
    Refresh-UpdateDialog
    if ($script:DlgLblStatus) { $script:DlgLblStatus.Text = "$headline`r`n$rollback" }
    Update-MenuState

    if (-not $createdBackup) {
        try { Start-Server } catch { Write-Log "再起動に失敗: $($_.Exception.Message)" 'ERROR' }
    }
    [System.Windows.Forms.MessageBox]::Show($summary, $AppName, 'OK', 'Warning') | Out-Null
}

# --- 起動/停止 ----------------------------------------------------------------
$script:WslProcess = $null

function Start-Server {
    if ($script:UpdateRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            "更新の実行中はアプリを起動できません。`n完了（または中止）を待ってください。",
            $AppName, 'OK', 'Information') | Out-Null
        return
    }

    if (-not (Test-DistroExists)) {
        [System.Windows.Forms.MessageBox]::Show(
            "ディストリビューション '$DistroName' が見つかりません。`nインストーラを再実行してください。",
            $AppName, 'OK', 'Error') | Out-Null
        return
    }

    if (Test-PortOpen -Port $Port) {
        Write-Log "Port $Port は既に開放済み。ブラウザだけ開きます。"
        Open-Browser
        return
    }

    Write-Log "サーバー起動: wsl -d $DistroName -u $WslUser -- bash -i $StartScript"
    # WSL イメージ内の start.sh に nvm 初期化 (~/.bashrc) と npm run dev を任せる。
    # ~/.bashrc は非対話シェルだと冒頭で return するため、bash -i で対話シェル扱いにする。
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName  = 'wsl.exe'
    $psi.Arguments = "-d $DistroName -u $WslUser -- bash -i $StartScript"
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow  = $true
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError  = $true

    try {
        $script:WslProcess = [System.Diagnostics.Process]::Start($psi)
    } catch {
        Write-Log "プロセス起動失敗: $($_.Exception.Message)" 'ERROR'
        [System.Windows.Forms.MessageBox]::Show("起動に失敗しました: $($_.Exception.Message)", $AppName, 'OK', 'Error') | Out-Null
        return
    }

    # 標準出力をログへ流す（非同期）
    Register-ObjectEvent -InputObject $script:WslProcess -EventName OutputDataReceived -Action {
        if ($EventArgs.Data) { Add-Content -LiteralPath $using:LogFile -Value "[stdout] $($EventArgs.Data)" }
    } | Out-Null
    Register-ObjectEvent -InputObject $script:WslProcess -EventName ErrorDataReceived -Action {
        if ($EventArgs.Data) { Add-Content -LiteralPath $using:LogFile -Value "[stderr] $($EventArgs.Data)" }
    } | Out-Null
    $script:WslProcess.BeginOutputReadLine()
    $script:WslProcess.BeginErrorReadLine()

    $script:NotifyIcon.ShowBalloonTip(2000, $AppName, 'サーバー起動中...', 'Info')
    Update-MenuState

    # ポーリングしてブラウザを開く
    $script:WaitTimer = New-Object System.Windows.Forms.Timer
    $script:WaitTimer.Interval = 1000
    $script:WaitElapsed = 0
    $script:WaitTimer.Add_Tick({
        $script:WaitElapsed++
        if (Test-PortOpen -Port $Port) {
            $script:WaitTimer.Stop()
            $script:WaitTimer.Dispose()
            $script:WaitTimer = $null
            Open-Browser
            $script:NotifyIcon.ShowBalloonTip(2000, $AppName, "起動しました (http://localhost:$Port)", 'Info')
        } elseif ($script:WaitElapsed -ge 600) {
            # 暴走防止: 10分経っても 3001 が開かなければサイレントに停止
            # （balloon は出さない: 起動できているかはブラウザを開けば判る）
            Write-Log "ポート $Port のオープンを 600 秒待っても確認できなかったため、ポーリングを停止します。" 'WARN'
            $script:WaitTimer.Stop()
            $script:WaitTimer.Dispose()
            $script:WaitTimer = $null
        }
    })
    $script:WaitTimer.Start()
}

function Stop-Server {
    if ($script:WaitTimer) {
        try { $script:WaitTimer.Stop(); $script:WaitTimer.Dispose() } catch {}
        $script:WaitTimer = $null
    }
    Write-Log "停止: wsl --terminate $DistroName"
    & wsl.exe --terminate $DistroName 2>&1 | ForEach-Object { Write-Log $_ }
    if ($script:WslProcess -and -not $script:WslProcess.HasExited) {
        try { $script:WslProcess.WaitForExit(3000) | Out-Null } catch {}
        if (-not $script:WslProcess.HasExited) {
            try { $script:WslProcess.Kill() } catch {}
        }
    }
    $script:WslProcess = $null
    $script:NotifyIcon.ShowBalloonTip(2000, $AppName, '停止しました', 'Info')
    Update-MenuState
}

function Open-Browser {
    Start-Process "http://localhost:$Port"
}

function Open-LogFolder {
    Start-Process explorer.exe $LogDir
}

# --- 診断モード（サポート・自動テスト用） --------------------------------------
if ($Diagnose) {
    Write-EarlyLog 'Diagnose: 開始'
    Update-VersionState
    Write-EarlyLog 'Diagnose: 状態取得完了'
    $json = [pscustomobject][ordered]@{
        DistroName     = $DistroName
        DistroExists   = $script:Ver.DistroExists
        HomepageExists = $script:Ver.HomepageExists
        CurrentVersion = $script:Ver.CurrentVersion
        LatestTag      = $script:Ver.LatestTag
        LatestVersion  = $script:Ver.LatestVersion
        LatestSource   = $script:Ver.LatestSource
        LatestError    = $script:Ver.LatestError
        Comparison     = $script:Ver.Comparison
        CanUpdate      = $script:Ver.CanUpdate
        UpdateScript   = (Get-UpdateScriptPath)
    } | ConvertTo-Json -Depth 4
    Write-EarlyLog ('Diagnose: ' + $json)
    try { [Console]::Out.WriteLine($json) } catch {}
    exit 0
}

# --- UI -----------------------------------------------------------------------
function Get-AppIcon {
    # 同梱 icon.ico があれば使う
    $here = Get-AppDir

    $parent = $null
    if ($here) {
        try { $parent = Split-Path -Parent $here } catch {}
    }

    $candidates = @()
    if ($here)   { $candidates += (Join-Path $here   'icon.ico') }
    if ($here)   { $candidates += (Join-Path $here   'assets\icon.ico') }
    if ($parent) { $candidates += (Join-Path $parent 'assets\icon.ico') }

    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c)) {
            try { return New-Object System.Drawing.Icon($c) } catch {}
        }
    }
    return [System.Drawing.SystemIcons]::Application
}

$script:NotifyIcon = New-Object System.Windows.Forms.NotifyIcon
$script:NotifyIcon.Icon    = Get-AppIcon
$script:NotifyIcon.Text    = $AppName
$script:NotifyIcon.Visible = $true

$menu = New-Object System.Windows.Forms.ContextMenuStrip
$miStart   = $menu.Items.Add('起動 (npm run dev)')
$miStop    = $menu.Items.Add('停止')
$miBrowser = $menu.Items.Add('ブラウザを開く')
[void]$menu.Items.Add('-')
$miUpdate  = $menu.Items.Add('アプリを更新...')
$miLog     = $menu.Items.Add('ログフォルダを開く')
[void]$menu.Items.Add('-')
$miExit    = $menu.Items.Add('終了')

$miStart.Add_Click({ Start-Server })
$miStop.Add_Click({ Stop-Server })
$miBrowser.Add_Click({ Open-Browser })
$miUpdate.Add_Click({ Show-UpdateDialog })
$miLog.Add_Click({ Open-LogFolder })
$miExit.Add_Click({
    if ($script:UpdateRunning) {
        [System.Windows.Forms.MessageBox]::Show(
            '更新の実行中は終了できません。完了（または中止）を待ってください。',
            $AppName, 'OK', 'Information') | Out-Null
        return
    }
    if (Test-DistroRunning) {
        $r = [System.Windows.Forms.MessageBox]::Show(
            'サーバーが起動中です。停止して終了しますか？',
            $AppName, 'YesNoCancel', 'Question')
        if ($r -eq 'Cancel') { return }
        if ($r -eq 'Yes') { Stop-Server }
    }
    $script:NotifyIcon.Visible = $false
    [System.Windows.Forms.Application]::Exit()
})

$script:NotifyIcon.ContextMenuStrip = $menu
$script:NotifyIcon.Add_DoubleClick({ Open-Browser })

function Update-MenuState {
    $running = Test-DistroRunning
    if ($script:UpdateRunning) {
        # 更新中は起動/停止/更新のいずれも受け付けない（二重実行・競合防止）
        if ($miStart)  { $miStart.Enabled  = $false }
        if ($miStop)   { $miStop.Enabled   = $false }
        if ($miUpdate) { $miUpdate.Enabled = $false; $miUpdate.Text = 'アプリを更新...(実行中)' }
        return
    }
    if ($miStart)  { $miStart.Enabled  = -not $running }
    if ($miStop)   { $miStop.Enabled   = $running }
    if ($miUpdate) { $miUpdate.Enabled = $true;  $miUpdate.Text = 'アプリを更新...' }
}

# 状態の定期更新
$stateTimer = New-Object System.Windows.Forms.Timer
$stateTimer.Interval = 5000
$stateTimer.Add_Tick({ Update-MenuState })
$stateTimer.Start()
Update-MenuState

Write-Log "=== Tray 起動 ==="
$script:NotifyIcon.ShowBalloonTip(1500, $AppName, 'タスクトレイで待機中', 'Info')

# -AutoStart 指定時はサーバ起動も自動で行う
if ($AutoStart) {
    Write-Log "AutoStart 指定: Start-Server を実行"
    try { Start-Server } catch { Write-Log "AutoStart 失敗: $($_.Exception.Message)" 'ERROR' }
}

[System.Windows.Forms.Application]::Run()

# 終了処理
try { $script:NotifyIcon.Dispose() } catch {}
try { $script:Mutex.ReleaseMutex() } catch {}

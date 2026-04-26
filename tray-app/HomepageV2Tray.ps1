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
    [int]   $Port        = 3001,
    [string]$BaseDir     = (Join-Path $env:LOCALAPPDATA 'HomepageV2'),
    [string]$AppName     = 'homepage-v2-installer',
    [switch]$AutoStart
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
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction SilentlyContinue
        [System.Windows.Forms.MessageBox]::Show(
            "起動時エラー:`n$($_.Exception.Message)`n`n詳細は次のログを参照してください:`n$script:EarlyLogFile",
            'homepage-v2-installer', 'OK', 'Error') | Out-Null
    } catch {}
    exit 1
}
$ErrorActionPreference = 'Stop'
Write-EarlyLog "=== Tray 起動開始 (PID=$PID) ==="
Write-EarlyLog ("PSCommandPath='{0}' PSScriptRoot='{1}'" -f $PSCommandPath, $PSScriptRoot)

# --- シングルインスタンス -----------------------------------------------------
$mutexName = 'Global\HomepageV2InstallerTray'
$createdNew = $false
$script:Mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    [System.Windows.Forms.MessageBox]::Show('homepage-v2-installer は既に起動中です。', $AppName) | Out-Null
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

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

function Test-DistroExists {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $list = (& wsl.exe --list --quiet) 2>$null
    } finally { [Console]::OutputEncoding = $prev }
    if (-not $list) { return $false }
    return ($list | Where-Object { $_.Trim() -eq $DistroName }).Count -gt 0
}

function Test-DistroRunning {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::Unicode
        $list = (& wsl.exe --list --running --quiet) 2>$null
    } finally { [Console]::OutputEncoding = $prev }
    if (-not $list) { return $false }
    return ($list | Where-Object { $_.Trim() -eq $DistroName }).Count -gt 0
}

# --- 起動/停止 ----------------------------------------------------------------
$script:WslProcess = $null

function Start-Server {
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

# --- UI -----------------------------------------------------------------------
function Get-AppIcon {
    # 同梱 icon.ico があれば使う
    # ps2exe で .exe 化された場合 $PSCommandPath は空になるため、複数のソースを順に試す
    $here = $null
    if ($PSCommandPath) {
        $here = Split-Path -Parent $PSCommandPath
    }
    if (-not $here -and $PSScriptRoot) {
        $here = $PSScriptRoot
    }
    if (-not $here) {
        try {
            $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
            if ($exePath) { $here = Split-Path -Parent $exePath }
        } catch {}
    }
    if (-not $here) {
        $here = (Get-Location).Path
    }

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
$miLog     = $menu.Items.Add('ログフォルダを開く')
[void]$menu.Items.Add('-')
$miExit    = $menu.Items.Add('終了')

$miStart.Add_Click({ Start-Server })
$miStop.Add_Click({ Stop-Server })
$miBrowser.Add_Click({ Open-Browser })
$miLog.Add_Click({ Open-LogFolder })
$miExit.Add_Click({
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
    $miStart.Enabled = -not $running
    $miStop.Enabled  = $running
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

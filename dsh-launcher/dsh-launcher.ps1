#Requires -Version 5.1
# ============================================================
#  DeepSeek Harness 一键启动器 (GUI 合并版)
#  - 打开即检查更新（npm view 优先，直连 registry 兜底）
#  - 启动 / 关闭 / 更新 / 打开窗口
#  - 点「X」最小化到系统托盘；托盘右键「退出」会一并关闭服务
# ============================================================
param([switch]$SelfTest)

$ErrorActionPreference = 'SilentlyContinue'

# ============================================================
#  关键修复：NotifyIcon（系统托盘图标）必须在 STA 线程上运行。
#  若在本机默认的 MTA 线程运行，点击「X」时 FormClosing 里设置
#  notifyIcon.Visible = $true 会抛异常，异常从 ShowDialog 冒出，
#  触发 finally 释放托盘图标并结束整个 PowerShell 进程 —— 表现就是：
#  窗口/托盘全消失、PowerShell 退出，而 dsh 服务（独立进程）仍在跑。
#  若当前不是 STA，则以 -STA 重新启动自身（保持隐藏控制台，行为不变）。
# ============================================================

# 诊断日志：整个生命周期写入 %TEMP%\dsh-launcher-debug.log，
# 若托盘/退出行为仍异常，直接看这个文件即可定位，无需再猜。
$script:DebugLog = Join-Path $env:TEMP 'dsh-launcher-debug.log'
function Write-Dbg([string]$msg) {
    try {
        $line = (Get-Date -Format 'HH:mm:ss.fff') + "  PID=$PID  " + $msg
        Add-Content -LiteralPath $script:DebugLog -Value $line -Encoding utf8
    } catch { }
}
try { Remove-Item -LiteralPath $script:DebugLog -ErrorAction SilentlyContinue } catch { }

$apt = [System.Threading.Thread]::CurrentThread.ApartmentState
Write-Dbg "脚本启动：ApartmentState=$apt PSCommandPath=$PSCommandPath"
if ($apt -ne 'STA') {
    Write-Dbg '检测到 MTA 线程，尝试以 -STA 重启自身'
    $staLaunched = $false
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = 'powershell.exe'
        $psi.Arguments = "-STA -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`""
        $psi.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
        [void][System.Diagnostics.Process]::Start($psi)
        $staLaunched = $true
        Write-Dbg 'STA 子进程已拉起，本 MTA 进程即将退出'
    } catch {
        Write-Dbg "STA 自举失败：$($_.Exception.Message)"
    }
    if ($staLaunched) { exit }
    Write-Dbg '自举失败，降级继续运行（窗口可用，但托盘行为可能不稳定）'
} else {
    Write-Dbg '已在 STA 线程，直接运行 GUI'
}

$Port        = 3080
$PkgName     = '@deepseek-ai/dsh'
$NpxRoot     = Join-Path $env:LOCALAPPDATA 'npm-cache\_npx'
$ServerTitle = 'DeepSeek Harness Server'
$AppUrl      = "http://127.0.0.1:$Port"

# ================= 基础函数 =================

function Get-ListenerPid([int]$p) {
    $line = netstat -ano | Select-String -Pattern ":$p\s" | Select-String 'LISTENING' | Select-Object -First 1
    if ($line) {
        $tokens = ($line.ToString().Trim() -split '\s+')
        return [int]$tokens[-1]
    }
    return $null
}

function Get-NpmExe {
    $npm = (Get-Command npm.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npm) { $npm = (Get-Command npm -ErrorAction SilentlyContinue).Source }
    return $npm
}

function Get-NpxExe {
    $npx = (Get-Command npx.cmd -ErrorAction SilentlyContinue).Source
    if (-not $npx) { $npx = (Get-Command npx -ErrorAction SilentlyContinue).Source }
    return $npx
}

function Get-CacheDir {
    foreach ($d in (Get-ChildItem $NpxRoot -Directory -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)) {
        if (Test-Path (Join-Path $d.FullName "node_modules\$PkgName\package.json")) { return $d.FullName }
    }
    return $null
}

function Get-LocalVersion {
    $dir = Get-CacheDir
    if ($dir) {
        try { return (Get-Content (Join-Path $dir "node_modules\$PkgName\package.json") -Raw | ConvertFrom-Json).version } catch { }
    }
    return $null
}

function Get-LatestVersion {
    # 方式 1：npm view（可能受 npm 缓存 EPERM 影响）
    $npm = Get-NpmExe
    if ($npm) {
        try {
            $out = & $npm view $PkgName version --fetch-timeout=15000 --fetch-retries=0 2>$null
            if ($LASTEXITCODE -eq 0 -and $out) {
                $v = (($out | Select-Object -Last 1) -as [string]).Trim()
                if ($v) { return $v }
            }
        } catch { }
    }
    # 方式 2：直连 registry（绕过 npm 缓存，避免 EPERM / 网络抖动）
    try {
        $reg = (& $npm config get registry 2>$null)
        if (-not $reg) { $reg = 'https://registry.npmjs.org' }
        $reg = $reg.Trim().TrimEnd('/')
        $pkgPath = $PkgName -replace '/', '%2F'
        $url = "$reg/$pkgPath/latest"
        $json = Invoke-RestMethod -Uri $url -TimeoutSec 15 -ErrorAction Stop
        if ($json -and $json.version) { return $json.version }
    } catch { }
    return $null
}

function Test-NeedUpdate($local, $latest) {
    if (-not $local -or -not $latest) { return $true }
    try { return ([version]$local -lt [version]$latest) } catch { return ($local -ne $latest) }
}

function Stop-ProcessTree([int]$rootId) {
    # 杀掉 rootId 及其所有子孙进程
    $all = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    $children = @{}
    foreach ($proc in $all) {
        $ppid = [int]$proc.ParentProcessId
        if (-not $children.ContainsKey($ppid)) { $children[$ppid] = New-Object System.Collections.Generic.List[int] }
        $children[$ppid].Add([int]$proc.ProcessId)
    }
    $toKill = New-Object System.Collections.Generic.List[int]
    $queue = New-Object System.Collections.Queue
    $queue.Enqueue($rootId)
    while ($queue.Count -gt 0) {
        $cur = [int]$queue.Dequeue()
        if ($children.ContainsKey($cur)) { foreach ($c in $children[$cur]) { $queue.Enqueue($c) } }
        if ($cur -ne $rootId) { $toKill.Add($cur) }
    }
    $toKill.Reverse()
    foreach ($id in $toKill) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue }
    Stop-Process -Id $rootId -Force -ErrorAction SilentlyContinue
}

function Get-DshPids {
    # 识别 dsh 相关的 node 进程（命令行含 bin.js / @deepseek-ai / \dsh\ 特征，排除无关 node 如 weixinpay）
    # 兼容性：优先用 CIM 取命令行（Win11 24H2+ 已移除 wmic）；CIM 取不到时退回 wmic
    $pids = New-Object System.Collections.Generic.List[int]
    $cmdlines = @{}
    # 方式 1：CIM（现代系统默认路径）
    try {
        $procs = Get-CimInstance Win32_Process -Filter "Name='node.exe'" -ErrorAction Stop
        foreach ($p in $procs) {
            if ($p.ProcessId -and $p.CommandLine) { $cmdlines[[int]$p.ProcessId] = [string]$p.CommandLine }
        }
    } catch { }
    # 方式 2：wmic 兜底（部分环境 CIM 取不到 CommandLine，如本机曾遇到的坑）——两边合并去重
    try {
        $out = wmic process where "name='node.exe'" get ProcessId,CommandLine /format:csv 2>$null
        foreach ($line in $out) {
            if ($line -match 'node\.exe' -and $line -match ',(\d+)\s*$') {
                [int]$p = 0
                if ([int]::TryParse($Matches[1].Trim(), [ref]$p)) {
                    if (-not $cmdlines.ContainsKey($p)) { $cmdlines[$p] = [string]$line }
                }
            }
        }
    } catch { }
    foreach ($k in @($cmdlines.Keys)) {
        if ($cmdlines[$k] -match 'bin\\\.js|@deepseek-ai|\\dsh\\') {
            if ($pids -notcontains $k) { $pids.Add($k) }
        }
    }
    return $pids
}

function Kill-Service {
    # 可靠清理 dsh 服务相关进程（端口监听者 + wmic 命令行特征匹配），直到端口释放
    $deadline = (Get-Date).AddSeconds(25)
    while ((Get-Date) -lt $deadline) {
        $targets = New-Object System.Collections.Generic.List[int]
        # 1) 端口监听进程
        $lp = Get-ListenerPid $Port
        if ($lp) { if ($targets -notcontains $lp) { $targets.Add($lp) } }
        # 2) wmic 匹配 dsh node 进程（绕过 Get-CimInstance 取不到 CommandLine 的坑）
        foreach ($p in (Get-DshPids)) { if ($targets -notcontains $p) { $targets.Add($p) } }
        if ($targets.Count -eq 0) { return $true }
        foreach ($t in $targets) {
            Write-Log "关闭残留进程 PID=$t"
            Stop-ProcessTree $t
        }
        # 额外杀端口监听者的父进程（cmd 包在外面时父进程不是子节点）
        if ($lp) {
            try {
                $parent = (Get-CimInstance Win32_Process -Filter "ProcessId=$lp" -ErrorAction SilentlyContinue).ParentProcessId
                if ($parent) { Stop-Process -Id $parent -Force -ErrorAction SilentlyContinue }
            } catch { }
        }
        Start-Sleep -Milliseconds 800
    }
    # 超时后再次确认端口是否释放
    return (-not (Get-ListenerPid $Port))
}

function Open-AppWindow {
    $desktop = [Environment]::GetFolderPath('Desktop')
    $lnk = Join-Path $desktop 'DeepSeek Harness.lnk'
    if (Test-Path $lnk) { try { Start-Process $lnk; return } catch { } }
    Start-Process $AppUrl
}

# ================= 自检模式 (无 GUI) =================
if ($SelfTest) {
    Write-Output "listener_pid=$(Get-ListenerPid $Port)"
    Write-Output "local_version=$(Get-LocalVersion)"
    Write-Output "latest_version=$(Get-LatestVersion)"
    Write-Output "npm=$(Get-NpmExe)"
    Write-Output "npx=$(Get-NpxExe)"
    exit 0
}

# ================= GUI =================
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[System.Windows.Forms.Application]::EnableVisualStyles()

$form = New-Object System.Windows.Forms.Form
$form.Text = 'DeepSeek Harness 启动器'
$form.ClientSize = New-Object System.Drawing.Size(600, 490)
$form.StartPosition = 'CenterScreen'
$form.FormBorderStyle = 'FixedSingle'
$form.MaximizeBox = $false
$form.ShowInTaskbar = $true
$form.BackColor = [System.Drawing.Color]::White
$form.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)

# 应用图标（酒红色版）
$appIcon = $null
try { $appIcon = New-Object System.Drawing.Icon((Join-Path $PSScriptRoot 'dsh-red.ico')) } catch { }
if (-not $appIcon) {
    # 兜底：用纯色位图生成一个图标，确保 NotifyIcon 永远有图标可显示
    # （NotifyIcon 在 Icon 为空时设置 Visible 会抛异常，导致托盘不显示）
    try {
        $bmp = New-Object System.Drawing.Bitmap(32, 32)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.Clear([System.Drawing.Color]::FromArgb(37, 99, 235))
        $g.FillEllipse([System.Drawing.Brushes]::White, 7, 7, 18, 18)
        $g.Dispose()
        $appIcon = [System.Drawing.Icon]::FromHandle($bmp.GetHicon())
    } catch { }
}
if ($appIcon) { $form.Icon = $appIcon }

# ---- 顶部标题区 ----
$pnlAccent = New-Object System.Windows.Forms.Panel
$pnlAccent.Size = New-Object System.Drawing.Size(5, 30)
$pnlAccent.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
$pnlAccent.Location = New-Object System.Drawing.Point(14, 14)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = 'DeepSeek Harness 启动器'
$lblTitle.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 15, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::FromArgb(24, 36, 68)
$lblTitle.AutoSize = $true
$lblTitle.Location = New-Object System.Drawing.Point(26, 17)

$pnlDivider = New-Object System.Windows.Forms.Panel
$pnlDivider.Size = New-Object System.Drawing.Size(576, 1)
$pnlDivider.BackColor = [System.Drawing.Color]::FromArgb(228, 232, 238)
$pnlDivider.Location = New-Object System.Drawing.Point(12, 52)

# ---- 状态 / 版本 / 地址 ----
$lblStatus = New-Object System.Windows.Forms.Label
$lblStatus.Text = '正在检测...'
$lblStatus.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 11, [System.Drawing.FontStyle]::Bold)
$lblStatus.AutoSize = $true
$lblStatus.Location = New-Object System.Drawing.Point(24, 70)

$lblVersion = New-Object System.Windows.Forms.Label
$lblVersion.Text = '版本信息加载中...'
$lblVersion.AutoSize = $true
$lblVersion.Location = New-Object System.Drawing.Point(24, 100)

$lblAddr = New-Object System.Windows.Forms.Label
$lblAddr.Text = "服务地址：$AppUrl"
$lblAddr.ForeColor = [System.Drawing.Color]::FromArgb(130, 138, 150)
$lblAddr.AutoSize = $true
$lblAddr.Location = New-Object System.Drawing.Point(24, 124)

# ---- 按钮行 (5 个按钮一行) ----
$flowBtns = New-Object System.Windows.Forms.FlowLayoutPanel
$flowBtns.Location = New-Object System.Drawing.Point(20, 154)
$flowBtns.Size = New-Object System.Drawing.Size(560, 42)
$flowBtns.FlowDirection = 'LeftToRight'
$flowBtns.WrapContents = $false

function New-Btn([string]$text, [switch]$Primary) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.Size = New-Object System.Drawing.Size(100, 34)
    $b.Margin = New-Object System.Windows.Forms.Padding(4, 4, 4, 4)
    $b.FlatStyle = 'Flat'
    $b.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($Primary) {
        $b.BackColor = [System.Drawing.Color]::FromArgb(37, 99, 235)
        $b.ForeColor = [System.Drawing.Color]::White
        $b.FlatAppearance.BorderSize = 0
    } else {
        $b.UseVisualStyleBackColor = $true
        $b.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(210, 215, 225)
    }
    return $b
}
$btnStart  = New-Btn '启动服务' -Primary
$btnStop   = New-Btn '关闭服务'
$btnUpdate = New-Btn '检查/更新'
$btnOpen   = New-Btn '打开窗口'
$btnExit   = New-Btn '退出'

# ---- 操作日志 ----
$lblLogTitle = New-Object System.Windows.Forms.Label
$lblLogTitle.Text = '操作日志'
$lblLogTitle.ForeColor = [System.Drawing.Color]::FromArgb(130, 138, 150)
$lblLogTitle.AutoSize = $true
$lblLogTitle.Location = New-Object System.Drawing.Point(24, 212)

$logBox = New-Object System.Windows.Forms.TextBox
$logBox.Multiline = $true
$logBox.ReadOnly = $true
$logBox.ScrollBars = 'Vertical'
$logBox.BackColor = [System.Drawing.Color]::FromArgb(250, 251, 252)
$logBox.BorderStyle = 'FixedSingle'
$logBox.Font = New-Object System.Drawing.Font('Microsoft YaHei UI', 9)
$logBox.Location = New-Object System.Drawing.Point(24, 234)
$logBox.Size = New-Object System.Drawing.Size(552, 200)

# ---- 底部提示 ----
$lblFooter = New-Object System.Windows.Forms.Label
$lblFooter.Text = '提示：点「X」最小化到系统托盘；托盘右键「退出」会关闭服务并退出启动器。'
$lblFooter.ForeColor = [System.Drawing.Color]::FromArgb(160, 166, 175)
$lblFooter.AutoSize = $true
$lblFooter.Location = New-Object System.Drawing.Point(24, 452)

# ================= UI 辅助函数 =================

function Update-UI([scriptblock]$sb) {
    if ($form.InvokeRequired) { [void]$form.Invoke([System.Windows.Forms.MethodInvoker]$sb) }
    else { & $sb }
}

function Start-Async([scriptblock]$action) {
    try {
        $rs = [runspacefactory]::CreateRunspace()
        $rs.Open()
        $ps = [powershell]::Create()
        $ps.Runspace = $rs
        # --- 注入 UI 控件与配置变量（独立运行空间无法直接访问闭包） ---
        foreach ($v in @('form','logBox','lblStatus','lblVersion','btnStart','btnStop','btnUpdate')) {
            [void]$ps.AddCommand('Set-Variable').AddParameter('Name', $v).AddParameter('Value', (Get-Variable -Name $v -ValueOnly)).AddParameter('Scope', 'Script')
        }
        foreach ($v in @('Port','PkgName','NpxRoot','ServerTitle','AppUrl')) {
            [void]$ps.AddCommand('Set-Variable').AddParameter('Name', $v).AddParameter('Value', (Get-Variable -Name $v -ValueOnly)).AddParameter('Scope', 'Script')
        }
        foreach ($v in @('local','latest','busy','logLine','RealExit')) {
            [void]$ps.AddCommand('Set-Variable').AddParameter('Name', $v).AddParameter('Value', (Get-Variable -Name $v -Scope Script -ValueOnly)).AddParameter('Scope', 'Script')
        }
        # --- 注入函数定义 ---
        $funcs = @('Get-ListenerPid','Get-NpmExe','Get-NpxExe','Get-CacheDir','Get-LocalVersion','Get-LatestVersion','Test-NeedUpdate','Stop-ProcessTree','Get-DshPids','Kill-Service','Open-AppWindow','Update-UI','Write-Log','Set-Busy','Refresh-Status','Refresh-Labels','Start-DshService','Stop-DshService','Update-Dsh')
        $prelude = ''
        foreach ($fn in $funcs) {
            $body = (Get-Content "function:$fn").ToString()
            $prelude += "function $fn { $body }`n"
        }
        [void]$ps.AddScript($prelude + $action.ToString())
        [void]$ps.BeginInvoke()
        # 注意：不 Dispose $ps，避免异步操作被取消；进程退出时自然回收
    } catch { }
}

function Write-Log([string]$msg) {
    $script:logLine = (Get-Date -Format 'HH:mm:ss') + "  " + $msg
    Update-UI {
        $logBox.AppendText($script:logLine + "`r`n")
        $logBox.SelectionStart = $logBox.TextLength
        $logBox.ScrollToCaret()
    }
}

function Set-Busy([bool]$b) {
    $script:busy = $b
    Update-UI {
        $btnStart.Enabled = -not $script:busy
        $btnStop.Enabled  = -not $script:busy
        $btnUpdate.Enabled = -not $script:busy
    }
}

function Refresh-Status {
    $pid0 = Get-ListenerPid $Port
    Update-UI {
        if ($pid0) {
            $lblStatus.Text = "● 服务运行中（PID $pid0）"
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
        } else {
            $lblStatus.Text = '○ 服务未运行'
            $lblStatus.ForeColor = [System.Drawing.Color]::FromArgb(180, 40, 40)
        }
    }
}

function Refresh-Labels {
    $script:local  = Get-LocalVersion
    $script:latest = $script:latest
    Update-UI {
        if ($script:local) { $lblVersion.Text = "本地版本：$($script:local)" }
        else { $lblVersion.Text = '本地版本：未安装（首次运行）' }
        if ($script:latest) { $lblVersion.Text += "    最新版本：$($script:latest)" }
        if (Test-NeedUpdate $script:local $script:latest) {
            $lblVersion.ForeColor = [System.Drawing.Color]::FromArgb(202, 102, 0)
            $lblVersion.Text += '    ← 有新版本，可点「检查/更新」'
        } else {
            $lblVersion.ForeColor = [System.Drawing.Color]::FromArgb(60, 60, 60)
        }
    }
}

# ================= 业务动作 =================

function Start-DshService {
    Write-Log '== 启动服务 =='
    # 先清理可能残留的 dsh 进程（防止 cordis.yml 写锁导致 EPERM，解决「关闭再启动失败」）
    Kill-Service | Out-Null
    Start-Sleep -Milliseconds 500

    $attempts = 0
    $maxAttempts = 3
    $ready = $false
    while ($attempts -lt $maxAttempts -and -not $ready) {
        $attempts++
        Write-Log "第 $attempts 次尝试启动..."
        $listenerPid = Get-ListenerPid $Port
        if ($listenerPid) {
            $proc = Get-Process -Id $listenerPid -ErrorAction SilentlyContinue
            if ($proc -and $proc.ProcessName -match '^node') {
                Write-Log "服务已在运行（PID $listenerPid）。"
                $ready = $true; break
            }
            Write-Log "端口 $Port 被其他程序占用（PID $listenerPid），无法启动。"
            break
        }
        # 启动前检测 cordis.yml 是否被占用（绕过杀毒/云同步瞬时锁）
        $cordisFile = Join-Path $env:USERPROFILE '.dsh\profiles\web\cordis.yml'
        $unlocked = $true
        if (Test-Path $cordisFile) {
            try { $s = [System.IO.File]::Open($cordisFile, 'Open', 'Write', 'None'); $s.Close() }
            catch { $unlocked = $false }
        }
        if (-not $unlocked) {
            Write-Log "cordis.yml 正被其他程序占用，等待最多 15 秒释放..."
            $w = 0
            while ($w -lt 15 -and -not $unlocked) {
                Start-Sleep -Seconds 1; $w++
                try { $s = [System.IO.File]::Open($cordisFile, 'Open', 'Write', 'None'); $s.Close(); $unlocked = $true }
                catch { $unlocked = $false }
            }
        }
        if (-not $unlocked) {
            Write-Log "cordis.yml 仍被占用（疑似杀毒软件实时扫描或云同步）。建议把 $env:USERPROFILE\.dsh 加入杀毒/Defender 排除项后再启动。"
        }
        # 服务日志落盘（便于排查）
        $logFile = Join-Path $env:TEMP 'dsh-server.log'
        $errFile = Join-Path $env:TEMP 'dsh-server-err.log'
        # 优先直接运行本地缓存的 dsh（绕过 npx/npm，规避 npm 缓存 EPERM 与网络抖动）
        $nodeExe = (Get-Command node.exe -ErrorAction SilentlyContinue).Source
        $cacheDir = Get-CacheDir
        $bin = $null
        if ($cacheDir) {
            $candidate = Join-Path $cacheDir "node_modules\$PkgName\lib\bin.js"
            if (Test-Path $candidate) { $bin = $candidate }
        }
        if ($bin -and $nodeExe) {
            Write-Log "启动命令：node `"$bin`" web（本地缓存，绕过 npx）"
            Start-Process -FilePath $nodeExe -ArgumentList $bin,'web' -WorkingDirectory $PWD -WindowStyle Minimized -RedirectStandardOutput $logFile -RedirectStandardError $errFile
        } else {
            Write-Log "启动命令：npx --prefer-online $PkgName web（未找到本地缓存）"
            Start-Process -FilePath $env:ComSpec -ArgumentList '/c', "npx --prefer-online $PkgName web" -WorkingDirectory $PWD -WindowStyle Minimized -RedirectStandardOutput $logFile -RedirectStandardError $errFile
        }
        Write-Log "服务日志：$logFile（错误日志：$errFile）"
        Write-Log '正在等待服务就绪（最长 90 秒，首次冷启动较慢约 40~60 秒）...'
        $deadline = (Get-Date).AddSeconds(90)
        $waited = 0
        while ((Get-Date) -lt $deadline) {
            if (Get-ListenerPid $Port) { $ready = $true; break }
            $waited += 2
            if ($waited % 10 -eq 0) { Write-Log "已等待约 ${waited} 秒，仍在启动中..." }
            Start-Sleep -Seconds 2
        }
        if (-not $ready) {
            $errTail = ''
            try { $errTail = (Get-Content $errFile -Tail 6 -ErrorAction SilentlyContinue) -join ' | ' } catch { }
            if ($errTail -match 'EPERM') {
                Write-Log "检测到 EPERM（cordis.yml 被占用，多为杀毒/Defender 瞬时扫描）。已清理残留进程，等待 8 秒让扫描释放后自动重试..."
                Kill-Service | Out-Null
                Start-Sleep -Seconds 8
            } else {
                Write-Log "启动超时。错误日志：$errTail"
                break
            }
        }
    }
    Refresh-Status
    if ($ready) {
        Write-Log "服务已就绪：$AppUrl"
        Open-AppWindow
    } else {
        Write-Log "启动失败。若持续 EPERM，请确认没有其他程序（杀毒/云同步）正在扫描 $env:USERPROFILE\.dsh 目录，或手动结束占用 cordis.yml 的进程后重试。"
    }
}

function Stop-DshService {
    Write-Log '== 关闭服务 =='
    if (-not (Get-ListenerPid $Port)) { Write-Log '服务未在运行。'; Refresh-Status; return }
    $ok = Kill-Service
    Start-Sleep -Milliseconds 600
    Refresh-Status
    if (Get-ListenerPid $Port) { Write-Log '端口仍被占用，关闭可能未完全成功。' }
    else { Write-Log '服务已关闭。' }
}

function Update-Dsh {
    Write-Log '== 检查 / 更新 =='
    if (Get-ListenerPid $Port) { Write-Log '服务正在运行，请先点击「关闭服务」再执行更新。'; return }
    Write-Log '正在查询 npm 最新版本...'
    $latest = Get-LatestVersion
    if (-not $latest) { Write-Log '无法连接 npm 仓库（可能离线），更新中止。'; return }
    $local = Get-LocalVersion
    if (-not (Test-NeedUpdate $local $latest)) {
        Write-Log "已是最新版本（$latest），无需更新。"
        $script:latest = $latest
        Refresh-Labels
        return
    }
    Write-Log "发现新版本：$local -> $latest，开始更新..."
    $cacheDir = Get-CacheDir
    if ($cacheDir) {
        Write-Log "清除旧缓存：$cacheDir"
        Remove-Item $cacheDir -Recurse -Force -ErrorAction SilentlyContinue
        if (Test-Path $cacheDir) { Write-Log '部分文件被占用未能删除，将尝试覆盖安装。' }
    }
    Write-Log '正在下载安装最新版本（可能需要几分钟）...'
    $npx = Get-NpxExe
    if (-not $npx) { $npx = 'npx' }
    & $npx --prefer-online $PkgName --version 2>$null
    if ($LASTEXITCODE -eq 0) { Write-Log "更新完成（$latest）。可以点击「启动服务」了。" }
    else { Write-Log '预取未完全成功；下次「启动服务」时 npx 会自动安装最新版。' }
    $script:latest = $latest
    Refresh-Labels
}

# ================= 托盘 / 退出 =================

$script:RealExit = $false

function Show-Launcher {
    Update-UI {
        $form.ShowInTaskbar = $true
        if ($form.WindowState -eq 'Minimized') { $form.WindowState = 'Normal' }
        $form.Show()
        $form.BringToFront()
        $form.Activate()
        # 托盘图标保持常驻（启动即在托盘，恢复窗口也不隐藏）
    }
}

function Exit-Launcher {
    Write-Dbg 'Exit-Launcher 被调用（按钮或托盘「退出」）'
    $script:RealExit = $true
    Write-Log '正在关闭服务并退出启动器...'
    Kill-Service | Out-Null
    Update-UI { $form.Close() }
}

# ================= 事件绑定 =================

$btnStart.Add_Click({
    Set-Busy $true
    Start-Async { try { Start-DshService } finally { Set-Busy $false } }
})
$btnStop.Add_Click({
    Set-Busy $true
    Start-Async { try { Stop-DshService } finally { Set-Busy $false } }
})
$btnUpdate.Add_Click({
    Set-Busy $true
    Start-Async { try { Update-Dsh } finally { Set-Busy $false } }
})
$btnOpen.Add_Click({
    Open-AppWindow
    Write-Log '已打开应用窗口。'
})
# 退出按钮：先关服务，再退出
$btnExit.Add_Click({ Exit-Launcher })

$form.Add_Shown({
    Write-Log '启动器已就绪。正在检查服务状态与版本更新...'
    Refresh-Status
    Refresh-Labels
    Start-Async {
        $script:latest = Get-LatestVersion
        Refresh-Labels
        if ($script:latest) {
            Write-Log "最新版本：$($script:latest)"
            if (Test-NeedUpdate $script:local $script:latest) { Write-Log '发现新版本！点击「检查/更新」可升级。' }
            else { Write-Log '已是最新版本。' }
        } else {
            Write-Log '无法获取最新版本（可能离线或 npm 不可用）。'
        }
        Write-Log '就绪。可使用下方按钮操作。'
    }
})

# 点「X」/ Alt+F4 都不退出：一律取消关闭并最小化到系统托盘（只有托盘「退出」才真正退出）
# 注意：FormClosing 事件本就在 UI 线程触发，必须【同步】直接操作控件与托盘图标，
# 不要用 Update-UI 异步包装——否则 Hide 与 notifyIcon.Visible 的时序不确定，会让托盘图标在叉掉后消失。
# 整个处理逻辑包在 try/catch 中：即使某一步异常，也要保证 Cancel=$true（不退出）与托盘图标显示。
# 每步写诊断日志，异常时能直接在 %TEMP%\dsh-launcher-debug.log 里看到具体是哪一步。
$form.Add_FormClosing({
    param($sender, $e)
    Write-Dbg "FormClosing 触发：RealExit=$script:RealExit CloseReason=$($e.CloseReason)"
    if (-not $script:RealExit) {
        try {
            $e.Cancel = $true
            Write-Dbg '已取消关闭 → 最小化到托盘'
            if ($script:notifyIcon) {
                $script:notifyIcon.Visible = $true
                Write-Dbg '托盘图标已设置为可见'
                try { $script:notifyIcon.ShowBalloonTip(3000, 'DeepSeek Harness 启动器', '已最小化到系统托盘。右键图标可「退出」（会一并关闭服务）。', 'Info') } catch { Write-Dbg "气泡提示异常：$($_.Exception.Message)" }
            } else {
                Write-Dbg '警告：notifyIcon 为空！'
            }
            $form.Hide()
            $form.ShowInTaskbar = $false
            Write-Dbg '窗口已隐藏，进程保持存活'
        } catch {
            Write-Dbg "FormClosing 异常：$($_.Exception.Message)"
            try { $e.Cancel = $true } catch { }
        }
    } else {
        Write-Dbg 'RealExit=true，允许窗口真正关闭'
    }
})

# 烟雾测试：DSH_SMOKE=1 时 3 秒后自动关闭
if ($env:DSH_SMOKE -eq '1') {
    $smokeTimer = New-Object System.Windows.Forms.Timer
    $smokeTimer.Interval = 3000
    $smokeTimer.Add_Tick({ $form.Close() })
    $smokeTimer.Start()
}

# 系统托盘图标
$script:notifyIcon = New-Object System.Windows.Forms.NotifyIcon
if ($appIcon) { $script:notifyIcon.Icon = $appIcon }
$script:notifyIcon.Text = 'DeepSeek Harness 启动器'
# 启动即常驻托盘（用户需求：不必等叉掉窗口才出现）；叉掉窗口时额外弹气泡提示
$script:notifyIcon.Visible = $true

$ctxMenu = New-Object System.Windows.Forms.ContextMenuStrip
$ctxShow = $ctxMenu.Items.Add('显示窗口')
$ctxExit = $ctxMenu.Items.Add('退出')
$script:notifyIcon.ContextMenuStrip = $ctxMenu

$ctxShow.Add_Click({ Show-Launcher })
$ctxExit.Add_Click({ Exit-Launcher })
# 单击托盘图标（左键）即显示窗口；右键仍走右键菜单（ContextMenuStrip 自动接管）
$script:notifyIcon.Add_MouseClick({
    param($sender, $e)
    if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) { Show-Launcher }
})

# 状态轮询：刷新窗口状态与托盘提示
$statusTimer = New-Object System.Windows.Forms.Timer
$statusTimer.Interval = 5000
$statusTimer.Add_Tick({
    Refresh-Status
    Update-UI {
        if ($script:notifyIcon) {
            $p = Get-ListenerPid $Port
            if ($p) { $script:notifyIcon.Text = "DeepSeek Harness 启动器`n● 服务运行中 (PID $p)" }
            else { $script:notifyIcon.Text = "DeepSeek Harness 启动器`n○ 服务未运行" }
        }
    }
})
$statusTimer.Start()

$form.Controls.AddRange(@($pnlAccent, $pnlDivider, $lblTitle, $lblStatus, $lblVersion, $lblAddr, $flowBtns, $lblLogTitle, $logBox, $lblFooter))
foreach ($b in @($btnStart, $btnStop, $btnUpdate, $btnOpen, $btnExit)) { $flowBtns.Controls.Add($b) }

# ============================================================
#  消息循环：必须用 Application.Run，不能用 ShowDialog！
#  ShowDialog 是模态对话框——窗体在 FormClosing 里被取消关闭
#  并 Hide 后，部分 .NET 版本仍会让对话框循环退出，导致
#  finally 释放托盘图标、整个 PowerShell 进程结束（症状：
#  窗口/托盘全消失、服务还在）。Application.Run 只在窗体
#  真正关闭时（RealExit 路径）才结束循环，Hide 不影响它。
# ============================================================
try { [System.Windows.Forms.Application]::Run($form) }
catch {
    Write-Dbg "Application.Run 异常：$($_.Exception.ToString())"
    [System.Windows.Forms.MessageBox]::Show($_.Exception.ToString(), '启动器错误')
}
finally {
    Write-Dbg '消息循环结束，脚本即将退出（若你只是点了 X 却看到这条，说明进程被异常/关闭拖垮了）'
    try { if ($script:notifyIcon) { $script:notifyIcon.Visible = $false; $script:notifyIcon.Dispose() } } catch { }
}

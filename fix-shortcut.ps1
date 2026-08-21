# ============================================================
#  fix-shortcut.ps1 - Rebuild the desktop shortcut with -STA
#  ------------------------------------------------------------
#  Run via fix-shortcut.bat (double-click it), or manually:
#    powershell -NoProfile -ExecutionPolicy Bypass -STA -File fix-shortcut.ps1
#  Result is also written to %TEMP%\dsh-fix-shortcut.log so a
#  failure is never silent.
# ============================================================

$ErrorActionPreference = 'Continue'

$log = Join-Path $env:TEMP 'dsh-fix-shortcut.log'
try { Remove-Item -LiteralPath $log -ErrorAction SilentlyContinue } catch { }
function W([string]$m) {
    try { Add-Content -LiteralPath $log -Value ((Get-Date -Format 'HH:mm:ss') + '  ' + $m) -Encoding utf8 } catch { }
    Write-Host $m
}

# "Qidongqi" (launcher) built from char codes -> pure ASCII source
$zh = [string][char]0x542F + [string][char]0x52A8 + [string][char]0x5668   # 启动器
# 脚本所在目录：三重兜底（部分启动方式下 $PSScriptRoot 为空，如右键"使用 PowerShell 运行"）
$scriptDir = $PSScriptRoot
if (-not $scriptDir -and $MyInvocation.MyCommand.Path) {
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}
if (-not $scriptDir) { $scriptDir = (Get-Location).Path }
$lnkName   = 'DeepSeek Harness ' + $zh + '.lnk'
$lnkPath   = Join-Path ([Environment]::GetFolderPath('Desktop')) $lnkName

# 目标：直接指向 powershell.exe（Windows Terminal 由启动器脚本内部自行隐藏）
$psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$target = Join-Path $scriptDir 'dsh-launcher.ps1'
$icon   = Join-Path $scriptDir 'dsh-red.ico'

W "scriptDir = $scriptDir"
W "target    = $target"
W "lnkPath   = $lnkPath"

# 安全闸：脚本目录/目标文件/图标任一缺失就中止，绝不覆盖现有快捷方式
if (-not $scriptDir -or -not (Test-Path -LiteralPath $target) -or -not (Test-Path -LiteralPath $icon)) {
    W 'ERROR: launcher script or icon not found next to fix-shortcut.ps1.'
    W "  target = $target"
    W 'Nothing was changed. Press any key to close...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

try {
    $ws  = New-Object -ComObject WScript.Shell
    W ("psExe = " + $psExe)   # 诊断：确认 TargetPath 用的路径值
    # 写入临时文件再移动：绕开 WScript.Shell 对已存在/刚删除 lnk 的 TargetPath 写入不稳定问题
    $tmpLnk = Join-Path $env:TEMP $lnkName
    Remove-Item -LiteralPath $tmpLnk, $lnkPath -Force -ErrorAction SilentlyContinue
    $lnk = $ws.CreateShortcut($tmpLnk)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $target + '"'
    $lnk.IconLocation     = $icon + ',0'
    $lnk.WorkingDirectory = $scriptDir
    $lnk.Description      = 'DeepSeek Harness launcher'
    $lnk.Save()
    Move-Item -LiteralPath $tmpLnk -Destination $lnkPath -Force
    # 写后自检：重新读取并打印实际写入的目标与参数
    $chk = $ws.CreateShortcut($lnkPath)
    W ("verify TargetPath = " + $chk.TargetPath)
    W ("verify Arguments  = " + $chk.Arguments)
    if ([string]::IsNullOrWhiteSpace([string]$chk.TargetPath)) {
        W 'WARNING: TargetPath 为空 —— WScript.Shell 写入失败，请改用手动方式：'
        W '  右键 dsh-launcher.bat → 发送到 → 桌面快捷方式（再右键重命名/改图标）'
        W 'Press any key to close...'
        $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        exit 1
    }
    W 'OK - shortcut rebuilt.'
} catch {
    W ('ERROR: ' + $_.Exception.Message)
    W 'Press any key to close...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

W ''
W 'Now test: open the shortcut -> start service -> click X.'
W 'The wine-red tray icon should appear with a balloon tip.'
W 'If it still fails, send me: %TEMP%\dsh-launcher-debug.log'
W ''
W 'Press any key to close...'
$null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')

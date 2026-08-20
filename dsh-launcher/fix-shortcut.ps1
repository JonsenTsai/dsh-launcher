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
$scriptDir = $PSScriptRoot   # 脚本所在目录，自动适配任何安装位置
$lnkName   = 'DeepSeek Harness ' + $zh + '.lnk'
$lnkPath   = Join-Path ([Environment]::GetFolderPath('Desktop')) $lnkName

$psExe  = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
$target = Join-Path $scriptDir 'dsh-launcher.ps1'
$icon   = Join-Path $scriptDir 'dsh-red.ico'

W "scriptDir = $scriptDir"
W "target    = $target"
W "lnkPath   = $lnkPath"

if (-not (Test-Path -LiteralPath $target)) {
    W 'ERROR: launcher script not found.'
    W 'Press any key to close...'
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
    exit 1
}

try {
    $ws  = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut($lnkPath)
    $lnk.TargetPath       = $psExe
    $lnk.Arguments        = '-NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "' + $target + '"'
    $lnk.IconLocation     = $icon + ',0'
    $lnk.WorkingDirectory = $scriptDir
    $lnk.Description      = 'DeepSeek Harness launcher (STA mode)'
    $lnk.Save()
    W 'OK - shortcut rebuilt with -STA.'
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

@echo off
rem ============================================================
rem  dsh-launcher.bat - one-click launcher entry.
rem  PowerShell console / Windows Terminal window is hidden
rem  automatically by dsh-launcher.ps1 (Hide-ConsoleWindow).
rem ============================================================
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0dsh-launcher.ps1"
endlocal

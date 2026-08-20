@echo off
setlocal
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0dsh-launcher.ps1"
endlocal

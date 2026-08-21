@echo off
rem ============================================================
rem  fix-shortcut.bat - one-click rebuild of the launcher
rem  desktop shortcut with -STA (fixes missing tray icon).
rem  Double-click this file. No admin rights needed.
rem ============================================================
setlocal
powershell -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0fix-shortcut.ps1"
endlocal

@echo off
setlocal
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0context-menu.ps1" -Action Remove
if errorlevel 1 pause

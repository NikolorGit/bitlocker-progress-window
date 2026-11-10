@echo off
rem Opens the BitLocker progress window. Windows asks for admin once (needed to read the status).
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0BitLockerProgress.ps1"

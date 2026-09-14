@echo off
rem Kingsway Desk administrator command. Runs kdesk.ps1 next to this file.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kdesk.ps1" %*

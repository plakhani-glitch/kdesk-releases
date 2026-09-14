@echo off
rem Kingsway Desk administrator command. The only entry point: launches the
rem implementation with the execution policy bypassed, so it works on a PC whose
rem PowerShell policy is the default Restricted (a bare .ps1 would be refused).
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0kdesk-impl.ps1" %*

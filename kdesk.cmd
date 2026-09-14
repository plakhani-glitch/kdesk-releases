@echo off
setlocal
rem Kingsway Desk administrator command - the ONLY entry point.
rem Execution policy (default Restricted, or one forced by Group Policy that even
rem -ExecutionPolicy Bypass cannot override) gates .ps1 FILES. It never gates a
rem script block built from text, so the implementation is read with Get-Content
rem and invoked as a script block. Arguments travel through KDESK_ARGS, are
rem re-split with quotes honoured ("John Smith" stays one argument), then
rem re-quoted so -Pin / -User / -Json still bind as named parameters.
set "KDESK_IMPL=%~dp0kdesk-impl.ps1"
set "KDESK_ARGS=%*"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$a = @([regex]::Matches([string]$env:KDESK_ARGS, '\x22([^\x22]*)\x22|(\S+)') | ForEach-Object { if ($_.Groups[1].Success) { $_.Groups[1].Value } else { $_.Value } }); $sb = [scriptblock]::Create((Get-Content -Raw -LiteralPath $env:KDESK_IMPL)); $q = @($a | ForEach-Object { if ($_ -match '^-[A-Za-z][A-Za-z0-9]*$') { $_ } else { [string][char]39 + $_.Replace([string][char]39, [string][char]39 + [char]39) + [char]39 } }); Invoke-Expression ('& $sb ' + ($q -join ' ')); exit $LASTEXITCODE"
endlocal

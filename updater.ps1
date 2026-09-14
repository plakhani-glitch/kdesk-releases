# Kingsway Desk auto-updater. Runs as SYSTEM from the hidden Task Scheduler task
# KingswayDeskUpdater: when an agent raises the Application-log event
# KingswayDesk/100 (Ktools told it a new release is out), 3 min after boot, and
# once a day as a safety net. Compares the
# published zip's SHA-256 with the installed one; when they differ it downloads,
# verifies, swaps C:\Program Files\KingswayDesk\app, refreshes the kdesk scripts
# and the agent task, and lets the Scheduler restart the agents in every
# session. Nobody touches the PC. Reports to Kingsway only when it changes
# something or fails; a local log is kept in %ProgramData%\KingswayDesk\updater.log.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
try { $wp = [Net.WebRequest]::DefaultWebProxy; if ($wp) { $null = $wp.GetProxy([Uri]'https://github.com/') } } catch { [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy }

$Repo    = 'plakhani-glitch/kdesk-releases'
$Base    = "https://github.com/$Repo/releases/latest/download"
$Asset   = 'KingswayDesk-win-x64.zip'
$App     = Join-Path $env:ProgramFiles 'KingswayDesk'
$Data    = Join-Path $env:ProgramData 'KingswayDesk'
$Log     = Join-Path $Data 'updater.log'
$DiagUrl = 'https://us-central1-kingsway-internal-tools.cloudfunctions.net/desktopDiag'
$Lines   = New-Object System.Collections.Generic.List[string]

function L([string]$t) {
  $line = '{0} {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $t
  $Lines.Add($line) | Out-Null
  try { Add-Content -LiteralPath $Log -Value $line } catch {}
}
function Invoke-Native([string]$exe, [string[]]$argv) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  return @{ Code = $code; Out = @($out | ForEach-Object { "$_" }) }
}
function Send-Diag([string]$level, [string]$message) {
  try {
    $body = @{ kind = 'install'; level = $level; stage = 'auto-update'; message = $message; detail = ($Lines -join "`n")
               host = $env:COMPUTERNAME; user = "$env:USERNAME (updater)"; machine = $true
               os = ('{0} | PS {1}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion) }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5))
    Invoke-RestMethod -Method POST -Uri $DiagUrl -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 20 | Out-Null
  } catch {}
}

New-Item -ItemType Directory -Force -Path $Data | Out-Null
try { $lf = Get-Item -LiteralPath $Log -ErrorAction SilentlyContinue; if ($lf -and $lf.Length -gt 1MB) { Move-Item -LiteralPath $Log -Destination "$Log.1" -Force } } catch {}

try {
  $want = ((Invoke-RestMethod -Uri "$Base/$Asset.sha256" -TimeoutSec 60) -split '\s+')[0].ToLower()
  if ($want.Length -ne 64) { throw "Published checksum looks wrong: '$want'" }
  $haveFile = Join-Path $Data 'installed.sha256'
  $have = if (Test-Path -LiteralPath $haveFile) { ((Get-Content -LiteralPath $haveFile -Raw) -split '\s+')[0].ToLower() } else { '' }
  if ($want -eq $have) { L "up to date ($($want.Substring(0, 12)))"; exit 0 }
  L "update available: installed '$have' -> published '$want'"

  # 1. download + verify
  $tmp = Join-Path $Data 'tmp'
  if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue }
  New-Item -ItemType Directory -Force -Path $tmp | Out-Null
  $zip = Join-Path $tmp $Asset
  Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Asset" -OutFile $zip
  $got = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
  if ($got -ne $want) { throw "Download corrupted: SHA-256 $got, expected $want" }
  L ('downloaded {0:N1} MB, checksum ok' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

  # 2. unpack next to the live app, fix permissions (a move keeps the source ACL)
  $new = Join-Path $App 'app.new'
  if (Test-Path -LiteralPath $new) { Remove-Item -LiteralPath $new -Recurse -Force }
  $x = Join-Path $tmp 'x'
  Expand-Archive -LiteralPath $zip -DestinationPath $x -Force
  $exe = Get-ChildItem -LiteralPath $x -Filter 'KingswayDesk.exe' -Recurse | Select-Object -First 1
  if (-not $exe) { throw 'KingswayDesk.exe not found in the download' }
  Move-Item -LiteralPath $exe.Directory.FullName -Destination $new
  $r = Invoke-Native 'icacls.exe' @($new, '/reset', '/T', '/C', '/Q'); if ($r.Code -ne 0) { L ("icacls: {0}" -f ($r.Out -join ' ')) }

  # 3. scripts (this file included; it is already in memory)
  foreach ($f in 'kdesk-impl.ps1', 'kdesk.cmd', 'updater.ps1') {
    try { Invoke-WebRequest -UseBasicParsing -Uri "$Base/$f" -OutFile (Join-Path $App $f); L "refreshed $f" } catch { L "could not refresh ${f}: $($_.Exception.Message)" }
  }

  # 4. stop every session's agent, swap folders
  $procs = @(Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue)
  if ($procs.Count) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; L "stopped $($procs.Count) agent process(es)" }
  $deadline = (Get-Date).AddSeconds(20)
  while ((Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
  $live = Join-Path $App 'app'; $old = Join-Path $App 'app.old'
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue }
  $swapped = $false
  for ($i = 0; $i -lt 15 -and -not $swapped; $i++) {
    try { if (Test-Path -LiteralPath $live) { Rename-Item -LiteralPath $live -NewName 'app.old' -Force }; Rename-Item -LiteralPath $new -NewName 'app' -Force; $swapped = $true }
    catch { Start-Sleep -Seconds 2 }
  }
  if (-not $swapped) { throw 'Could not replace the app folder (files still locked)' }
  Set-Content -LiteralPath $haveFile -Value "$want  $Asset" -Encoding ASCII
  L 'app folder swapped'

  # 5. agent task: re-register from the template the new build ships, so a
  #    changed task definition travels with the update
  $tpl = Join-Path $App 'app\resources\task-machine.xml'
  if (Test-Path -LiteralPath $tpl) {
    $exePath = Join-Path $App 'app\KingswayDesk.exe'
    $esc = { param($s) $s.Replace('&', '&amp;').Replace('<', '&lt;').Replace('>', '&gt;') }
    $xml = (Get-Content -LiteralPath $tpl -Raw).Replace('__EXE__', (& $esc $exePath)).Replace('__APPDIR__', (& $esc (Split-Path $exePath -Parent)))
    $tx = Join-Path $tmp 'KingswayDesk.xml'
    [IO.File]::WriteAllText($tx, $xml, [Text.Encoding]::Unicode)
    $r = Invoke-Native 'schtasks.exe' @('/Create', '/F', '/TN', 'KingswayDesk', '/XML', $tx)
    L ("agent task re-registered: exit {0} {1}" -f $r.Code, (($r.Out | Select-Object -First 2) -join ' '))
  }

  # 6. bring agents back: the Scheduler restarts killed instances (RestartOnFailure)
  #    and unlock/logon triggers cover the rest; /Run kicks the console session now
  $r = Invoke-Native 'schtasks.exe' @('/Run', '/TN', 'KingswayDesk'); L ("schtasks /Run: exit {0}" -f $r.Code)
  Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
  L "UPDATED to $($want.Substring(0, 12))"
  Send-Diag 'info' "Auto-updated to zip $($want.Substring(0, 12))"
  exit 0
} catch {
  L "FAILED: $($_.Exception.Message)"
  Send-Diag 'error' "Auto-update failed: $($_.Exception.Message)"
  exit 1
}

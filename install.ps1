# Kingsway Desk for Windows - headless installer.
#
#   Run in PowerShell **as Administrator** (right-click PowerShell > Run as administrator):
#   irm https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1 | iex
#
# MACHINE-WIDE (Administrator PowerShell, the normal case): the app goes to
# C:\Program Files\KingswayDesk (standard users cannot touch it), the `kdesk`
# command onto the machine PATH, and ONE hidden Task Scheduler task with the
# Users group as principal is registered. Windows then starts one agent inside
# EVERY account's session at sign-in and after unlock, with no user action.
# Pair each Windows account to an employee from this same admin session:
#   kdesk assign <WindowsAccount> ABCD-1234   (code: Ktools > Drafting > Connect Desktop > Code for a team member)
# PER-USER (not elevated): installs for the current account only, into
# %LOCALAPPDATA%\KingswayDesk, with a logon task + 5-minute watchdog.
#
# Optional, set before running:
#   $env:KDESK_CODE    = 'ABCD-1234'   per-user install: pair this account without asking
#   $env:KDESK_VERSION = '0.4.0'       pin a release (default: latest)
#   $env:KDESK_SCOPE   = 'user'        force a per-user install even when elevated
#
# Nothing is visible to the person using the PC: no tray icon, no window, no
# Start-menu entry, no Startup-apps entry. Re-running updates in place and
# keeps every pairing.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo    = if ($env:KDESK_REPO) { $env:KDESK_REPO } else { 'plakhani-glitch/kdesk-releases' }
$Version = $env:KDESK_VERSION
$IsAdmin = try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }
$Machine = $IsAdmin -and ($env:KDESK_SCOPE -ne 'user')
$MachineDir = Join-Path $env:ProgramData 'KingswayDesk'
if ($Machine) {
  $Root  = Join-Path $env:ProgramFiles 'KingswayDesk'   # app + kdesk command (admin-owned)
} else {
  $Root  = Join-Path $env:LOCALAPPDATA 'KingswayDesk'
}
$UserRoot = Join-Path $env:LOCALAPPDATA 'KingswayDesk'     # this session's control.json / log
$AppDir  = Join-Path $Root 'app'
$Exe     = Join-Path $AppDir 'KingswayDesk.exe'
$Kdesk   = Join-Path $Root 'kdesk.ps1'
$Tmp     = Join-Path $env:TEMP ('kdesk-install-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$Asset   = 'KingswayDesk-win-x64.zip'
$Base    = if ($Version) { "https://github.com/$Repo/releases/download/v$Version" } else { "https://github.com/$Repo/releases/latest/download" }
$Raw     = "https://raw.githubusercontent.com/$Repo/main"

function Step([string]$t) { Write-Host ''; Write-Host "==> $t" -ForegroundColor Cyan }
function Ok([string]$t)   { Write-Host "    [ok] $t" -ForegroundColor Green }
function Warn([string]$t) { Write-Host "    [!!] $t" -ForegroundColor Yellow }
function Invoke-Native([string]$exe, [string[]]$argv) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  return @{ Code = $code; Out = @($out | ForEach-Object { "$_" }) }
}
function Get-LiveControl {
  $cf = Join-Path $UserRoot 'control.json'
  if (-not (Test-Path -LiteralPath $cf)) { return $null }
  try { $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json } catch { return $null }
  if (-not (Get-Process -Id $c.pid -ErrorAction SilentlyContinue)) { return $null }
  return $c
}
function Get-AgentStatus($c) {
  return Invoke-RestMethod -Method GET -Uri "http://127.0.0.1:$($c.port)/status" -Headers @{ Authorization = "Bearer $($c.secret)" } -TimeoutSec 30
}

Write-Host ''
Write-Host 'Kingsway Desk for Windows' -ForegroundColor White
if ($Machine) {
  Write-Host "Machine-wide headless install on $env:COMPUTERNAME (every account), run by $env:USERNAME"
} else {
  Write-Host "Headless install for the account $env:USERNAME only, on $env:COMPUTERNAME"
  if (-not $IsAdmin) { Warn 'Not running as Administrator. Only THIS account will be tracked. For every account on the PC, open PowerShell as Administrator and run the same line.' }
}
if (-not $Machine -and (Test-Path -LiteralPath (Join-Path $MachineDir 'machine.json'))) {
  throw 'A machine-wide install already exists on this PC. Run this as Administrator to update it (or kdesk uninstall as Administrator first).'
}
$arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
if ($arch -ne 'AMD64') { Warn "This build is x64; this PC reports $arch. It will run under emulation on Windows 11 ARM." }

Step "Downloading $Asset from github.com/$Repo"
New-Item -ItemType Directory -Force -Path $Tmp, $Root | Out-Null
$zip = Join-Path $Tmp $Asset
Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Asset" -OutFile $zip
Invoke-WebRequest -UseBasicParsing -Uri "$Base/$Asset.sha256" -OutFile "$zip.sha256"
$want = ((Get-Content -LiteralPath "$zip.sha256" -Raw) -split '\s+')[0].ToLower()
$have = (Get-FileHash -LiteralPath $zip -Algorithm SHA256).Hash.ToLower()
if ($want -ne $have) { throw "Download corrupted: SHA-256 mismatch (expected $want, got $have)" }
Ok ('{0:N1} MB, SHA-256 verified' -f ((Get-Item -LiteralPath $zip).Length / 1MB))

Step 'Stopping running agents (if any)'
foreach ($t in 'KingswayDesk', 'KingswayDeskWatchdog') { $null = Invoke-Native 'schtasks.exe' @('/Change', '/TN', $t, '/DISABLE') }
$procs = @(Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue)   # as admin this covers every session
if ($procs.Count) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 2; Ok "Stopped $($procs.Count) process(es)" } else { Ok 'Nothing running' }
if ($Machine) {
  # A previous per-user install of THIS account is superseded by the machine one.
  $old = Join-Path $env:LOCALAPPDATA 'KingswayDesk\app'
  if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Recurse -Force -ErrorAction SilentlyContinue; Ok 'Removed the old per-user copy for this account' }
  foreach ($n in @('electron.app.Kingsway Desk', 'Kingsway Desk', 'KingswayDesk')) { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n -ErrorAction SilentlyContinue }
}

Step "Installing to $AppDir"
$extract = Join-Path $Tmp 'x'
Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
$found = Get-ChildItem -LiteralPath $extract -Filter 'KingswayDesk.exe' -Recurse | Select-Object -First 1
if (-not $found) { throw 'KingswayDesk.exe not found inside the download.' }
for ($i = 0; $i -lt 5; $i++) {
  if (-not (Test-Path -LiteralPath $AppDir)) { break }
  try { Remove-Item -LiteralPath $AppDir -Recurse -Force; break } catch { Start-Sleep -Seconds 2 }
}
if (Test-Path -LiteralPath $AppDir) { throw "Could not replace $AppDir (a file is still in use). Sign out and in, then run the installer again." }
Move-Item -LiteralPath $found.Directory.FullName -Destination $AppDir
Get-ChildItem -LiteralPath $AppDir -Recurse -File | Unblock-File -ErrorAction SilentlyContinue
Ok 'Files in place'

Step 'Installing the kdesk command'
foreach ($f in 'kdesk.ps1', 'kdesk.cmd') { Invoke-WebRequest -UseBasicParsing -Uri "$Raw/$f" -OutFile (Join-Path $Root $f) }
Get-ChildItem -LiteralPath $Root -File | Unblock-File -ErrorAction SilentlyContinue
$scope = if ($Machine) { 'Machine' } else { 'User' }
$curPath = [Environment]::GetEnvironmentVariable('Path', $scope)
if (-not (@($curPath -split ';') -contains $Root)) {
  [Environment]::SetEnvironmentVariable('Path', ((@($curPath, $Root) | Where-Object { $_ }) -join ';'), $scope)
}
if (-not (@($env:Path -split ';') -contains $Root)) { $env:Path = "$env:Path;$Root" }
Ok "kdesk is on the $scope PATH (new terminals pick it up)"

if ($Machine) {
  Step 'Preparing the shared folder for per-account pairings'
  $assign = Join-Path $MachineDir 'assign'
  New-Item -ItemType Directory -Force -Path $assign | Out-Null
  # Users may list the folder; each pairing file gets its own read grant for its account only.
  $acl = Invoke-Native 'icacls.exe' @($assign, '/inheritance:r', '/grant:r', 'SYSTEM:(OI)(CI)F', '/grant:r', 'Administrators:(OI)(CI)F', '/grant:r', 'Users:(RX)')
  if ($acl.Code -ne 0) { Warn ("icacls: {0}" -f ($acl.Out -join ' ')) } else { Ok "$assign" }
}

Step $(if ($Machine) { 'Registering the machine-wide task (every account) and starting the agent here' } else { 'Registering the always-on tasks and starting the agent' })
$p = if ($Machine) { Start-Process -FilePath $Exe -ArgumentList '--machine' -PassThru -Wait } else { Start-Process -FilePath $Exe -PassThru -Wait }
if ($p.ExitCode -ne 0) {
  if ($Machine) { & $Kdesk log 30; throw "Task Scheduler refused the machine-wide task (installer exit $($p.ExitCode)). See the log above." }
  Warn "Installer step exited with code $($p.ExitCode) (Task Scheduler refused; Startup fallback used). Details: kdesk log"
}
$deadline = (Get-Date).AddSeconds(45); $live = $null
while ((Get-Date) -lt $deadline) { $live = Get-LiveControl; if ($live) { break }; Start-Sleep -Milliseconds 700 }
if (-not $live) {
  Warn 'The agent did not report in within 45 s. Last log lines:'
  & $Kdesk log 40
  throw 'Install incomplete: the agent is not running.'
}
Ok "Agent v$($live.version) running in this session (pid $($live.pid))"
$taskNames = if ($Machine) { @('KingswayDesk') } else { @('KingswayDesk', 'KingswayDeskWatchdog') }
foreach ($t in $taskNames) {
  $r = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $t, '/FO', 'CSV', '/NH')
  if ($r.Code -eq 0) {
    $line = $r.Out | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    $cols = "$line" -split '","'
    $state = if ($cols.Count -ge 3) { $cols[2].Trim('"').Trim() } else { 'present' }
    Ok "Task $t : $state"
  } else { Warn "Task $t is missing; autostart is relying on the Startup fallback" }
}

if ($Machine) {
  Step 'Pairing the Windows accounts on this PC to employees'
  $existing = @(Get-ChildItem -LiteralPath (Join-Path $MachineDir 'assign') -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object { $_.BaseName })
  if ($existing.Count) { Ok ("Already assigned: {0} (kept)" -f ($existing -join ', ')) }
  Write-Host ''
  Write-Host '    For each employee account: in Ktools > Drafting > Connect Desktop use "Code for a team member",'
  Write-Host '    pick the employee, then enter their Windows account name and the code here. The pairing is'
  Write-Host '    applied the moment they sign in (or right away if they are signed in). Press Enter to finish;'
  Write-Host '    you can always do it later with:  kdesk assign <WindowsAccount> ABCD-1234'
  $accounts = @()
  try { $accounts = @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled } | ForEach-Object { $_.Name }) } catch {}
  if ($accounts.Count) { Write-Host ("    Accounts on this PC: {0}" -f ($accounts -join ', ')) }
  while ($true) {
    Write-Host ''
    $acct = Read-Host '    Windows account (Enter to finish)'
    if (-not $acct) { break }
    $code = Read-Host "    Pairing code for $acct"
    if (-not $code) { continue }
    & $Kdesk assign $acct $code
  }
} else {
  Step 'Connecting to Ktools'
  Start-Sleep -Milliseconds 800
  $st = Get-AgentStatus $live
  if ($st.paired) { Ok "Already connected as $($st.device.name) <$($st.device.email)>" }
  else {
    $code = $env:KDESK_CODE
    if (-not $code) {
      Write-Host ''
      Write-Host '    This account is not connected yet. Code: Ktools > Drafting > Connect Desktop (the employee'
      Write-Host '    generates their own, or the owner uses "Code for a team member"). Valid 10 minutes.'
      Write-Host '    Press Enter to skip and pair later with:  kdesk pair ABCD-1234'
      $code = Read-Host '    Pairing code'
    }
    if ($code) { & $Kdesk pair $code } else { Warn 'Not connected yet. Nothing is recorded until it is paired.' }
  }
}

Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host '  Visible to employees    : nothing (no tray icon, window, Start-menu or Startup entry)'
if ($Machine) {
  Write-Host '  Covers                  : every account on this PC; starts at each sign-in and after unlock, restarts if killed'
  Write-Host '  Manage from PowerShell  : kdesk users | assign | status -User <acct> | today -User <acct> | pause | log | update | uninstall'
} else {
  Write-Host '  Covers                  : this account only; starts at sign-in, brought back within 5 minutes if killed'
  Write-Host '  Manage from PowerShell  : kdesk status | today | pause | resume | sync | log | update | uninstall'
}
Write-Host '  Admin commands ask for the owner PIN (set in Ktools > Drafting > Connect Desktop).'

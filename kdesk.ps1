#Requires -Version 5.1
<#
.SYNOPSIS
  Kingsway Desk - administrator command (Windows).

.DESCRIPTION
  The agent has no tray icon and no window. This command is the only way to see
  or change it. It talks to the running agent over a local-only channel; every
  command beyond status / pair / start asks for the owner's 6-digit PIN, which
  Kingsway (Ktools) verifies server-side, rate-limits, logs and emails.

  kdesk status                 is it running, connected as who, last sample, pending uploads
  kdesk pair ABCD-1234         connect this PC (code from Ktools > Drafting > Connect Desktop)
  kdesk today            PIN   what is being tracked right now + hours today by app
  kdesk pause | resume   PIN   stop / restart tracking (stays paused until resumed)
  kdesk sync             PIN   upload pending activity now
  kdesk titles on|off    PIN   record window titles (needed to match work to jobs)
  kdesk shots on|off     PIN   screenshots for the AI work summary
  kdesk exclude "A, B"   PIN   apps that are never recorded
  kdesk disconnect       PIN   forget the pairing (agent keeps running, unpaired)
  kdesk start                  start the agent if it is not running
  kdesk restart                kill the agent and start it again
  kdesk log [lines]            tail the agent log
  kdesk update                 install the latest release from GitHub (keeps the pairing)
  kdesk uninstall        PIN   remove the agent, its tasks, its data and this command

  Add -Pin 123456 to skip the prompt, -Json for machine-readable status.
#>
param(
  [Parameter(Position = 0)] [string] $Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Rest,
  [string] $Pin,
  [switch] $Force,
  [switch] $Json
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Rest) { $Rest = @() }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

$Root        = Join-Path $env:LOCALAPPDATA 'KingswayDesk'
$AppDir      = Join-Path $Root 'app'
$Exe         = Join-Path $AppDir 'KingswayDesk.exe'
$ControlFile = Join-Path $Root 'control.json'
$LogFile     = Join-Path $Root 'logs\desk.log'
$TaskName    = 'KingswayDesk'
$Watchdog    = 'KingswayDeskWatchdog'
$DistRepo    = if ($env:KDESK_REPO) { $env:KDESK_REPO } else { 'plakhani-glitch/kdesk-releases' }
$RawBase     = "https://raw.githubusercontent.com/$DistRepo/main"

# ---- output helpers ----
function Write-Head([string]$t) { Write-Host ''; Write-Host $t -ForegroundColor Cyan }
function Write-Row([string]$k, $v) { Write-Host ('  {0,-16} {1}' -f $k, $v) }
function Write-Ok([string]$t)   { Write-Host "  [ok] $t" -ForegroundColor Green }
function Write-Note([string]$t) { Write-Host "  [!!] $t" -ForegroundColor Yellow }
function Write-Bad([string]$t)  { Write-Host "  [x]  $t" -ForegroundColor Red }

function Fmt-Dur($sec) {
  $sec = [int64]$sec
  if ($sec -lt 60) { return "$sec s" }
  if ($sec -lt 3600) { return ('{0} min' -f [math]::Floor($sec / 60)) }
  if ($sec -lt 86400) { return ('{0}h {1:00}m' -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60)) }
  return ('{0}d {1}h' -f [math]::Floor($sec / 86400), [math]::Floor(($sec % 86400) / 3600))
}
function Fmt-Hours($sec) {
  $sec = [int64]$sec
  return ('{0}h {1:00}m' -f [math]::Floor($sec / 3600), [math]::Floor(($sec % 3600) / 60))
}
function Fmt-Ago($ms) {
  if (-not $ms) { return 'never' }
  $t = [DateTimeOffset]::FromUnixTimeMilliseconds([int64]$ms).LocalDateTime
  $s = [int]((Get-Date) - $t).TotalSeconds
  if ($s -lt 60) { return "$s s ago" }
  if ($s -lt 3600) { return ('{0} min ago' -f [math]::Floor($s / 60)) }
  return $t.ToString('ddd HH:mm')
}

# Native commands: never let stderr chatter become a terminating error.
function Invoke-Native([string]$exe, [string[]]$argv) {
  $prev = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
  try { $out = & $exe @argv 2>&1; $code = $LASTEXITCODE } finally { $ErrorActionPreference = $prev }
  return @{ Code = $code; Out = @($out | ForEach-Object { "$_" }) }
}

# ---- agent control channel ----
function Get-AgentProcess { Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue }
function Get-Control {
  if (-not (Test-Path -LiteralPath $ControlFile)) { return $null }
  try { $c = Get-Content -LiteralPath $ControlFile -Raw | ConvertFrom-Json } catch { return $null }
  if (-not (Get-Process -Id $c.pid -ErrorAction SilentlyContinue)) { return $null }
  return $c
}
function Invoke-Agent([string]$Method, [string]$Path, $Body = $null) {
  $c = Get-Control
  if (-not $c) { throw 'The agent is not running (no live control channel). Try: kdesk start' }
  $headers = @{ Authorization = "Bearer $($c.secret)" }
  $uri = "http://127.0.0.1:$($c.port)$Path"
  try {
    if ($null -ne $Body) {
      $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Compress -Depth 6))
      return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 45
    }
    return Invoke-RestMethod -Method $Method -Uri $uri -Headers $headers -TimeoutSec 45
  } catch {
    $msg = $null
    if ($_.ErrorDetails -and $_.ErrorDetails.Message) { $msg = $_.ErrorDetails.Message }
    elseif ($_.Exception.Response) {
      try { $sr = New-Object IO.StreamReader($_.Exception.Response.GetResponseStream()); $msg = $sr.ReadToEnd() } catch {}
    }
    if ($msg) {
      $parsed = $null
      try { $parsed = $msg | ConvertFrom-Json } catch {}
      if ($parsed -and $parsed.error) {
        $m = "$($parsed.error)"
        if ($parsed.retryAfterMs -gt 0) { $m += (' (try again in {0})' -f (Fmt-Dur ([int]($parsed.retryAfterMs / 1000)))) }
        throw $m
      }
      throw $msg
    }
    throw
  }
}
function Read-Pin {
  if ($Pin) { return $Pin }
  $s = Read-Host -AsSecureString 'Administrator PIN (6 digits)'
  $b = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($s)
  try { return [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b) } finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b) }
}
function Invoke-Admin([string]$type, $value = $null) {
  $p = Read-Pin
  $body = @{ pin = "$p"; type = $type }
  if ($null -ne $value) { $body.value = $value }
  return Invoke-Agent 'POST' '/admin' $body
}
function Parse-OnOff {
  $v = if ($Rest.Count -ge 1) { "$($Rest[0])".ToLower() } else { '' }
  if ($v -in @('on', 'true', '1', 'yes')) { return $true }
  if ($v -in @('off', 'false', '0', 'no')) { return $false }
  throw "Say on or off, e.g. kdesk $Command on"
}
function Get-TaskState([string]$name) {
  $r = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $name, '/FO', 'CSV', '/NH')
  if ($r.Code -ne 0) { return 'MISSING' }
  $line = $r.Out | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
  if (-not $line) { return 'present' }
  $cols = $line -split '","'
  if ($cols.Count -ge 3) { return $cols[2].Trim('"').Trim() }
  return 'present'
}
function Wait-Agent([int]$seconds = 30) {
  $deadline = (Get-Date).AddSeconds($seconds)
  while ((Get-Date) -lt $deadline) {
    if (Get-Control) { Start-Sleep -Milliseconds 400; return }
    Start-Sleep -Milliseconds 600
  }
  throw "The agent did not come up within $seconds s. Look at: kdesk log"
}

# ---- commands ----
function Show-Tasks {
  if ($env:OS -ne 'Windows_NT') { return }
  Write-Row 'Logon task' (Get-TaskState $TaskName)
  Write-Row 'Watchdog task' (Get-TaskState $Watchdog)
}
function Show-Status {
  if (-not (Get-Control)) {
    if ($Json) { @{ running = $false } | ConvertTo-Json; return }
    Write-Head 'Kingsway Desk'
    Write-Bad 'Agent is NOT running'
    Show-Tasks
    Write-Row 'Installed' ($(if (Test-Path -LiteralPath $Exe) { $Exe } else { 'NO - run the installer again' }))
    Write-Host ''; Write-Host '  Start it with: kdesk start'
    return
  }
  $s = Invoke-Agent 'GET' '/status'
  if ($Json) { $s | ConvertTo-Json -Depth 6; return }
  Write-Head 'Kingsway Desk'
  Write-Row 'Agent' ('v{0}  pid {1}  up {2}' -f $s.version, $s.pid, (Fmt-Dur $s.uptimeSeconds))
  if ($s.paired) { Write-Row 'Connected as' ('{0} <{1}>' -f $s.device.name, $s.device.email) }
  else { Write-Note 'NOT connected. Run: kdesk pair ABCD-1234  (code from Ktools > Drafting > Connect Desktop)' }
  $state = if (-not $s.enabled) { 'PAUSED by administrator (kdesk resume)' }
    elseif ($s.systemPause -eq 'locked') { 'screen locked' }
    elseif ($s.systemPause -eq 'suspend') { 'asleep' }
    elseif ($s.idle) { 'away from keyboard' }
    elseif ($s.sampleState -eq 'ok') { 'tracking' }
    elseif ($s.sampleState -eq 'pending') { 'starting' }
    elseif ($s.sampleState -eq 'excluded') { 'excluded app in front' }
    else { "NOT sampling: $($s.sampleState) $($s.sampleMessage)" }
  Write-Row 'State' $state
  Write-Row 'Uploads' ('{0} pending, last sync {1}' -f $s.outboxCount, (Fmt-Ago $s.lastFlushAt))
  if ($s.lastError) { Write-Note "Sync issue: $($s.lastError)" }
  if ($s.shots.on) { Write-Row 'Screenshots' ('on, {0} sent, last {1}' -f $s.shots.sent, (Fmt-Ago $s.shots.lastAt)) } else { Write-Row 'Screenshots' 'off' }
  if ($s.shots.error) { Write-Note "Screenshot issue: $($s.shots.error)" }
  Write-Row 'Supervised' ($(if ($s.supervised) { 'yes (Task Scheduler)' } else { 'NO - started by hand. Run: kdesk restart' }))
  Show-Tasks
  Write-Row 'Log' $LogFile
}
function Show-Full($s) {
  if ($Json) { $s | ConvertTo-Json -Depth 6; return }
  $who = if ($s.device) { $s.device.name } else { 'not connected' }
  Write-Head "Kingsway Desk - $who"
  $badge = if (-not $s.enabled) { 'PAUSED' }
    elseif ($s.systemPause -eq 'locked') { 'Screen locked' }
    elseif ($s.systemPause -eq 'suspend') { 'Asleep' }
    elseif ($s.idle) { 'Away' }
    elseif ($s.permissionOk -eq $false) { 'No permission' }
    else { 'Tracking' }
  Write-Row 'State' $badge
  if ($s.current) { Write-Row 'Right now' ('{0} - {1} [{2}] for {3}' -f $s.current.app, $s.current.title, $s.current.category, (Fmt-Dur $s.current.seconds)) }
  elseif ($s.lastSample -and $s.lastSample.ok -eq $false) { Write-Row 'Right now' ('no sample: {0} {1}' -f $s.lastSample.reason, $s.lastSample.message) }
  Write-Row 'Today' (Fmt-Hours $s.today.seconds)
  foreach ($a in @($s.today.apps)) { Write-Host ('    {0,-30} {1}' -f $a.app, (Fmt-Hours $a.seconds)) }
  Write-Row 'Uploads' ('{0} pending, last sync {1}' -f $s.outboxCount, (Fmt-Ago $s.lastFlushAt))
  Write-Row 'Titles' ($(if ($s.settings.captureTitles) { 'on' } else { 'off' }))
  Write-Row 'Screenshots' ($(if ($s.settings.captureShots) { 'on, every {0}s, {1} sent' -f $s.shots.every, $s.shots.sent } else { 'off' }))
  Write-Row 'Excluded apps' (@($s.settings.excludedApps) -join ', ')
  Write-Row 'Sampling' ('every {0}s, away after {1}s idle, upload every {2}s' -f $s.settings.sampleSeconds, $s.settings.idleSeconds, $s.settings.flushSeconds)
}
function Do-Pair {
  $code = ($Rest -join '').Trim()
  if (-not $code) {
    Write-Host '  The employee signs in to Ktools > Drafting > Connect Desktop > Generate code (valid 10 min).'
    $code = Read-Host '  Pairing code'
  }
  $code = ($code -replace '[^A-Za-z0-9]', '').ToUpper()
  if ($code.Length -ne 8) { throw 'A pairing code is 8 letters/digits, e.g. ABCD-1234.' }
  $s = Invoke-Agent 'POST' '/pair' @{ code = $code }
  Write-Ok ('Connected as {0} <{1}>' -f $s.device.name, $s.device.email)
}
function Do-Start {
  if (Get-Control) { Write-Ok 'Already running'; return }
  if (-not (Test-Path -LiteralPath $Exe)) { throw "Not installed ($Exe missing). Run the installer again: kdesk update" }
  $r = Invoke-Native 'schtasks.exe' @('/Run', '/TN', $TaskName)
  if ($r.Code -ne 0) {
    Write-Note "Task Scheduler could not start it ($($r.Out -join ' ')). Re-registering the tasks..."
    # Unsupervised launch of the packaged exe = installer mode: rewrites the tasks, starts the supervised copy, exits.
    $p = Start-Process -FilePath $Exe -PassThru -Wait
    if ($p.ExitCode -ne 0) { Write-Note "installer step exit code $($p.ExitCode) - see kdesk log" }
  }
  Wait-Agent
  Write-Ok 'Running'
}
function Do-Restart {
  $procs = Get-AgentProcess
  if ($procs) { $procs | Stop-Process -Force -ErrorAction SilentlyContinue; Start-Sleep -Seconds 1; Write-Ok "Stopped $(@($procs).Count) process(es)" }
  Do-Start
}
function Do-Log {
  $n = 60
  if ($Rest.Count -ge 1 -and "$($Rest[0])" -match '^\d+$') { $n = [int]$Rest[0] }
  if (-not (Test-Path -LiteralPath $LogFile)) { Write-Note "No log yet at $LogFile"; return }
  Get-Content -LiteralPath $LogFile -Tail $n
}
function Do-Update {
  Write-Head "Updating from github.com/$DistRepo ..."
  $script = Invoke-RestMethod -Uri "$RawBase/install.ps1?nocache=$(Get-Random)" -TimeoutSec 60
  Invoke-Expression $script
}
function Do-Uninstall {
  Write-Head 'Uninstall Kingsway Desk'
  if (Get-Control) { $null = Invoke-Admin 'status'; Write-Ok 'PIN accepted' }
  elseif (-not $Force) { throw 'The agent is not running, so the PIN cannot be checked. Run kdesk start first, or add -Force.' }
  foreach ($t in @($TaskName, $Watchdog)) {
    $r = Invoke-Native 'schtasks.exe' @('/Delete', '/F', '/TN', $t)
    if ($r.Code -eq 0) { Write-Ok "Removed task $t" } else { Write-Note "Task ${t}: $($r.Out -join ' ')" }
  }
  Get-AgentProcess | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  foreach ($n in @('electron.app.Kingsway Desk', 'Kingsway Desk', 'KingswayDesk')) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n -ErrorAction SilentlyContinue
  }
  Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Kingsway Desk') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ControlFile -Force -ErrorAction SilentlyContinue
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($u) {
    $new = (@($u -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Root) }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  }
  Write-Ok 'Kingsway Desk removed from this PC. If the device is still listed in Ktools > Drafting > Connect Desktop, revoke it there.'
  # Delete the folder holding this very script after we exit.
  Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$Root`"" -WindowStyle Hidden
}
function Show-Help {
  $lines = @(Get-Content -LiteralPath $PSCommandPath)
  $start = ($lines | Select-String -SimpleMatch '.DESCRIPTION' | Select-Object -First 1).LineNumber
  $end = ($lines | Select-String -SimpleMatch '#>' | Select-Object -First 1).LineNumber
  Write-Host ''
  $lines[$start..($end - 2)] | ForEach-Object { Write-Host $_ }
}

try {
  switch ($Command.ToLower()) {
    'status'     { Show-Status }
    'pair'       { Do-Pair }
    'today'      { Show-Full (Invoke-Admin 'status') }
    'full'       { Show-Full (Invoke-Admin 'status') }
    'pause'      { $null = Invoke-Admin 'pause';  Write-Ok 'Tracking paused. It stays paused until: kdesk resume' }
    'resume'     { $null = Invoke-Admin 'resume'; Write-Ok 'Tracking resumed' }
    'sync'       { $s = Invoke-Admin 'sync';      Write-Ok ('Synced. {0} segment(s) still pending' -f $s.outboxCount) }
    'disconnect' { $null = Invoke-Admin 'disconnect'; Write-Ok 'Disconnected. The agent keeps running; connect it again with: kdesk pair ABCD-1234' }
    'titles'     { $on = Parse-OnOff; $null = Invoke-Admin 'set-titles' $on; Write-Ok ('Window titles {0}' -f $(if ($on) { 'on' } else { 'off' })) }
    'shots'      { $on = Parse-OnOff; $null = Invoke-Admin 'set-shots' $on;  Write-Ok ('Screenshots {0}' -f $(if ($on) { 'on' } else { 'off' })) }
    'exclude'    {
      $list = @((($Rest -join ' ') -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ })
      $s = Invoke-Admin 'set-excluded' (, $list)
      Write-Ok ('Excluded apps: {0}' -f (@($s.settings.excludedApps) -join ', '))
    }
    'start'      { Do-Start }
    'restart'    { Do-Restart }
    'log'        { Do-Log }
    'update'     { Do-Update }
    'uninstall'  { Do-Uninstall }
    default      { Show-Help }
  }
} catch {
  Write-Host ''
  Write-Bad $_.Exception.Message
  exit 1
}

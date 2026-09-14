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
  kdesk users                  every Windows account on this PC: agent running? connected as who?
  kdesk assign <WinUser> CODE  (admin) pair a Windows account to an employee BEFORE they sign in;
                               the code comes from Ktools > Drafting > Connect Desktop > Code for a team member
  kdesk assignments            (admin) list the pre-made pairings
  kdesk pair ABCD-1234         connect the agent running in THIS session (employee's own code)
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
  kdesk report                 send the full picture to Kingsway (task history, permissions, every
                               account's agent log) so problems can be diagnosed remotely
  kdesk update                 check GitHub for a newer release now (updates arrive by themselves when Kingsway publishes)
  kdesk uninstall        PIN   remove the agent, its tasks, its data and this command

  Add -User <WinUser> to aim status/today/pause/... at another signed-in account (admin).
  Add -Pin 123456 to skip the prompt, -Json for machine-readable status.

  Machine-wide install (installer run as Administrator): app in C:\Program Files\KingswayDesk,
  one hidden Task Scheduler task with the Users group as principal, so Windows starts one agent
  inside EVERY account's session at sign-in / unlock. Per-user install: this account only.
#>
param(
  [Parameter(Position = 0)] [string] $Command = 'help',
  [Parameter(Position = 1, ValueFromRemainingArguments = $true)] [string[]] $Rest,
  [string] $Pin,
  [string] $User,
  [switch] $Force,
  [switch] $Json
)

Set-StrictMode -Off
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
if (-not $Rest) { $Rest = @() }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}
# Broken system proxy => every web call (even to 127.0.0.1) dies with an
# "Invalid URI" error. If it cannot resolve a URL, go direct.
try {
  if ($env:KDESK_NOPROXY) { throw 'forced' }
  $wp = [Net.WebRequest]::DefaultWebProxy
  if ($wp) { $null = $wp.GetProxy([Uri]'https://github.com/'); $null = $wp.GetProxy([Uri]'http://127.0.0.1:1/') }
} catch { [Net.WebRequest]::DefaultWebProxy = New-Object Net.WebProxy }

# Where things live. MACHINE install: app under Program Files (admin-owned),
# shared data under ProgramData. Per-user runtime files (control.json, log,
# state) are always in the signed-in user's own profile, so -User <WinUser>
# simply points at another profile (needs admin rights to read it).
# ($env:ProgramData / ProgramFiles always exist on Windows; the fallbacks only let the script run in tests elsewhere.)
$MachineDir  = Join-Path $(if ($env:ProgramData) { $env:ProgramData } else { [IO.Path]::GetTempPath() }) 'KingswayDesk-ProgramData'
$MachineApp  = Join-Path $(if ($env:ProgramFiles) { $env:ProgramFiles } else { [IO.Path]::GetTempPath() }) 'KingswayDesk'
if ($env:ProgramData) { $MachineDir = Join-Path $env:ProgramData 'KingswayDesk' }
$IsMachine   = Test-Path -LiteralPath (Join-Path $MachineDir 'machine.json')
$ProfileRoot = if ($User) {
  $prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -and (Split-Path $_.LocalPath -Leaf) -ieq $User } | Select-Object -First 1
  if ($prof) { $prof.LocalPath } else { Join-Path (Split-Path $env:USERPROFILE -Parent) $User }
} else { $env:USERPROFILE }
$LocalAppData = if ($env:LOCALAPPDATA) { $env:LOCALAPPDATA } else { Join-Path $env:HOME '.kdesk' }
$Root        = if ($User) { Join-Path $ProfileRoot 'AppData\Local\KingswayDesk' } else { Join-Path $LocalAppData 'KingswayDesk' }
$AppDir      = if ($IsMachine) { Join-Path $MachineApp 'app' } else { Join-Path (Join-Path $LocalAppData 'KingswayDesk') 'app' }
$Exe         = Join-Path $AppDir 'KingswayDesk.exe'
$ControlFile = Join-Path $Root 'control.json'
$LogFile     = Join-Path $Root 'logs\desk.log'
$TaskName    = 'KingswayDesk'
$Watchdog    = 'KingswayDeskWatchdog'
$DistRepo    = if ($env:KDESK_REPO) { $env:KDESK_REPO } else { 'plakhani-glitch/kdesk-releases' }
$RawBase     = "https://raw.githubusercontent.com/$DistRepo/main"
$PairUrl     = 'https://us-central1-kingsway-internal-tools.cloudfunctions.net/desktopPair'
$IsAdmin     = try { ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator) } catch { $false }

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
function Get-AgentProcess {
  $all = @(Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue)
  if (-not $User -or -not $all.Count) { return $all }
  # Only that account's instance (needs admin to see other users' processes).
  $owned = @()
  foreach ($p in $all) {
    try { $o = (Get-CimInstance Win32_Process -Filter "ProcessId = $($p.Id)" | Invoke-CimMethod -MethodName GetOwner).User; if ($o -ieq $User) { $owned += $p } } catch {}
  }
  return $owned
}
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
  if (-not $IsMachine) { Write-Row 'Watchdog task' (Get-TaskState $Watchdog) }
}
function Require-Admin([string]$what) {
  if (-not $IsAdmin) { throw "$what needs an Administrator PowerShell (right-click PowerShell > Run as administrator)." }
}
# ---- machine-wide: pre-made pairings per Windows account ----
function Get-LocalAccounts {
  # Interactive accounts on this PC (local + any domain profiles that have signed in).
  $names = @()
  try { $names += @(Get-LocalUser -ErrorAction Stop | Where-Object { $_.Enabled } | ForEach-Object { $_.Name }) } catch {}
  try { $names += @(Get-CimInstance Win32_UserProfile -ErrorAction Stop | Where-Object { -not $_.Special -and $_.LocalPath } | ForEach-Object { Split-Path $_.LocalPath -Leaf }) } catch {}
  return @($names | Where-Object { $_ } | Sort-Object -Unique)
}
function Get-LoggedOnUsers {
  # Owner of each explorer.exe = each interactive session.
  $out = @()
  try {
    foreach ($p in @(Get-CimInstance Win32_Process -Filter "Name = 'explorer.exe'" -ErrorAction Stop)) {
      try { $o = ($p | Invoke-CimMethod -MethodName GetOwner).User; if ($o) { $out += $o } } catch {}
    }
  } catch {}
  return @($out | Sort-Object -Unique)
}
function Do-Assign {
  Require-Admin 'kdesk assign'
  if (-not $IsMachine) { throw 'assign is for the machine-wide install. Run the installer as Administrator first.' }
  $target = if ($Rest.Count -ge 1) { "$($Rest[0])" } else { Read-Host '  Windows account name (as shown at the sign-in screen)' }
  $code = if ($Rest.Count -ge 2) { ($Rest[1..($Rest.Count - 1)] -join '') } else { Read-Host "  Pairing code for $target (Ktools > Drafting > Connect Desktop > Code for a team member)" }
  $code = ($code -replace '[^A-Za-z0-9]', '').ToUpper()
  if (-not $target) { throw 'Which Windows account?' }
  if ($code.Length -ne 8) { throw 'A pairing code is 8 letters/digits, e.g. ABCD-1234.' }
  $known = Get-LocalAccounts
  if ($known.Count -and -not ($known -contains $target)) { Write-Note ("'{0}' is not a known account here (known: {1}). Continuing anyway." -f $target, ($known -join ', ')) }
  # Redeem the code now (single use, 10 min) so the token is ready when they sign in.
  $body = [Text.Encoding]::UTF8.GetBytes((@{ code = $code; deviceName = "$env:COMPUTERNAME ($target) (windows)"; platform = 'windows' } | ConvertTo-Json -Compress))
  try {
    $r = Invoke-RestMethod -Method POST -Uri $PairUrl -ContentType 'application/json; charset=utf-8' -Body $body -TimeoutSec 45
  } catch {
    $msg = if ($_.ErrorDetails -and $_.ErrorDetails.Message) { try { ($_.ErrorDetails.Message | ConvertFrom-Json).error } catch { $_.ErrorDetails.Message } } else { $_.Exception.Message }
    throw "Kingsway rejected the code: $msg"
  }
  if (-not $r.token) { throw 'Pairing failed (no token returned).' }
  $dir = Join-Path $MachineDir 'assign'
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  $file = Join-Path $dir "$target.json"
  $doc = @{ email = $r.email; name = $r.name; deviceId = $r.deviceId; token = $r.token; at = [int64]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds()); assignedBy = $env:USERNAME; windowsUser = $target }
  [IO.File]::WriteAllText($file, ($doc | ConvertTo-Json -Compress), (New-Object Text.UTF8Encoding $false))
  # Only that account (plus SYSTEM and Administrators) may read the token.
  $acl = Invoke-Native 'icacls.exe' @($file, '/inheritance:r', '/grant:r', 'SYSTEM:F', '/grant:r', 'Administrators:F', '/grant:r', "${target}:R")
  if ($acl.Code -ne 0) { Write-Note ("icacls: {0}" -f ($acl.Out -join ' ')) }
  Write-Ok ("{0} -> {1} <{2}> (device {3})" -f $target, $r.name, $r.email, $r.deviceId)
  # If that account is signed in right now, tell its agent to pick it up immediately.
  $their = Join-Path (Join-Path (Split-Path $env:USERPROFILE -Parent) $target) 'AppData\Local\KingswayDesk\control.json'
  $prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -and (Split-Path $_.LocalPath -Leaf) -ieq $target } | Select-Object -First 1
  if ($prof) { $their = Join-Path $prof.LocalPath 'AppData\Local\KingswayDesk\control.json' }
  if (Test-Path -LiteralPath $their) {
    try {
      $c = Get-Content -LiteralPath $their -Raw | ConvertFrom-Json
      if (Get-Process -Id $c.pid -ErrorAction SilentlyContinue) {
        $res = Invoke-RestMethod -Method POST -Uri "http://127.0.0.1:$($c.port)/adopt" -Headers @{ Authorization = "Bearer $($c.secret)" } -ContentType 'application/json' -Body '{}' -TimeoutSec 20
        Write-Ok ("Their agent is signed in now: {0}" -f $res.result)
      } else { Write-Host '  They are not signed in; the agent adopts it at their next sign-in.' }
    } catch { Write-Note "Could not reach their running agent ($($_.Exception.Message)); it adopts the pairing within 5 minutes or at next sign-in." }
  } else { Write-Host '  Applied at their next sign-in (or within 5 minutes if their agent is already running).' }
}
function Show-Assignments {
  Require-Admin 'kdesk assignments'
  $dir = Join-Path $MachineDir 'assign'
  if (-not (Test-Path -LiteralPath $dir)) { Write-Note 'No assignments yet. kdesk assign <WinUser> ABCD-1234'; return }
  Write-Head 'Pre-made pairings (Windows account -> employee)'
  foreach ($f in Get-ChildItem -LiteralPath $dir -Filter '*.json') {
    try { $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; Write-Row $f.BaseName ("{0} <{1}>  assigned {2} by {3}" -f $d.name, $d.email, (Fmt-Ago $d.at), $d.assignedBy) } catch { Write-Row $f.BaseName 'unreadable' }
  }
}
# Task Scheduler's verbose CSV: columns are positional (names are localized).
# 0 HostName, 1 TaskName, 2 Next Run Time, 3 Status, 4 Logon Mode, 5 Last Run Time, 6 Last Result
function Get-TaskLastRun([string]$name) {
  $r = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $name, '/V', '/FO', 'CSV', '/NH')
  if ($r.Code -ne 0) { return $null }
  $line = $r.Out | Where-Object { $_ -and $_.Trim() } | Select-Object -First 1
  if (-not $line) { return $null }
  $cols = ($line -split '","') | ForEach-Object { $_.Trim('"') }
  if ($cols.Count -lt 7) { return $null }
  return @{ Status = $cols[3]; LastRun = $cols[5]; LastResult = $cols[6] }
}
function Get-ProfilePaths {
  @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath } | ForEach-Object { $_.LocalPath })
}
function Send-Report {
  $parts = New-Object System.Collections.Generic.List[string]
  $add = { param($title, $text) $parts.Add("=== $title ===`n$text") | Out-Null }
  & $add 'env' ("host={0} user={1} admin={2} machine={3} ps={4} os={5}" -f $env:COMPUTERNAME, $env:USERNAME, $IsAdmin, $IsMachine, $PSVersionTable.PSVersion, [Environment]::OSVersion.VersionString)
  & $add 'logged on (explorer owners)' ((Get-LoggedOnUsers) -join ', ')
  & $add 'local accounts' ((Get-LocalAccounts) -join ', ')
  $q = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $TaskName, '/V', '/FO', 'LIST'); & $add "schtasks $TaskName (exit $($q.Code))" (($q.Out | Select-Object -First 60) -join "`n")
  $x = Invoke-Native 'schtasks.exe' @('/Query', '/TN', $TaskName, '/XML'); & $add 'task xml' (($x.Out -join "`n").Substring(0, [Math]::Min(3000, ($x.Out -join "`n").Length)))
  if (Test-Path -LiteralPath $Exe) { $a = Invoke-Native 'icacls.exe' @($Exe); & $add 'icacls exe' ($a.Out -join "`n") } else { & $add 'exe' "MISSING: $Exe" }
  foreach ($f in @((Join-Path $MachineDir 'machine.json'), (Join-Path $MachineDir 'installed.sha256'), (Join-Path $Root 'install.json'))) { if (Test-Path -LiteralPath $f) { & $add $f (Get-Content -LiteralPath $f -Raw) } }
  $uq = Invoke-Native 'schtasks.exe' @('/Query', '/TN', 'KingswayDeskUpdater', '/V', '/FO', 'LIST'); & $add "schtasks KingswayDeskUpdater (exit $($uq.Code))" (($uq.Out | Select-Object -First 40) -join "`n")
  $ul = Join-Path $MachineDir 'updater.log'; if (Test-Path -LiteralPath $ul) { & $add 'updater.log (tail)' (@(Get-Content -LiteralPath $ul -Tail 30) -join "`n") }
  $assignDir = Join-Path $MachineDir 'assign'
  if (Test-Path -LiteralPath $assignDir) {
    $rows = foreach ($f in Get-ChildItem -LiteralPath $assignDir -Filter '*.json') { try { $d = Get-Content -LiteralPath $f.FullName -Raw | ConvertFrom-Json; "{0} -> {1} (device {2}, {3})" -f $f.BaseName, $d.email, $d.deviceId, (Fmt-Ago $d.at) } catch { "$($f.BaseName): unreadable" } }
    & $add 'assignments' ($rows -join "`n")
    $a2 = Invoke-Native 'icacls.exe' @($assignDir, '/T'); & $add 'icacls assign' (($a2.Out | Select-Object -First 30) -join "`n")
  }
  foreach ($prof in Get-ProfilePaths) {
    $name = Split-Path $prof -Leaf
    $lf = Join-Path $prof 'AppData\Local\KingswayDesk\logs\desk.log'
    $cf = Join-Path $prof 'AppData\Local\KingswayDesk\control.json'
    $st = Join-Path $prof 'AppData\Roaming\Kingsway Desk\kdesk-state.json'
    $line = "log={0} control={1} state={2}" -f (Test-Path -LiteralPath $lf), (Test-Path -LiteralPath $cf), (Test-Path -LiteralPath $st)
    if (Test-Path -LiteralPath $cf) { try { $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json; $line += " pid=$($c.pid) alive=$([bool](Get-Process -Id $c.pid -ErrorAction SilentlyContinue)) v=$($c.version)" } catch {} }
    if (Test-Path -LiteralPath $st) { try { $d = (Get-Content -LiteralPath $st -Raw | ConvertFrom-Json).device; if ($d) { $line += " paired=$($d.email)" } else { $line += ' paired=no' } } catch {} }
    & $add "account $name" $line
    if (Test-Path -LiteralPath $lf) { try { & $add "log $name (tail)" (@(Get-Content -LiteralPath $lf -Tail 25) -join "`n") } catch {} }
  }
  $detail = ($parts -join "`n`n")
  if ($detail.Length -gt 29000) { $detail = $detail.Substring(0, 29000) + "`n[truncated]" }
  $body = @{ kind = 'kdesk'; level = 'info'; stage = 'report'; message = "kdesk report from $env:COMPUTERNAME by $env:USERNAME"; detail = $detail
             host = $env:COMPUTERNAME; user = $env:USERNAME; machine = [bool]$IsMachine
             os = ('{0} | PS {1} | admin={2}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $IsAdmin) }
  $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5))
  Invoke-RestMethod -Method POST -Uri 'https://us-central1-kingsway-internal-tools.cloudfunctions.net/desktopDiag' -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 30 | Out-Null
  Write-Ok ("Report sent ({0} KB). Kingsway can read it now." -f [math]::Round($detail.Length / 1024))
}
function Show-Users {
  Write-Head 'Windows accounts on this PC'
  $logged = Get-LoggedOnUsers
  $assignDir = Join-Path $MachineDir 'assign'
  foreach ($name in Get-LocalAccounts) {
    $line = ''
    $on = $logged -contains $name
    $prof = Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { $_.LocalPath -and (Split-Path $_.LocalPath -Leaf) -ieq $name } | Select-Object -First 1
    $cf = if ($prof) { Join-Path $prof.LocalPath 'AppData\Local\KingswayDesk\control.json' } else { $null }
    $agent = 'agent not running'
    if ($cf -and (Test-Path -LiteralPath $cf)) {
      try {
        $c = Get-Content -LiteralPath $cf -Raw | ConvertFrom-Json
        if (Get-Process -Id $c.pid -ErrorAction SilentlyContinue) {
          $st = Invoke-RestMethod -Method GET -Uri "http://127.0.0.1:$($c.port)/status" -Headers @{ Authorization = "Bearer $($c.secret)" } -TimeoutSec 10
          $agent = if ($st.paired) { "agent running, connected as $($st.device.name) <$($st.device.email)>, $($st.sampleState)" } else { 'agent running, NOT connected' }
        }
      } catch { $agent = "agent running, no access ($($_.Exception.Message))" }
    }
    $assigned = ''
    if (Test-Path -LiteralPath (Join-Path $assignDir "$name.json")) { try { $d = Get-Content -LiteralPath (Join-Path $assignDir "$name.json") -Raw | ConvertFrom-Json; $assigned = " | assigned -> $($d.email)" } catch {} }
    Write-Row $name (("{0} | {1}{2}" -f $(if ($on) { 'signed in' } else { 'signed out' }), $agent, $assigned))
  }
  $lr = Get-TaskLastRun $TaskName
  if ($lr) { Write-Row 'Agent task' ("{0}, last run {1}, result {2}" -f $lr.Status, $lr.LastRun, $lr.LastResult) }
  if ($IsMachine) {
    $ur = Get-TaskLastRun 'KingswayDeskUpdater'
    if ($ur) { Write-Row 'Updater task' ("{0}, last run {1}, result {2}" -f $ur.Status, $ur.LastRun, $ur.LastResult) } else { Write-Note 'Updater task MISSING: run the installer line once as Administrator' }
    $ul = Join-Path $MachineDir 'updater.log'
    if (Test-Path -LiteralPath $ul) { Write-Row 'Updater log' ((Get-Content -LiteralPath $ul -Tail 1) -join '') }
  }
  if (-not $IsAdmin) { Write-Note 'Run as Administrator to see other accounts'' agents.' }
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
  Write-Head ("Kingsway Desk - Windows account {0}" -f $(if ($s.user) { $s.user } elseif ($User) { $User } else { $env:USERNAME }))
  Write-Row 'Agent' ('v{0}  pid {1}  up {2}' -f $s.version, $s.pid, (Fmt-Dur $s.uptimeSeconds))
  Write-Row 'Install' ($(if ($s.machineInstall) { 'machine-wide (every account on this PC)' } else { 'this account only' }))
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
  if ($User) { throw "Start it from that account's own session (sign in as $User, or lock/unlock: the task starts it)." }
  $r = Invoke-Native 'schtasks.exe' @('/Run', '/TN', $TaskName)
  if ($r.Code -ne 0) {
    Write-Note "Task Scheduler could not start it ($($r.Out -join ' ')). Re-registering the task..."
    if ($IsMachine) { Require-Admin 'Re-registering the machine-wide task' }
    # Unsupervised launch of the packaged exe = installer mode: rewrites the tasks, starts the supervised copy, exits.
    $args = @(); if ($IsMachine) { $args = @('--machine') }
    $p = if ($args.Count) { Start-Process -FilePath $Exe -ArgumentList $args -PassThru -Wait } else { Start-Process -FilePath $Exe -PassThru -Wait }
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
  if ($IsMachine) {
    Require-Admin 'kdesk update (machine-wide install)'
    # Same code the SYSTEM task runs every 30 minutes, just now and in front of you.
    $u = Join-Path $MachineApp 'updater.ps1'
    if (-not (Test-Path -LiteralPath $u)) { throw "No updater at $u. Run the installer line once as Administrator." }
    Write-Head 'Checking github.com for a newer release...'
    & ([scriptblock]::Create((Get-Content -Raw -LiteralPath $u)))
    return
  }
  Write-Head "Updating from github.com/$DistRepo ..."
  $script = try { Invoke-RestMethod -Uri "https://github.com/$DistRepo/releases/latest/download/install.ps1" -TimeoutSec 60 }
            catch { Invoke-RestMethod -Uri "$RawBase/install.ps1?nocache=$(Get-Random)" -TimeoutSec 60 }
  Invoke-Expression $script
}
function Do-Uninstall {
  Write-Head 'Uninstall Kingsway Desk'
  if ($IsMachine) { Require-Admin 'kdesk uninstall (machine-wide install)' }
  if (Get-Control) { $null = Invoke-Admin 'status'; Write-Ok 'PIN accepted' }
  elseif (-not $Force) { throw 'The agent is not running in this session, so the PIN cannot be checked. Run kdesk start first, or add -Force.' }
  foreach ($t in @($TaskName, $Watchdog, 'KingswayDeskUpdater')) {
    $r = Invoke-Native 'schtasks.exe' @('/Delete', '/F', '/TN', $t)
    if ($r.Code -eq 0) { Write-Ok "Removed task $t" } elseif ($t -eq $TaskName) { Write-Note "Task ${t}: $($r.Out -join ' ')" }
  }
  # All sessions' agents (admin) or just ours.
  Get-Process -Name 'KingswayDesk' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 1
  foreach ($n in @('electron.app.Kingsway Desk', 'Kingsway Desk', 'KingswayDesk')) {
    Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $n -ErrorAction SilentlyContinue
  }
  if ($IsMachine) {
    Remove-Item -LiteralPath $MachineDir -Recurse -Force -ErrorAction SilentlyContinue
    # Every account's state + runtime files.
    foreach ($prof in @(Get-CimInstance Win32_UserProfile -ErrorAction SilentlyContinue | Where-Object { -not $_.Special -and $_.LocalPath })) {
      Remove-Item -LiteralPath (Join-Path $prof.LocalPath 'AppData\Roaming\Kingsway Desk') -Recurse -Force -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path $prof.LocalPath 'AppData\Local\KingswayDesk') -Recurse -Force -ErrorAction SilentlyContinue
    }
    $m = [Environment]::GetEnvironmentVariable('Path', 'Machine')
    if ($m) { [Environment]::SetEnvironmentVariable('Path', ((@($m -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $MachineApp) }) -join ';'), 'Machine') }
    Write-Ok 'Kingsway Desk removed for every account on this PC. Revoke the devices in Ktools > Drafting > Connect Desktop if they are still listed.'
    Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$MachineApp`"" -WindowStyle Hidden
    return
  }
  Remove-Item -LiteralPath $AppDir -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Kingsway Desk') -Recurse -Force -ErrorAction SilentlyContinue
  Remove-Item -LiteralPath $ControlFile -Force -ErrorAction SilentlyContinue
  $u = [Environment]::GetEnvironmentVariable('Path', 'User')
  if ($u) {
    $new = (@($u -split ';') | Where-Object { $_ -and ($_.TrimEnd('\') -ne $Root) }) -join ';'
    [Environment]::SetEnvironmentVariable('Path', $new, 'User')
  }
  Write-Ok 'Kingsway Desk removed from this account. If the device is still listed in Ktools > Drafting > Connect Desktop, revoke it there.'
  # Delete the folder holding this very script after we exit.
  Start-Process -FilePath 'cmd.exe' -ArgumentList "/c timeout /t 2 /nobreak >nul & rmdir /s /q `"$Root`"" -WindowStyle Hidden
}
function Show-Help {
  $me = if ($PSCommandPath) { $PSCommandPath } elseif ($env:KDESK_IMPL) { $env:KDESK_IMPL } else { Join-Path $MachineApp 'kdesk-impl.ps1' }
  $lines = @(Get-Content -LiteralPath $me)
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
    'users'      { Show-Users }
    'report'     { Send-Report }
    'assign'     { Do-Assign }
    'assignments' { Show-Assignments }
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
  # Report to Kingsway so failures on a PC can be read remotely (best effort).
  try {
    $tail = $null; if (Test-Path -LiteralPath $LogFile) { try { $tail = @(Get-Content -LiteralPath $LogFile -Tail 30) -join "`n" } catch {} }
    $body = @{ kind = 'kdesk'; level = 'error'; stage = "kdesk $Command"; message = $_.Exception.Message
               detail = ("args: {0}`n{1}`n--- agent log ---`n{2}" -f ($Rest -join ' '), $_.ScriptStackTrace, $tail)
               host = $env:COMPUTERNAME; user = $env:USERNAME; machine = [bool]$IsMachine
               os = ('{0} | PS {1} | admin={2}' -f [Environment]::OSVersion.VersionString, $PSVersionTable.PSVersion, $IsAdmin) }
    $bytes = [Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Compress -Depth 5))
    Invoke-RestMethod -Method POST -Uri 'https://us-central1-kingsway-internal-tools.cloudfunctions.net/desktopDiag' -ContentType 'application/json; charset=utf-8' -Body $bytes -TimeoutSec 10 | Out-Null
  } catch {}
  exit 1
}

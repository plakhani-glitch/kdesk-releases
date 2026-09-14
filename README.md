# Kingsway Desk for Windows

Headless activity agent for Kingsway employee PCs. No tray icon, no window,
no Start-menu or Startup-apps entry. It starts at every sign-in, is brought
back within 5 minutes if it is killed, and is managed only from PowerShell.

## Install or update (PowerShell, signed in as the employee, no admin rights)

```powershell
irm https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1 | iex
```

The installer asks for a pairing code. The employee gets one from
**Ktools → Drafting → Connect Desktop → Generate code** (valid 10 minutes).
To pair without the prompt:

```powershell
$env:KDESK_CODE = 'ABCD-1234'; irm https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1 | iex
```

## Manage

| Command | PIN | What it does |
|---|---|---|
| `kdesk status` | | running? connected as who? last sample, pending uploads, tasks |
| `kdesk pair ABCD-1234` | | connect this PC |
| `kdesk today` | yes | what is being tracked right now and hours today by app |
| `kdesk pause` / `kdesk resume` | yes | stop / restart tracking |
| `kdesk sync` | yes | upload pending activity now |
| `kdesk titles on\|off` | yes | record window titles (needed to match work to jobs) |
| `kdesk shots on\|off` | yes | screenshots for the AI work summary |
| `kdesk exclude "1Password, Signal"` | yes | apps never recorded |
| `kdesk disconnect` | yes | forget the pairing |
| `kdesk start` / `kdesk restart` | | start, or kill and start |
| `kdesk log [lines]` | | tail the agent log |
| `kdesk update` | | install the latest release, keeps the pairing |
| `kdesk uninstall` | yes | remove everything |

The PIN is the owner's 6-digit administrator PIN, verified by Ktools; wrong
attempts are rate-limited, logged and emailed to the owner.

## How it stays running

Two hidden Task Scheduler tasks, registered by the agent itself:
`KingswayDesk` (at logon, restarts on failure, no execution time limit) and
`KingswayDeskWatchdog` (every 5 minutes, starts the agent if it is not running).
The agent re-creates them if they are removed. Files live in
`%LOCALAPPDATA%\KingswayDesk` (app, log, `kdesk` command) and
`%APPDATA%\Kingsway Desk` (state).

Releases are built from the private `kdesk` repository; each zip ships with a
`.sha256` the installer verifies before unpacking.

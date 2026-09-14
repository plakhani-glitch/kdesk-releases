# Kingsway Desk for Windows

Headless activity agent for Kingsway employee PCs. No tray icon, no window,
no Start-menu or Startup-apps entry. It starts at every sign-in, is brought
back within 5 minutes if it is killed, and is managed only from PowerShell.

## Install or update (PowerShell **as Administrator**, once per PC, covers every account)

```powershell
irm https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1 | iex
```

Then pair each Windows account to an employee, still from the admin session:

1. Ktools → Drafting → Connect Desktop → **Code for a team member** → pick the employee → copy the code.
2. `kdesk assign <WindowsAccount> ABCD-1234`

The pairing is applied the moment that account signs in (or immediately if it
is signed in already). The installer offers this step at the end; `kdesk users`
shows every account, whether its agent is running and who it reports as.

Run without elevation, the same line installs for the current account only and
asks for that account's own code (`$env:KDESK_CODE = 'ABCD-1234'` to skip the prompt).

## Manage

| Command | PIN | What it does |
|---|---|---|
| `kdesk status` | | running? connected as who? last sample, pending uploads, task |
| `kdesk users` | | every Windows account: signed in? agent running? reporting as who? |
| `kdesk assign <WinUser> ABCD-1234` | admin | pair a Windows account to an employee before they sign in |
| `kdesk assignments` | admin | list the pre-made pairings |
| `kdesk pair ABCD-1234` | | connect the agent running in this session |
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

Add `-User <WindowsAccount>` to aim `status`, `today`, `pause`, `resume`, `sync`,
`log` … at another signed-in account (admin). The PIN is the owner's 6-digit
administrator PIN, verified by Ktools; wrong attempts are rate-limited, logged
and emailed to the owner.

## How it stays running

One hidden Task Scheduler task, `KingswayDesk`, with the **Users group** as
principal: Windows starts one agent inside every account's session at sign-in
and after unlock/reconnect, restarts it within a minute if it is killed, and no
standard user can edit or remove it. App and `kdesk` live in
`C:\Program Files\KingswayDesk` (admin-owned), pairings in
`C:\ProgramData\KingswayDesk\assign` (each file readable only by its account),
per-account state in that account's `%APPDATA%\Kingsway Desk`, logs in
`%LOCALAPPDATA%\KingswayDesk\logs`.

Releases are built from the private `kdesk` repository; each zip ships with a
`.sha256` the installer verifies before unpacking. The installer, `kdesk` and the
agent report failures and milestones to Kingsway automatically, so problems on a
PC can be diagnosed remotely.

Note: raw.githubusercontent.com caches for about 5 minutes; right after a release,
add a cache-buster: `irm "https://raw.githubusercontent.com/plakhani-glitch/kdesk-releases/main/install.ps1?$(Get-Random)" | iex`.

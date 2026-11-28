# Windows dev-toolchain maintenance

`dev-maintenance.ps1` keeps the local Windows developer toolchain inventoried and applies a small
allowlist of low-risk updates. It is separate from the Docker maintenance in this repository and
shares only the Maintenance Runner, which reads its report for the `dev_maintenance_status` tool.

## Operation

- One Scheduled Task, `DevToolMaintenance`, runs `-Mode Update` on Saturdays at 09:00 as the
  logged-in user, without elevation, on AC power only. A missed run starts when the machine is
  next available.
- The task runs the deployed copy in `%LOCALAPPDATA%\DevToolMaintenance`. Deploy or re-register
  from a clean `main` checkout with `pwsh -File dev-maintenance.ps1 -RegisterTask`; it replaces the
  same task and never creates a second one.
- `-Mode Report` (the default) installs nothing.
- Reports go to `%LOCALAPPDATA%\DevToolMaintenance\reports\<yyyyMMdd-HHmmss>-<mode>.json` and
  `.md`. They contain versions before, available and after, status, errors, verification and
  overlapping PATH copies. The profile path, user name and host name are replaced by placeholders.
- `dev_maintenance_status` returns a validated summary of the newest report. It reports `missing`,
  `invalid` (unreadable, too large or unknown schema) and `stale` (older than 8 days), and never
  returns notes, mechanisms, paths or diagnostic prose. Errors and deferral reasons are fixed
  codes. Known tool identifiers and versions remain visible; other local package identities
  and versions stay in the local report, while the MCP summary retains their category and status.

## One install mechanism per tool

| Tool | Primary mechanism | Kept besides it |
|---|---|---|
| PowerShell 7 | Microsoft Store | copies bundled inside agent apps |
| Git, GitHub CLI, FFmpeg, RipGrep, Python 3.12, Python Launcher, Node.js 22, Visual Studio Build Tools, VC++ Redistributable, WSL, Docker Desktop | WinGet | Docker Desktop and VS Build Tools also have their own updater |
| uv | WinGet | no standalone copy; MCP clients and tasks call the WinGet copy by full path |
| Claude Code CLI | WinGet | the copy bundled in the Claude desktop app |
| Codex CLI | npm global | the copies bundled in the Codex app |
| Global npm packages, global uv tools, global pip packages | npm, uv, pip | |

Project environments (`.venv`, lockfiles, pinned toolchains) belong to each repository's own
maintenance and are never changed here.

## Update policy

| Policy | Tools | Meaning |
|---|---|---|
| auto (same major) | FFmpeg, GitHub CLI | Upgraded to the exact available version when the major version is unchanged (the same `0.minor` before 1.0). GitHub CLI is machine-wide, so an unelevated run reports it as awaiting approval instead of prompting for UAC. |
| own updater | the Codex and Claude apps | Reported only; the tool updates itself. |
| controlled | everything else from WinGet, uv, Python, Node.js, Claude Code, WSL, Docker Desktop, Build Tools, Rust when installed | Reported with the available version; upgraded by hand after review. |
| individual approval | each global npm, uv tool and pip package | Reported per package; never updated in bulk. |

Git and RipGrep move to `auto (same major)` only after the first unattended upgrade of the current
allowlist has been verified. Never: `winget upgrade --all`, `npm update -g` without a package name,
reboots, killing processes or bypassing UAC.

## When an update is skipped

Before each upgrade the script reads the process list once more and skips the package when:

- a build or installer runs (`cargo`, `rustc`, `msbuild`, `cl`, `link`, `devenv`, `winget`,
  `msiexec`, Visual Studio Installer), or the tool itself runs;
- an agent is working: a Claude Code or Codex process is present and a session transcript
  (`~\.claude\projects`, `~\.codex\sessions`) was written in the last 60 minutes. An agent app that
  is open but idle does not block. If activity cannot be read, the agent counts as working.

A skipped package is retried on the next run.

## Manual upgrades of controlled tools

Some installers have side effects that the weekly script cannot rule out, which is one reason these
tools stay `controlled`. Observed when upgrading by hand with `winget upgrade --id <id> --exact`:

- **Node.js (MSI)** stops every running `node.exe` through Windows Restart Manager, even with
  `--custom "MSIRESTARTMANAGERCONTROL=Disable REBOOT=ReallySuppress"`. Every Node-based MCP server,
  gateway and stdio launcher goes down. Self-restarting tasks come back on their next repetition.
  A server can also stay half-stopped: its process lives on but no longer listens. Restart scripts
  that first verify a live listener then refuse to act, so restart such a server through its
  Scheduled Task (`scheduled_task_control` for an allowlisted alias). Afterwards check every MCP port
  and each client's server list; open agent sessions reconnect their stdio servers when next used.
  Upgrade Node only when those servers may restart.
- **Git for Windows (Inno Setup)** upgrades cleanly with
  `--custom "/NOCLOSEAPPLICATIONS /NORESTARTAPPLICATIONS"` when no process runs from the Git folder;
  check that first, because agents start `git` constantly.

Both are machine-wide installs and prompt for UAC, which the user answers.

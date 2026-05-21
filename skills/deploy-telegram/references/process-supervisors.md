# Process supervisors: systemd / launchd / Task Scheduler

The deploy-telegram daemon is a long-running process that must survive:

1. **Reboots** — auto-start when the machine boots / user logs in
2. **Crashes** — restart if the inner claude process exits unexpectedly
3. **Auto-updates** — when Claude Code updates itself in place, the supervisor must keep the wrapper alive long enough for the inner restart loop to pick up the new binary

The three operating systems use **three different supervisor philosophies**. Naive translations between them produce death spirals, silent failures, or no auto-start. This page documents the canonical pattern for each, why it's necessary, and what NOT to translate literally.

## Comparison at a glance

| Property | Linux (`systemd --user`) | macOS (launchd user) | Windows (Task Scheduler) |
|---|---|---|---|
| Unit format | INI-style `.service` file | XML `.plist` file | XML-ish `.xml` definition or PowerShell cmdlets |
| Tracks logical service vs. PID? | Logical (`RemainAfterExit=yes`) | **PID only** — no equivalent of `RemainAfterExit` | Logical (task has its own state machine) |
| Restart-on-failure | `Restart=on-failure` + `RestartSec=10` | `KeepAlive=true` + `ThrottleInterval=10` | `RestartCount` + `RestartInterval` (TimeSpan) |
| At-boot trigger | `WantedBy=default.target` (after `loginctl enable-linger`) | `RunAtLoad=true` | `New-ScheduledTaskTrigger -AtLogOn` |
| Hidden / no terminal | Native (systemd has no terminal) | Native (launchd has no terminal) | `-WindowStyle Hidden` argument on `powershell.exe` |
| Watch a directory for changes | `systemd.path` unit + inotify | `WatchPaths` array in plist (FSEvents) | Separate task running PowerShell `FileSystemWatcher` |
| Inner process model the skill uses | Direct: `tmux new-session -d -s claude ~/start-claude.sh` (systemd's `RemainAfterExit=yes` accepts the immediate exit) | Wrapper: thin script that polls `tmux has-session` (because launchd KeepAlive death-spirals on detached tmux — see below) | Direct: PowerShell hidden window runs `start-claude.ps1` with its own while-true restart loop |
| Loaded with | `systemctl --user enable && systemctl --user start` | `launchctl bootstrap gui/$UID <plist>` | `Register-ScheduledTask` + `Start-ScheduledTask` |
| Stopped with | `systemctl --user stop && disable` | `launchctl bootout gui/$UID/<label>` | `Stop-ScheduledTask` + `Unregister-ScheduledTask` |
| Logs | `journalctl --user -u <unit>` | Plist's `StandardOutPath` / `StandardErrorPath` keys | Task Scheduler history + redirected stdout/stderr files |

## Linux: `systemd --user` with `RemainAfterExit=yes`

The Linux skill's `Step 7` unit file:

```ini
[Service]
Type=simple
ExecStart=/usr/bin/tmux new-session -d -s claude %h/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
RemainAfterExit=yes
Restart=on-failure
RestartSec=10
```

How this works:

1. `tmux new-session -d -s claude ...` is **detached mode** — tmux daemonizes, and the foreground process exits 0 within ~200ms.
2. systemd would normally treat this as "service finished" and stop tracking. But `RemainAfterExit=yes` tells systemd: "The exit was expected. Consider the service still running even though there's no foreground PID."
3. `Restart=on-failure` only triggers if `ExecStart` returns **non-zero**. Detached tmux returns 0, so no restart loop. (If you mistype the script path and tmux can't exec it, you DO get the restart loop, which is desirable.)
4. After systemd-managed reboot, `loginctl enable-linger <user>` is required so user services run without an active SSH session.

The skill's `start-claude.sh` has its own `while true; do claude ...; sleep 3; done` loop **inside** tmux, so crashes of claude itself are handled at the script level. systemd's `Restart=on-failure` is the outermost safety net only.

## macOS: launchd with a wrapper script (the wrapper pattern)

launchd has **no `RemainAfterExit`**. If you naively translate the systemd unit to a plist:

```xml
<key>ProgramArguments</key>
<array>
  <string>/opt/homebrew/bin/tmux</string>
  <string>new-session</string><string>-d</string><string>-s</string><string>claude</string>
  <string>/Users/&lt;user&gt;/start-claude.sh</string>
</array>
<key>KeepAlive</key><true/>
```

you get this **death spiral**:

1. launchd runs `tmux new-session -d`. tmux daemonizes and the foreground PID exits 0 in ~200ms.
2. launchd sees the PID exit. `KeepAlive=true` triggers a restart.
3. launchd runs `tmux new-session -d` again. tmux errors: `duplicate session: claude`. Process exits 1.
4. launchd restarts immediately. Goto 3 forever.

You'd see `~/Library/Logs/claude-telegram.log` filling with `duplicate session` errors at line-per-second rate. `KeepAlive=false` breaks the loop but also removes the safety net — if claude truly crashes, launchd has stopped watching.

**Canonical macOS solution: a wrapper script** that launchd watches:

```bash
#!/bin/bash
export PATH="/opt/homebrew/bin:$HOME/.bun/bin:$HOME/.npm-global/bin:$PATH"
if ! tmux has-session -t claude 2>/dev/null; then
  tmux new-session -d -s claude /Users/<user>/start-claude.sh
fi
# Block while session lives. When it dies, exit non-zero so KeepAlive restarts us.
while tmux has-session -t claude 2>/dev/null; do
  sleep 30
done
exit 1
```

This script:
- Creates the tmux session **only if missing** (idempotent across launchd-triggered restarts)
- Blocks in a `sleep 30` loop, polling for session liveness
- Exits non-zero only when tmux dies for real → launchd KeepAlive correctly restarts it
- `ThrottleInterval=10` in the plist prevents thrash if claude crashes immediately

The full launchd plist (from macOS overlay):

```xml
<dict>
    <key>Label</key>            <string>com.openclaw.claude-telegram</string>
    <key>ProgramArguments</key>
    <array><string>/Users/<user>/start-claude-launchd-wrapper.sh</string></array>
    <key>RunAtLoad</key>        <true/>
    <key>KeepAlive</key>        <true/>
    <key>ThrottleInterval</key> <integer>10</integer>
    <key>StandardOutPath</key>  <string>/Users/<user>/Library/Logs/claude-telegram.log</string>
    <key>StandardErrorPath</key><string>/Users/<user>/Library/Logs/claude-telegram.log</string>
</dict>
```

Note: launchd does **not** expand `${HOME}` or `~/` inside plist values. Always substitute the real path before writing. Use `plutil -lint <plist>` to verify the XML is well-formed before bootstrapping.

## Windows: Task Scheduler with a PowerShell hidden window

Windows has neither systemd nor launchd. Task Scheduler is the closest equivalent — but its model is "run a command on a trigger" rather than "supervise a process group", so the inner restart loop happens in the launch script, not in the task itself.

Two Scheduled Tasks (registered as the current user, `Interactive` logon type):

| Task | Trigger | Action |
|---|---|---|
| `ClaudeCodeTelegramDaemon` | `AtLogOn` | `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\start-claude.ps1"` |
| `ClaudeTelegramInboxMover` | `AtLogOn` | `powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File "$env:USERPROFILE\tg-inbox-mover.ps1"` |

Both have:

- `-StartWhenAvailable` (catch up on missed triggers if the machine was off)
- `-RestartCount 999 -RestartInterval (New-TimeSpan -Minutes 1)` (recover from inner-script crashes)
- `-ExecutionTimeLimit (New-TimeSpan -Days 365)` (long-running daemons aren't a "task that should finish")
- `LogonType Interactive` principal (so the task has access to per-user environment, including the bundled `claude.exe` and `~/.bun/bin/bun.exe`)

The `start-claude.ps1` script has its own `while ($true) { ... ; Start-Sleep 3 }` restart loop — same as Linux. Task Scheduler's `RestartCount` is the outer safety net for cases where PowerShell itself dies.

### Why a separate Scheduled Task for the inbox mover

The inbox mover uses PowerShell's `FileSystemWatcher` (`.NET ReadDirectoryChangesW` wrapper), which requires a long-running script holding a reference to the watcher object. Co-mounting it inside `start-claude.ps1` would mean restarting the watcher every time claude crashes — losing in-flight uploads during the gap.

A separate task isolates the two lifecycles: claude can restart freely; uploads keep getting moved as long as the user is logged in.

### Why `WindowStyle Hidden` and not a Windows Service

A Windows Service runs in session 0 (the system session), which doesn't have access to `%USERPROFILE%` env var the way an interactive user session does. The deploy-telegram daemon depends on per-user state (bundled `claude.exe`, OAuth credentials, `~/.bun/bin/bun.exe`). Running as a Service would mean re-pointing all paths to system locations and re-authenticating as a system user — much more invasive.

`Interactive logon type` + `WindowStyle Hidden` gives the best of both worlds: the task runs as the user (with all their state), but no visible window pollutes the desktop.

Trade-off: the daemon stops when the user logs off. If you need a true 24/7 daemon on Windows (e.g. on a Windows server), you'd have to set up the task as `S4U` or `Password` logon type, which is out of scope here.

## Common operations

### Start / stop the daemon

| Platform | Start | Stop |
|---|---|---|
| Linux | `systemctl --user start claude-telegram` | `systemctl --user stop claude-telegram` |
| macOS | `launchctl bootstrap gui/$(id -u) <plist>` (after `bootout` if previously loaded) | `launchctl bootout gui/$(id -u)/com.openclaw.claude-telegram` |
| Windows | `Start-ScheduledTask -TaskName ClaudeCodeTelegramDaemon` | `Stop-ScheduledTask -TaskName ClaudeCodeTelegramDaemon` |

### Kill the inner process tree (for an immediate restart)

| Platform | Command |
|---|---|
| Linux | `tmux kill-session -t claude; pkill -f 'bun.*server.ts'; pkill -f 'claude --dangerously'` |
| macOS | same as Linux |
| Windows | `Get-Process bun,claude -ErrorAction SilentlyContinue \| Stop-Process -Force` then restart task |

### Check status

| Platform | Command |
|---|---|
| Linux | `systemctl --user status claude-telegram` and `journalctl --user -u claude-telegram -n 50` |
| macOS | `launchctl list \| grep com.openclaw` and `tail -50 ~/Library/Logs/claude-telegram.log` |
| Windows | `Get-ScheduledTask -TaskName ClaudeCodeTelegramDaemon \| Get-ScheduledTaskInfo` and `Get-Process bun,claude` |

## Why not Docker?

Tempting answer to platform divergence: containerize the whole thing. Tried and dropped:

- The Telegram channel plugin spawns Bun via stdio MCP protocol — works fine in container.
- But `claude` needs to access the host filesystem for projects, git repos, user's CLAUDE.md, MCP servers etc. — full host mount erodes the container benefit.
- More importantly: `claude` auth (`~/.claude.json`, OAuth state) is per-user and per-machine; reproducing that inside a container while keeping it secure is complex.
- And the user's primary daily-driver tool is the host Claude Code Desktop App, which IS host-native. The daemon needs to coexist with that, which is much easier as another host process than as a container neighbor.

Native-on-host is more invasive to install but simpler to operate. The trade-off chosen.

# Post-deploy hardening: incidents and what they taught us

Initial deploy success is not steady state. This page consolidates the production incidents observed across all three platforms and the permanent fixes folded back into the deploy steps. Reading this is not required to use the skill — but if you suspect upstream changes have eroded a fix, this is where the rationale lives.

Incidents are grouped by failure mode, not platform, because most lessons apply universally even when the implementation differs.

---

## §1. Trust dialog persistence (macOS, Linux first-launch)

**Symptom**: After a reboot or `pkill claude`, the freshly-spawned daemon blocks on:

```
 Quick safety check: Is this a project you created or one you trust?
 ❯ 1. Yes, I trust this folder
   2. No, exit
```

Inbound Telegram messages queue silently. The user gets no replies.

**Root cause**: `~/.claude.json` stores per-cwd trust state at `projects.<cwd>.hasTrustDialogAccepted`. Default is `false`. Pressing Enter flips it to `true` for that cwd — but only that one cwd. After a Mac reboot or fresh launchd start, something (Desktop App, CC upgrade, an unknown) sometimes flips it back to `false`, re-prompting on every wrapper restart.

**Fix**: Explicitly patch the field as a deterministic deploy step:

```python
import json, os
p = os.path.expanduser('~/.claude.json')
d = json.load(open(p))
projects = d.setdefault('projects', {})
projects.setdefault(os.path.expanduser('~'), {})['hasTrustDialogAccepted'] = True
json.dump(d, open(p, 'w'), indent=2)
```

Platform overlays:
- **macOS** ([`platforms/macos.md`](../platforms/macos.md) Step 7c): explicit patch step
- **Linux** ([`platforms/linux.md`](../platforms/linux.md)): the original `tmux send-keys Enter` handles first-launch; reboots usually keep trust state on Linux. Patch suggested as defense-in-depth in headless deployments.
- **Windows**: deploy-time visible PowerShell window with the human pressing Enter (Step 8 in [`platforms/windows.md`](../platforms/windows.md)). No reboot resurfacing issue observed since CC stores the answer the same way as Linux/macOS — explicit patch added as defense-in-depth.

---

## §2. `AskUserQuestion` deadlock (universal, but discovered on macOS)

**Symptom**: Daemon goes unresponsive for an extended period (1 h 15 min in the production incident on Mac mini, 2026-05). Telegram user sends messages, no replies. SSH-ing into the daemon's tmux pane reveals an `AskUserQuestion` widget waiting for keyboard input that no one can provide.

**Root cause**: `AskUserQuestion` (and similar numbered-picker widgets) block the main input stream until someone hits arrow keys + Enter **locally**. Inbound channel messages cannot drive them. MCP stdio reaches its idle timeout; the reply tool's response queue silently fills and is dropped.

**Fix**: A hard rule in CLAUDE.md (Rule 2 in [`claude-md-rules.md`](./claude-md-rules.md)) forbidding the model from invoking any select / numbered-picker widget, regardless of mode. The rule applies even in pure terminal mode because a channel can be attached later, and any lingering picker locks it out.

Recovery for an already-stuck session: kill the daemon (`pkill claude` / `Stop-ScheduledTask`) and restart. The session's context is lost.

---

## §3. Claude Code native binary auto-update breakage (macOS, less common on Linux)

**Symptom**: After CC auto-updates, the daemon's `while true; do claude ...; done` loop produces a tight crash/respawn at ~3s interval:

```
Error: claude native binary not installed
Claude exited. Restarting in 3s...
Error: claude native binary not installed
...
```

**Root cause**: `npm install -g @anthropic-ai/claude-code@latest` is supposed to pull a platform-specific optional dependency (`@anthropic-ai/claude-code-darwin-arm64`, `linux-x64`, etc.). Sometimes — observed on macOS Apple Silicon — the optional dep doesn't get pulled, leaving the launcher invoking a `claude.js` that immediately errors on the missing native binary.

**Fix**: Self-healing in `start-claude.sh`'s loop. Before each `claude --channels` invocation:

1. Run `claude --version`. If it succeeds, proceed.
2. If it fails with `"native binary not installed"`, run `npm install -g @anthropic-ai/claude-code@latest`. Verify it healed.
3. **Notify the user directly via Telegram Bot API** (since MCP reply tool is unavailable while claude is broken): `curl https://api.telegram.org/bot<token>/sendMessage`
4. Apply exponential backoff (60s → 300s → 900s → 1800s) if self-heal fails repeatedly, so a real outage doesn't burn through 10-minute reinstalls in a tight loop.

**Platform applicability**:
- **macOS** ([`platforms/macos.md`](../platforms/macos.md) Step 7.1): self-heal integrated into `start-claude.sh`. The macOS deploy was the original site of this incident.
- **Linux**: same risk in principle; Linux skill could be enhanced with the same logic. As of writing, not observed in production on Linux servers.
- **Windows**: the daemon reuses the **bundled `claude.exe` from the Desktop App's directory**, which Anthropic manages via its own auto-updater (not npm). The npm optional-dep failure mode doesn't apply. If the Desktop App's bundled binary breaks, the user would need to reinstall the Desktop App — out of scope for this skill.

---

## §4. Desktop App vs CLI bot-token contention (macOS-specific currently, but worth understanding)

**Symptom** (macOS only, as of 2026-05): both the Claude Desktop App and a CLI `claude` session running on the same Mac under the same user. Both read `~/.claude/settings.json`. If `enabledPlugins.telegram@claude-plugins-official: true` is set at user scope, both processes try to load the plugin. The Telegram plugin's bun MCP server makes a `getUpdates` call. Two long-pollers on the same bot token → HTTP 409 Conflict → only the most recently-started consumer wins, the other loses all messages.

**Root cause**: On macOS, the Desktop App's claude invocation **does** include `--channels` (or some equivalent that activates channel polling) when channels are enabled in settings.json. So both Desktop App and the deploy-telegram daemon become long-poll competitors.

**Fix**: Install the Telegram plugin at **local scope** of the daemon's launch cwd (`$HOME`), not user scope. This writes the enable-flag to `$HOME/.claude/settings.local.json` instead of `~/.claude/settings.json`. The plugin then only auto-loads when `claude` starts from `$HOME` — which the daemon's launcher always does (`cd ~`), but the Desktop App doesn't.

For belt-and-suspenders, the macOS deploy can also write `enabledPlugins.telegram@...: false` to the Desktop App's typical cwd's local settings (Step 7d, optional).

**Windows**: investigated 2026-05-21 — **does not exhibit this contention**. The Windows Desktop App invokes the bundled claude.exe with `--plugin-dir <skills-cache>` for its agent-mode skills, **not** `--channels`. So even though `channelsEnabled: true` is in shared settings.json, Desktop App's claude.exe never spawns a Telegram bun child. Only the daemon does.

> **Don't rely on this**: if a future Desktop App version changes to use `--channels`, Windows would hit the same contention. To future-proof, the Windows overlay could switch to `--scope local` install (currently `--scope user`). The trade-off is that the Windows daemon would need its launcher to `cd $env:USERPROFILE` before invoking claude (which it already does), and any future manual `claude --channels` invocation from a different cwd wouldn't auto-load the plugin.

**Linux**: not affected — no Linux Desktop App ships an integrated CC session, only the CLI. There's nothing to contend with.

---

## §5. Settings file overwrite clobbering user state (universal)

**Symptom**: After running the skill, some pre-existing setting that the user / another tool had configured is gone:

- A user-installed analytics PreToolUse hook erased (observed on the 2026-05-21 Windows validation deploy — the operator had a third-party tool-usage reporter wired up)
- Desktop App's per-cwd `projects.<cwd>` state in `~/.claude.json` erased (would have been observed on macOS if the skill ran the Linux pattern, hence the macOS skill explicitly avoids it)
- Custom MCP servers in `mcpServers` erased
- User-customized `permissions.allow` shortened

**Root cause**: The original Linux skill's Steps 3 and 4 use bash here-doc `cat > <file> << EOF` which fully overwrites. Whatever the file used to contain is destroyed silently.

**Fix**: All overlays now **merge additively**:

- **macOS** uses inline Python (`json.load` → mutate → `json.dump`)
- **Windows** uses PowerShell (`Get-Content -Raw | ConvertFrom-Json` → mutate → `ConvertTo-Json | WriteAllText`)
- **Linux** should adopt the macOS Python pattern (current overlay still uses `cat > EOF`; planned fix as part of this refactor)

Before any mutation: copy the file to `<path>.before-deploy-telegram.bak`. Idempotent on re-runs (only backs up if no backup exists). Gives the user a clean undo path.

> **`~/.claude.json` deserves extra care.** On macOS the Desktop App writes ~23 KB of session/project state there (`projects`, `oauthAccount`, `tipsHistory`, `cachedGrowthBookFeatures`, `seenNotifications`, etc.). Overwriting it would log the user out of Desktop App and lose months of cached state. **Always merge, never replace.**

---

## §6. UserPromptSubmit hook doesn't fire on channel messages (production bug 2026-05-06)

**Symptom**: `~/.claude/CLAUDE.md` and `~/CLAUDE.md` both correctly contain the channel routing rule. The `~/telegram-routing-hook.sh` (UserPromptSubmit hook) is correctly registered in `settings.json`. But the daemon still drifts after a long session — Claude writes to stdout instead of calling the reply tool. Inspection of the jsonl session log shows **zero** occurrences of the "TELEGRAM ROUTING MANDATORY" string the hook should inject.

**Root cause**: Channel-routed messages go through a different code path inside Claude Code's input handler — `queue dequeue → user message`, which **bypasses `UserPromptSubmit`** entirely. The hook fires correctly for terminal-typed messages but never for Telegram pushes.

**Implication**: The routing hook is **defense-in-depth, not a guarantee**. It still helps when:
- The user types reminders from the daemon's terminal (rare in production)
- Future Claude Code versions route channel messages through `UserPromptSubmit` (potentially planned)
- It's installed for free anyway and may help with channel modes not yet invented

But the **primary defense remains the CLAUDE.md rule** + post-compact mitigation (currently no defense beyond "be more aggressive about restarting the daemon every few days").

---

## §7. Long-session attention drift (production bug 2026-05-06)

**Symptom**: A claude daemon that has been running for ~49 hours suddenly stops calling the reply tool for Telegram messages, even though it was working perfectly for the first 48 hours. The drift is cliff-like, not gradual.

**Root cause**: After many `compact` operations in a long session, model attention to the CLAUDE.md rule erodes. Once one turn skips the reply tool successfully (no immediate consequence visible to the model), subsequent turns follow the pattern.

**Mitigation** (not a fix): restart the daemon every ~24 hours. The simplest cron approach is to schedule a "midnight kill + relaunch" Task. Out of scope for the deploy skill itself.

**Long-term fix** (not implemented): a watchdog that monitors the bot's `getUpdates` for high-latency / dropped acks and force-restarts. The Mac skill's self-heal logic could be extended to detect this case.

---

## §8. Slash commands over Telegram don't work (universal architectural limit)

**Symptom**: User sends `/model opus`, `/clear`, `/compact`, `/cost`, `/help` from Telegram. Instead of switching models / clearing context / etc., Claude either replies "I can't change my own model" or processes the literal string as a normal user prompt.

**Root cause**: Claude Code's slash-command parser only intercepts input typed **directly into the local terminal**. Messages arriving via the Telegram channel plugin are injected into the prompt stream **after** the CLI's input parser, so the model sees the literal string `/model opus` as a normal user message.

**Implications** (this is a hard architectural limit, not a bug to be patched):

- Cannot switch model from Telegram. To change: edit `start-claude.{sh,ps1}` to add `--model <name>` (or set `env.ANTHROPIC_MODEL` in settings.json), then kill+relaunch the daemon.
- Cannot clear context (`/clear`), compact (`/compact`), check cost (`/cost`) from Telegram. For clear context remotely: restart the daemon (fresh session has empty context).
- The pairing slash commands (`/telegram:access pair <code>` / `policy allowlist`) MUST be entered in the daemon's terminal — see [`pairing-and-access.md`](./pairing-and-access.md).

This is documented in every platform overlay as an "operating note", not as a bug.

---

## §9. Mainland-China network access (deployment-level)

**Symptom**: Server can't reach `api.telegram.org`. Bun fails on every long-poll. Plugin install via `claude plugin install` fails on GitHub fetches.

**Root cause**: Telegram and GitHub are blocked from mainland-China public networks.

**Fix**: Deploy to a server outside mainland China (HK, SG, JP, US, EU all confirmed working). VPN-on-host is possible but fragile.

**Windows local deploy**: this same constraint applies to your local network. If your home network is mainland-China-blocked, neither the Bun long-poll nor `claude plugin install` will work even from a Windows desktop. A consumer VPN on the Windows machine itself solves this.

---

## Verifying a healthy deployment

After running the skill, the following sanity checks should all pass:

1. **Daemon process tree present** — see [`troubleshooting.md`](./troubleshooting.md) for the expected per-platform tree.
2. **No 409 from Telegram**: `curl 'https://api.telegram.org/bot<TOKEN>/getUpdates?limit=1&timeout=0'` returns `"ok":true`.
3. **Daemon's pane shows "Listening for channel messages"** (Linux/macOS via `tmux capture-pane`; Windows via the visible window or by tailing log).
4. **End-to-end test**: phone sends a message, the daemon logs `← telegram · <user_id>: <text>`, claude calls `plugin:telegram:telegram - reply`, the phone receives the reply.
5. **No hook errors in pane**: search for `hook error` — none expected.
6. **CLAUDE.md rules present**: `grep -l 'BEGIN: channel-routing-rule' ~/CLAUDE.md ~/.claude/CLAUDE.md` returns both paths.

If any check fails, see [`troubleshooting.md`](./troubleshooting.md).

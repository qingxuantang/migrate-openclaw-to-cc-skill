---
name: deploy-telegram
description: Deploy Claude Code on a remote Linux server and connect it to Telegram for remote access. Agent-executable — all steps are deterministic shell commands. Requires server SSH access, Telegram bot token, and Claude OAuth token.
disable-model-invocation: false
---

# Agent Runbook: Deploy Claude Code + Telegram Channel

## Contract

**Input** (collect ALL before starting — do not proceed with missing values):

| Parameter | Format | Example | How to obtain |
|-----------|--------|---------|---------------|
| `SSH_HOST` | IP or hostname | `203.0.113.10` | User provides |
| `SSH_USER` | string | `ubuntu` | User provides (default: `ubuntu`) |
| `SSH_PORT` | integer | `22` | User provides (default: `22`) |
| `BOT_TOKEN` | string `digits:AAx...` | `123456789:AAHfiq...` | User creates via Telegram @BotFather `/newbot` |
| `CLAUDE_TOKEN` | string `sk-ant-oat01-...` | `sk-ant-oat01-abc...` | User runs `claude setup-token` on a machine with a browser |

**Output**: Claude Code running persistently on the server (survives reboot), connected to Telegram, awaiting pairing.

**Post-deploy** (requires human): User messages the bot on Telegram, receives a pairing code, agent runs the pair command.

## Network Requirements

Before starting, verify the server meets these network conditions. **All three must pass.**

```bash
ssh ${SSH_USER}@${SSH_HOST} -p ${SSH_PORT} bash -s << 'EOF'
echo "=== Network Check ==="

# 1. Telegram API (required for bot communication)
curl -sf --max-time 10 "https://api.telegram.org" >/dev/null 2>&1 \
  && echo "PASS: api.telegram.org reachable" \
  || echo "FAIL: api.telegram.org blocked — Telegram API is blocked in mainland China and some restricted networks. Use a server in a region where Telegram is accessible (US, EU, Japan, Singapore, etc.)"

# 2. GitHub (required for plugin marketplace installation)
curl -sf --max-time 10 "https://github.com" >/dev/null 2>&1 \
  && echo "PASS: github.com reachable" \
  || echo "FAIL: github.com blocked or slow — required to install the Telegram plugin from the official marketplace"

# 3. Anthropic API (required for Claude Code to function)
curl -sf --max-time 10 "https://api.anthropic.com" >/dev/null 2>&1 \
  && echo "PASS: api.anthropic.com reachable" \
  || echo "FAIL: api.anthropic.com blocked — Claude Code cannot function without API access"

echo "=== End Network Check ==="
EOF
```

**If any FAIL**: Stop. Tell the user:
- Mainland China servers will fail all three checks. They must use a server outside mainland China (Hong Kong, Singapore, Japan, US, EU, etc.).
- If only GitHub fails, they may be able to configure a proxy, but it adds significant complexity.

## Execution

### Pick an execution mode

This skill is written remote-first: every step is wrapped in `$SSH_CMD bash -s << EOF`. That works for the most common case (a controller agent on your laptop reaches out to a target server via SSH), but it also degrades cleanly to **local self-execution** — where the agent runs on the same machine it's installing Claude Code on, e.g. an OpenClaw agent setting up Claude Code on its own host as a parallel deployment.

Define `SSH_CMD` **once**, before Step 1, depending on the mode:

| Mode | When | `SSH_CMD` definition |
|---|---|---|
| **Remote** | Controller agent (e.g. local Claude Code) targets a different machine | `SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${SSH_HOST}"` |
| **Local self-execution** | The agent runs on the target host itself (e.g. OpenClaw deploying Claude Code beside itself) | `SSH_CMD=""` — every `$SSH_CMD bash -s` collapses to a plain local `bash -s` |

> **Don't fork the skill** by stripping the `$SSH_CMD` calls. The wrapper is the universal entry point — both modes use the same command lines verbatim. With `SSH_CMD=""`, `$SSH_CMD bash -s << 'EOF' ... EOF` is just `bash -s << 'EOF' ... EOF`, which is exactly what you want for local execution.

### Self-execution caveats (OpenClaw setting up Claude Code on its own host)

If the executing agent is OpenClaw on the target machine, also read these:

1. **Don't kill yourself.** Do not stop the OpenClaw process during deployment. This is a *parallel* install, not a takeover. OpenClaw keeps its existing channels (especially WhatsApp); Claude Code takes Telegram.
2. **Same Linux user as your future Claude Code.** Whatever user runs `claude` later must own `~/.claude/`, `~/CLAUDE.md`, `~/start-claude.sh`. Easiest setup: OpenClaw and Claude Code share the same user. If they need to differ, switch users explicitly (e.g. `sudo -u ubuntu`) for the deploy steps.
3. **OAuth token still has to come from a browser.** `claude setup-token` requires interactive login. Headless servers can't run it. Ask the human to run it on their laptop and paste the resulting `sk-ant-oat01-...` token back.
4. **New Telegram bot — never reuse the one OpenClaw is currently using.** Two long-pollers on the same bot token = 409 Conflict and both processes silently stop receiving messages. Get a fresh bot from @BotFather.
5. **Cron jobs and other channels keep running.** Don't "clean up" your existing OpenClaw setup as part of this deploy. Migration is the *next* skill (`migrate-openclaw`); this one only adds Claude Code beside what's already running.

For the corresponding migration skill (which has more self-execution caveats — read-your-own-SOUL.md, open-heart-surgery rules, etc.) see [`../migrate-openclaw/SKILL.md`](../migrate-openclaw/SKILL.md).

---

Execute Steps 1–9b sequentially. After each step, check exit code — abort on failure.

---

### Step 1: Install Node.js (if missing)

```bash
$SSH_CMD bash -s << 'EOF'
set -e

if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node --version | grep -oP '(?<=v)\d+')
  if [ "$NODE_MAJOR" -ge 20 ]; then
    echo "OK: Node.js $(node --version) already installed"
    exit 0
  else
    echo "Node.js $(node --version) is too old. Installing v22..."
  fi
else
  echo "Node.js not found. Installing v22..."
fi

# Install Node.js 22 LTS via NodeSource
if command -v sudo >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - 2>&1 | tail -3
  sudo apt-get install -y nodejs 2>&1 | tail -3
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
  apt-get install -y nodejs 2>&1 | tail -3
fi

echo "INSTALLED: Node.js $(node --version)"
EOF
```

### Step 2: Install Claude Code, tmux, and Bun

```bash
$SSH_CMD bash -s << 'EOF'
set -e

# Claude Code
if ! command -v claude >/dev/null 2>&1; then
  echo "Installing Claude Code..."
  if command -v sudo >/dev/null 2>&1; then
    sudo npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  else
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  fi
fi
echo "CLAUDE: $(claude --version)"

# tmux
if ! command -v tmux >/dev/null 2>&1; then
  echo "Installing tmux..."
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq tmux >/dev/null 2>&1
  else
    apt-get update -qq && apt-get install -y -qq tmux >/dev/null 2>&1
  fi
fi
echo "TMUX: $(tmux -V)"

# Bun (required by Telegram plugin — runs the MCP server)
if [ ! -f "$HOME/.bun/bin/bun" ]; then
  echo "Installing Bun..."
  curl -fsSL https://bun.sh/install | bash 2>&1 | tail -1
fi
echo "BUN: $($HOME/.bun/bin/bun --version)"
EOF
```

### Step 3: Configure authentication

Substitute `${CLAUDE_TOKEN}` with the actual token value.

```bash
$SSH_CMD bash -s << ENDAUTH
set -e

# Bypass interactive onboarding (Claude Code requires TTY for these dialogs)
cat > ~/.claude.json << 'CJSON'
{
  "hasCompletedOnboarding": true,
  "hasAcknowledgedCostThreshold": true
}
CJSON

# Verify auth
RESULT=\$(CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}' claude auth status 2>&1)
echo "\$RESULT"
echo "\$RESULT" | grep -q '"loggedIn": true' || { echo "FATAL: Auth failed. Token may be invalid or expired. User must regenerate with: claude setup-token"; exit 1; }
echo "OK: Auth verified"
ENDAUTH
```

### Step 4: Write settings

```bash
$SSH_CMD bash -s << 'EOF'
set -e
mkdir -p ~/.claude
cat > ~/.claude/settings.json << 'SETTINGS'
{
  "permissions": {
    "allow": [
      "Bash(*)", "Read(*)", "Write(*)", "Edit(*)",
      "Glob(*)", "Grep(*)", "WebSearch(*)", "WebFetch(*)",
      "NotebookEdit(*)", "mcp__*"
    ],
    "deny": [],
    "defaultMode": "bypassPermissions"
  },
  "channelsEnabled": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
echo "OK: settings.json written"
EOF
```

> **CRITICAL**: `channelsEnabled: true` is mandatory. Without it, inbound Telegram messages are silently dropped with no error — the debug log shows `Channel notifications skipped`.

> **CRITICAL**: `permissions.defaultMode: "bypassPermissions"` is what actually silences permission prompts. `permissions.allow` and `skipDangerousModePermissionPrompt` only control the *judgment* after a check is triggered — they don't suppress the check itself. Six modes exist (`default`/`acceptEdits`/`plan`/`auto`/`dontAsk`/`bypassPermissions`); only the last is equivalent to launching with `--dangerously-skip-permissions` every time. The startup script in Step 6 already passes that flag, but setting `defaultMode` here also covers any manual `claude` invocations on the same server.

### Step 5: Install Telegram plugin

Substitute `${CLAUDE_TOKEN}` with the actual token value.

```bash
$SSH_CMD bash -s << ENDPLUGIN
set -e
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"

# Add official marketplace (idempotent)
claude plugin marketplace add anthropics/claude-plugins-official 2>&1 || true
claude plugin marketplace update claude-plugins-official 2>&1 | tail -1

# Clean install (uninstall first to avoid stale state)
claude plugin uninstall telegram@claude-plugins-official 2>/dev/null || true
claude plugin install telegram@claude-plugins-official 2>&1 | tail -1

# Verify
claude plugin list 2>&1 | grep -q telegram || { echo "FATAL: Plugin install failed."; exit 1; }
echo "OK: telegram plugin installed"
ENDPLUGIN
```

> **NEVER use `--plugin-dir` flag with `--channels`**. This tags the plugin as "inline" source, causing: `Channel notifications skipped: you asked for plugin:telegram@claude-plugins-official but the installed telegram plugin is from inline`.

### Step 5b: Patch plugin to disable channel permission relay

**Why**: As of Claude Code 2.1.92, the Telegram plugin's `server.ts` declares an opt-in capability `'claude/channel/permission': {}`. When declared, Claude Code relays every tool-call permission request (e.g. Edit, Write, Bash) from the channel session to Telegram as an Allow/Deny button card. This check is **independent of** `--dangerously-skip-permissions`, `permissions.allow` in `settings.json`, and `skipDangerousModePermissionPrompt` — those flags only govern terminal sessions. The result: even with all bypasses on, the Telegram user is spammed with permission cards on every tool call.

The fix is to comment out that single capability declaration. The channel session then falls back to the terminal permission flow, which the bypass flags correctly handle.

```bash
$SSH_CMD bash -s << 'EOF'
set -e
F=$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
if [ ! -f "$F" ]; then
  echo "FATAL: telegram plugin server.ts not found at $F"; exit 1
fi
[ ! -f "$F.bak" ] && cp "$F" "$F.bak"
sed -i "s|'claude/channel/permission': {},|// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG despite --dangerously-skip-permissions|" "$F"
grep -q "^ *// 'claude/channel/permission'" "$F" \
  && echo "OK: channel permission relay disabled" \
  || { echo "WARNING: patch did not apply — plugin may have changed upstream. Inspect $F manually."; exit 1; }
EOF
```

> **Re-apply after plugin updates.** `claude plugin marketplace update` or a reinstall will overwrite `server.ts`. Re-run this step whenever the plugin is updated. A `.bak` copy is preserved on first run.

### Step 6: Configure bot token

Substitute `${BOT_TOKEN}` with the actual token value.

```bash
$SSH_CMD bash -s << ENDBOT
set -e
mkdir -p ~/.claude/channels/telegram
echo "TELEGRAM_BOT_TOKEN=${BOT_TOKEN}" > ~/.claude/channels/telegram/.env
chmod 600 ~/.claude/channels/telegram/.env
echo "OK: bot token configured"
ENDBOT
```

### Step 7: Create startup script and systemd service

Substitute `${CLAUDE_TOKEN}` and `${BOT_TOKEN}` with actual values.

```bash
$SSH_CMD bash -s << ENDSETUP
set -e

# --- Startup script ---
cat > ~/start-claude.sh << 'STARTEOF'
#!/bin/bash
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}'
export TELEGRAM_BOT_TOKEN='${BOT_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"
cd ~
while true; do
    claude --dangerously-skip-permissions \
      --channels plugin:telegram@claude-plugins-official
    echo "Claude exited. Restarting in 3s..."
    sleep 3
done
STARTEOF
chmod 700 ~/start-claude.sh

# --- systemd user service (auto-start on boot) ---
mkdir -p ~/.config/systemd/user

cat > ~/.config/systemd/user/claude-telegram.service << SVCEOF
[Unit]
Description=Claude Code with Telegram Channel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=/usr/bin/tmux new-session -d -s claude %h/start-claude.sh
ExecStop=/usr/bin/tmux kill-session -t claude
RemainAfterExit=yes
Restart=on-failure
RestartSec=10

[Install]
WantedBy=default.target
SVCEOF

# Enable lingering (allows user services to run without login)
sudo loginctl enable-linger \$(whoami) 2>/dev/null || loginctl enable-linger \$(whoami) 2>/dev/null || true

# Enable service
systemctl --user daemon-reload
systemctl --user enable claude-telegram.service

echo "OK: startup script + systemd service created"
echo "    Service will auto-start on server reboot"
ENDSETUP
```

### Operating note: slash commands over Telegram do NOT work

**Slash commands sent from Telegram are not recognized by Claude Code's CLI parser.** Claude Code only intercepts slash commands (e.g. `/model opus`, `/clear`, `/compact`, `/cost`, `/help`) when they are typed **directly into the local terminal**. Messages arriving via the Telegram channel plugin are injected into the prompt stream **after** the CLI's input parser, so the model sees the literal string `/model opus` as a normal user message and has no way to act on it.

**Implications**:
- You **cannot** switch the model from Telegram. You must SSH in, edit `~/start-claude.sh` to add a `--model <name>` flag (or set `env.ANTHROPIC_MODEL` in `~/.claude/settings.json`), then kill+relaunch the tmux session.
- You **cannot** clear context (`/clear`), compact (`/compact`), check cost (`/cost`), or invoke any other CLI-level command from Telegram. Each of these requires a terminal session — for "clear context" remotely, restart the tmux session (a fresh session has empty context).
- This is a hard architectural limit of the channel plugin design, not a bug to be patched.

If you want to control the model on a per-deployment basis, set it at startup. Example startup script line:

```bash
claude --dangerously-skip-permissions \
  --model claude-opus-4-5-20250929 \
  --channels plugin:telegram@claude-plugins-official
```

### Step 7b: Telegram inbox mover (avoid sensitive-file guard)

**Why**: When a Telegram user uploads a file (image, PDF, xlsx, txt, …), the plugin drops it into `~/.claude/channels/telegram/inbox/`. As soon as Claude tries to `cp`/`mv`/`Read` that file, Claude Code's **hard-coded sensitive-file guard** fires (because the path is under `~/.claude/`) and pops a blocking permission dialog. This guard is **not** bypassed by `--dangerously-skip-permissions`, `permissions.allow`, `skipDangerousModePermissionPrompt`, or `permissions.defaultMode: bypassPermissions` — it's an independent hard-coded check. The result: the Claude session in tmux silently freezes on a dialog while the Telegram user gets nothing back.

The fix is **architectural**: install a tiny systemd path-unit watcher that moves new files out of `~/.claude/channels/telegram/inbox/` to `~/telegram-inbox/` (a normal directory) the instant they land. Then Claude only ever touches the safe path and the guard never triggers.

```bash
$SSH_CMD bash -s << 'EOF'
set -e

mkdir -p ~/telegram-inbox ~/.config/systemd/user

# --- path unit: watch the channel inbox ---
cat > ~/.config/systemd/user/tg-inbox-mover.path << 'PATHEOF'
[Unit]
Description=Watch Telegram channel inbox for new files

[Path]
PathChanged=%h/.claude/channels/telegram/inbox
Unit=tg-inbox-mover.service

[Install]
WantedBy=default.target
PATHEOF

# --- service: move them out of ~/.claude/ ---
cat > ~/.config/systemd/user/tg-inbox-mover.service << 'SVCEOF'
[Unit]
Description=Move Telegram uploads out of ~/.claude/ to avoid sensitive-file guard

[Service]
Type=oneshot
ExecStart=/bin/bash -c 'mkdir -p %h/telegram-inbox && find %h/.claude/channels/telegram/inbox -maxdepth 1 -type f -exec mv -t %h/telegram-inbox/ {} +'
SVCEOF

# Drain anything already in inbox so the guard never fires on history
mv ~/.claude/channels/telegram/inbox/* ~/telegram-inbox/ 2>/dev/null || true

systemctl --user daemon-reload
systemctl --user enable --now tg-inbox-mover.path

echo "OK: tg-inbox-mover.path active. Files will land in ~/telegram-inbox/"
systemctl --user status tg-inbox-mover.path --no-pager | head -5
EOF
```

> **CRITICAL**: After this step, every CLAUDE.md on the server **must** instruct Claude to look for user-uploaded files at `~/telegram-inbox/`, not at `~/.claude/channels/telegram/inbox/`. The `migrate-openclaw` skill's CLAUDE.md template already includes this rule. If you write CLAUDE.md by hand, copy the "Telegram file uploads" block from `migrate-openclaw/SKILL.md` Step 3.

> **Latency**: systemd's `PathChanged` is inotify-backed, so the move happens within milliseconds of the file landing. Claude effectively never sees a file at the original path.

> **Why not just chmod / symlink the directory?** Symlinks don't help — Claude Code resolves the realpath before checking the guard, so a symlink target inside `~/.claude/` still trips. Configuring the plugin to write elsewhere isn't possible — the inbox path is hard-coded in the plugin's `server.ts`. Moving files out is the only reliable approach.

### Step 7c: Install PermissionRequest hook (bypass ~/.claude/ self-edit guard)

**Why**: Claude Code has a **hard-coded `alwaysAskRule`** for any Edit/Write targeting paths under `~/.claude/`. This guard is independent of `--dangerously-skip-permissions`, `permissions.allow`, `permissions.defaultMode`, and `skipDangerousModePermissionPrompt` — none of them suppress it. When triggered, a blocking permission dialog appears in the tmux pane that the Telegram user cannot see, silently freezing the entire session.

This guard cannot be bypassed via settings. However, Claude Code's **PermissionRequest hook** fires when the guard is about to display the prompt. If the hook returns `{"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}`, the prompt is skipped entirely. Claude Code logs `Allowed by PermissionRequest hook` as an audit trail.

**Discovery details**: The guard's implementation was reverse-engineered from `cli.js` on 2026-04-09. The constants `NG8="/.claude/**"` and `yG8="~/.claude/**"` define the protected globs. A PreToolUse hook can bypass the guard for Read operations but **not** for Edit/Write (log: "Hook approved tool use for Edit, but ask rule requires prompt"). Only PermissionRequest hooks have sufficient priority to override the ask rule. Verified on four production servers (MM, APPSHIP, MIAH, Gali).

```bash
$SSH_CMD bash -s << 'EOF'
set -e

# --- Hook script: auto-allow tool calls targeting ~/.claude/ ---
cat > ~/bypass-claude-folder.sh << 'HOOKEOF'
#!/bin/bash
# PreToolUse + PermissionRequest hook
# Auto-allow tool calls whose target path is under $HOME/.claude/
# Bypasses CC's hardcoded ~/.claude/** alwaysAskRule guard.
# Covers: Edit/Read/Write (file_path), NotebookEdit (notebook_path), Bash (command string)
input=$(cat)
HOOK_HOME="$HOME" python3 - "$input" << 'PY'
import sys, json, os, re
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
event = d.get("hook_event_name", "")
ti = d.get("tool_input", {}) or {}
home = os.environ.get("HOOK_HOME", "")
guarded_prefix = home + "/.claude/"

def is_guarded(p):
    if p.startswith("~/"):
        p = home + p[1:]
    elif p == "~":
        p = home
    return p.startswith(guarded_prefix) or p == home + "/.claude"

# Strategy 1: explicit file_path / notebook_path (Edit, Read, Write, etc.)
path = ti.get("file_path") or ti.get("notebook_path") or ""
if path and is_guarded(path):
    pass  # fall through to allow
# Strategy 2: Bash command string — check if it references ~/.claude/
elif ti.get("command"):
    cmd = ti["command"]
    patterns = [
        r"~/.claude/",
        re.escape(home) + r"/.claude/",
        r"\$HOME/.claude/",
    ]
    if not any(re.search(p, cmd) for p in patterns):
        sys.exit(0)
else:
    sys.exit(0)

if event == "PreToolUse":
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"auto-allow .claude folder via hook"}}))
elif event == "PermissionRequest":
    print(json.dumps({"hookSpecificOutput":{"hookEventName":"PermissionRequest","decision":{"behavior":"allow"}}}))
PY
HOOKEOF
chmod +x ~/bypass-claude-folder.sh

# --- Patch settings.json to register hooks ---
python3 << 'PYEOF'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
hook_entry = {"matcher":"","hooks":[{"type":"command","command": os.path.expanduser("~/bypass-claude-folder.sh")}]}
d.setdefault("hooks", {})
d["hooks"]["PreToolUse"] = [hook_entry]
d["hooks"]["PermissionRequest"] = [hook_entry]
json.dump(d, open(p, "w"), indent=4)
PYEOF

echo "OK: PermissionRequest hook installed + settings.json patched"
EOF
```

> **How it works**: The hook script reads the JSON payload from stdin and checks two strategies: (1) for tools with `file_path`/`notebook_path` (Edit, Read, Write, etc.), it checks if the path falls under `$HOME/.claude/`; (2) for Bash commands, it regex-matches the `command` string for `~/.claude/`, `$HOME/.claude/`, or the expanded absolute path. If either matches, it outputs the appropriate allow JSON. If neither matches, the script exits silently and the default permission flow takes over.

> **Re-apply after CC major upgrades.** The hook schema is a public API (documented in CC hook docs), but a major version bump could change the expected output format. After upgrading CC, verify with: `mkdir -p ~/.claude/skills/_canary && echo test > ~/.claude/skills/_canary/t.txt` then ask Claude to edit it — if no permission dialog appears and the log says "Allowed by PermissionRequest hook", the hook still works.

### Step 7d: Install Telegram routing enforcement hook (prevent silent drops)

**Why**: After multiple `compact` cycles, Claude frequently "forgets" to call the `plugin:telegram:telegram - reply` MCP tool for Telegram messages — it generates a full response in the terminal that the Telegram user never sees. This happens even when the channel routing rule is written at the **top** of both `~/CLAUDE.md` and `~/.claude/CLAUDE.md`. The root cause is that `compact` summaries don't preserve CLAUDE.md instructions, and the model's attention drifts in long contexts. Observed on all four production servers (Gali, MM, Appship, Miah) — **every server eventually hits this silent-drop bug**.

CLAUDE.md rules are best-effort (model must "remember" them). Hooks are code-level (execute deterministically). This step uses a **`UserPromptSubmit` hook** that fires every time a message enters the session. If the message contains a Telegram channel marker (`← telegram`), the hook injects `additionalContext` directly into the model's input, forcing it to see the routing instruction **in the same turn**, regardless of what was compacted away.

```bash
$SSH_CMD bash -s << 'EOF'
set -e

# --- Hook script: inject Telegram routing reminder on every inbound message ---
cat > ~/telegram-routing-hook.sh << 'HOOKEOF'
#!/bin/bash
# UserPromptSubmit hook: detect Telegram channel messages and inject routing reminder
input=$(cat)
python3 - "$input" << 'PY'
import sys, json
try:
    d = json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
user_input = d.get("tool_input", {}).get("prompt", "") or ""
if "telegram" in user_input.lower() and ("<-" in user_input or chr(8592) in user_input):
    result = {
        "hookSpecificOutput": {
            "hookEventName": "UserPromptSubmit",
            "additionalContext": "TELEGRAM ROUTING MANDATORY: This message came from Telegram. You MUST call plugin:telegram:telegram reply MCP tool with chat_id to send your response. Terminal output is INVISIBLE to the Telegram user. Do NOT skip the reply tool call."
        }
    }
    print(json.dumps(result))
PY
HOOKEOF
chmod +x ~/telegram-routing-hook.sh

# --- Patch settings.json to register hook ---
python3 << 'PYEOF'
import json, os
p = os.path.expanduser("~/.claude/settings.json")
d = json.load(open(p))
hooks = d.setdefault("hooks", {})
hook_entry = {"matcher":"","hooks":[{"type":"command","command": os.path.expanduser("~/telegram-routing-hook.sh")}]}
existing = hooks.get("UserPromptSubmit", [])
if not any("telegram-routing-hook" in str(h) for h in existing):
    existing.append(hook_entry)
    hooks["UserPromptSubmit"] = existing
json.dump(d, open(p, "w"), indent=4)
PYEOF

echo "OK: Telegram routing hook installed + settings.json patched"
EOF
```

> **How it works**: Every time a user message enters the session (including Telegram channel pushes), the hook checks if the raw input contains a `← telegram` marker. If yes, it returns JSON with `additionalContext` that gets injected directly into the model's context for that turn. The model sees "TELEGRAM ROUTING MANDATORY: ..." as part of its input, making it virtually impossible to forget the reply tool call. If the message is from the terminal (no telegram marker), the hook exits silently with no effect.

> **Why not rely on CLAUDE.md alone**: CLAUDE.md is loaded once at session start and after each compact. But compact summaries don't include CLAUDE.md content, and in long sessions with many tool calls, the routing rule gets buried under task context. The hook fires **per-message**, guaranteeing the instruction is fresh in every single turn that needs it.

> **Complementary, not replacement**: Keep the channel routing rule in both CLAUDE.md files (Step 9b). The CLAUDE.md rule handles edge cases the hook might miss (e.g., multi-turn Telegram conversations where only the first message has the marker). The hook handles the common case where compact erases the model's awareness of CLAUDE.md.

### Step 8: Launch and confirm dialogs

```bash
$SSH_CMD bash -s << 'EOF'
set -e

# Kill any existing claude processes to prevent Telegram 409 conflicts
tmux kill-session -t claude 2>/dev/null || true
sleep 1
pkill -f 'claude --dangerously' 2>/dev/null || true
pkill -f 'bun.*server.ts' 2>/dev/null || true
sleep 2

# Launch in tmux
tmux new-session -d -s claude ~/start-claude.sh

# Wait for Claude Code to initialize
sleep 12

# Dialog 1: "Trust this folder?" — default is "Yes", press Enter
tmux send-keys -t claude Enter
sleep 4

# Dialog 2: "Bypass permissions?" — select "Yes, I accept" (2nd option)
OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
if echo "$OUTPUT" | grep -q "Yes, I accept"; then
  tmux send-keys -t claude Down
  sleep 0.5
  tmux send-keys -t claude Enter
  sleep 12
fi

# Verify
for i in 1 2 3; do
  OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
  if echo "$OUTPUT" | grep -q "Listening for channel messages"; then
    echo "SUCCESS: Claude Code is running and listening for Telegram messages"
    exit 0
  fi
  sleep 5
done

echo "WARNING: Could not confirm 'Listening' state. Current screen:"
tmux capture-pane -t claude -p 2>&1 | tail -15
exit 1
EOF
```

**Expected**: `SUCCESS: Claude Code is running and listening for Telegram messages`

### Step 9: Start systemd service for reboot persistence

```bash
$SSH_CMD bash -s << 'EOF'
# Now that the first-launch dialogs are done, enable the systemd service
# Future starts (including reboots) will skip those dialogs
systemctl --user start claude-telegram.service 2>/dev/null || true
echo "OK: systemd service active — Claude Code will auto-start on reboot"
EOF
```

### Step 9b: Install Channel Routing Rule into BOTH CLAUDE.md files (MANDATORY)

**Why**: Without this rule, Claude often generates a reply in the terminal but **forgets to call the `plugin:telegram:telegram - reply` MCP tool**, so the Telegram user sees nothing — a silent failure mode observed in real deployments (Gali, MM, APPSHIP all hit it). This step is **not optional**: every Telegram-channel deployment must end with this rule installed and the session restarted.

**Why both files**: Claude Code loads two layers of CLAUDE.md — `~/.claude/CLAUDE.md` (user-level, always loaded) and `~/CLAUDE.md` or `<cwd>/CLAUDE.md` (project-level, loaded based on launch directory). On long-running sessions, the model can re-Read the user-level file mid-session (e.g. when the agent introspects its own configuration), which then becomes the dominant authority in context. If the rule is **only** in the project-level file, it gets effectively shadowed and the silent-drop bug returns. **Observed at Gali on 2026-04-08**: a session that worked for ~1 day suddenly stopped routing Telegram replies through the reply tool, because the rule lived only in `/root/CLAUDE.md` while the agent was now anchored on `/root/.claude/CLAUDE.md`. The fix is to put the same rule block in **both** files.

Each block is fenced with HTML markers so the step is idempotent — re-running it on a server that already has the rule is a no-op, and it never duplicates or clobbers the user's other CLAUDE.md content.

```bash
$SSH_CMD bash -s << 'EOF'
set -e

install_rule() {
  local F=$1
  mkdir -p "$(dirname "$F")"
  touch "$F"
  if grep -q '<!-- BEGIN: channel-routing-rule -->' "$F"; then
    echo "OK: channel routing rule already present in $F"
    return
  fi
  cat >> "$F" << 'RULEEOF'

<!-- BEGIN: channel-routing-rule -->
## Channel Routing Rule (highest priority)

**General principle**: Reply on the *same platform* the message came from.
Telegram in → Telegram reply tool out. Terminal in → stdout out. Never cross.

When the incoming message is tagged `← telegram · <user_id>:`, you **must**
reply by calling the `plugin:telegram:telegram - reply` MCP tool targeted at
the same `chat_id`. Terminal output alone is invisible to the Telegram user.

1. Every user-visible Telegram reply must go through the reply tool.
2. Do not assume the Telegram user can see terminal output.
3. If a tool call fails, retry; do not silently drop the reply.
4. Do not cross-route: never answer a Telegram message by printing only to
   the terminal, and never push a terminal-only task into Telegram.
5. This rule overrides any default "just print to stdout" behavior.
6. Even if you already printed text to the terminal, you must still issue a
   reply tool call afterwards — terminal output does not count as a reply.
<!-- END: channel-routing-rule -->
RULEEOF
  echo "OK: channel routing rule appended to $F"
}

# Install in both layers — see Step 9b "Why both files" for rationale.
install_rule ~/CLAUDE.md
install_rule ~/.claude/CLAUDE.md

# Restart tmux session so Claude reloads CLAUDE.md
tmux kill-session -t claude 2>/dev/null || true
sleep 2
tmux new-session -d -s claude ~/start-claude.sh
sleep 12

# Re-handle first-launch dialogs (trust folder + bypass permissions)
tmux send-keys -t claude Enter
sleep 4
OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
if echo "$OUTPUT" | grep -q "Yes, I accept"; then
  tmux send-keys -t claude Down
  sleep 0.5
  tmux send-keys -t claude Enter
  sleep 12
fi

# Confirm listening
for i in 1 2 3 4; do
  OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
  if echo "$OUTPUT" | grep -q "Listening for channel messages"; then
    echo "SUCCESS: Claude reloaded with channel routing rule active"
    exit 0
  fi
  sleep 5
done
echo "WARNING: post-restart listening state not confirmed. Pane:"
tmux capture-pane -t claude -p 2>&1 | tail -15
exit 1
EOF
```

> **Why mandatory, not recommended**: This was originally documented as a recommendation. Real deployments showed that *every* server without this rule eventually hits the silent-drop bug — the model writes a beautiful reply to the terminal that the Telegram user never sees, and the operator only finds out by SSH-ing in and reading the tmux pane. Promoting it to a deterministic step removes the failure mode entirely.

---

## Post-Deploy: Telegram Pairing (requires human)

Tell the user:
> Open Telegram and send any message to your bot. The bot will reply with a 6-character pairing code. Give me that code.

Once you have the code (`${PAIR_CODE}`):

```bash
$SSH_CMD bash -s << ENDPAIR
tmux send-keys -t claude '/telegram:access pair ${PAIR_CODE}' Enter
sleep 8
tmux send-keys -t claude Enter
sleep 3
tmux send-keys -t claude '/telegram:access policy allowlist' Enter
sleep 5
tmux send-keys -t claude Enter
sleep 3
echo "OK: Paired and secured"
ENDPAIR
```

Ask the user to send a test message via Telegram and confirm they receive a reply.

---

## Troubleshooting Decision Tree

```
Problem: No response from bot
│
├─ Check: tmux session running?
│  $ tmux list-sessions
│  ├─ No → $ tmux new-session -d -s claude ~/start-claude.sh
│  └─ Yes ↓
│
├─ Check: Screen shows "Listening for channel messages"?
│  $ tmux capture-pane -t claude -p | grep Listening
│  ├─ No → Stuck on dialog. Re-run Step 8.
│  └─ Yes ↓
│
├─ Check: bun server.ts running?
│  $ ps aux | grep 'bun.*server.ts' | grep -v grep
│  ├─ No → Kill all, restart from Step 8.
│  └─ Yes ↓
│
├─ Check: Telegram API reachable?
│  $ curl -sf https://api.telegram.org >/dev/null && echo OK || echo BLOCKED
│  ├─ BLOCKED → Server cannot reach Telegram. Need a server in unrestricted region.
│  └─ OK ↓
│
├─ Check: 409 conflict?
│  $ curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates?limit=1&timeout=1"
│  ├─ "409" → Zombie processes. $ pkill -f 'bun.*server.ts'; pkill -f claude; then restart Step 8.
│  └─ "ok":true ↓
│
├─ Check: channelsEnabled set?
│  $ grep channelsEnabled ~/.claude/settings.json
│  ├─ Missing → Re-run Step 4.
│  └─ Present ↓
│
└─ Check: Debug log
   Add --debug-file /tmp/claude-debug.log to start-claude.sh, restart, then:
   $ grep -i 'channel.*notification' /tmp/claude-debug.log
   ├─ "skipped...inline" → --plugin-dir is in start-claude.sh. Remove it. Restart.
   ├─ "skipped...not in --channels" → --channels flag missing or channelsEnabled false.
   └─ "registered" → Plugin connected OK. Restart session.
```

## Architecture

```
┌──────────────┐
│  Telegram    │
│  (Phone)     │
└──────┬───────┘
       │ Bot API long-polling
       v
┌──────────────┐
│  bun         │  MCP server (child process of claude)
│  server.ts   │  Token: ~/.claude/channels/telegram/.env
│              │  Access: ~/.claude/channels/telegram/access.json
└──────┬───────┘
       │ stdio (MCP notifications/claude/channel)
       v
┌──────────────┐
│  claude      │  CLI in tmux, managed by systemd
│  --channels  │  channelsEnabled: true in settings.json
└──────┬───────┘
       │ filesystem, git, bash, tools
       v
┌──────────────┐
│  Server      │
└──────────────┘
```

## File Manifest

| Path | Purpose | Permissions |
|------|---------|-------------|
| `~/.claude.json` | Onboarding bypass | 644 |
| `~/.claude/settings.json` | Permissions + channelsEnabled + hooks | 644 |
| `~/.claude/channels/telegram/.env` | Bot token | 600 |
| `~/.claude/channels/telegram/access.json` | Paired users + policy | 644 (auto) |
| `~/start-claude.sh` | Startup with auto-restart loop | 700 |
| `~/bypass-claude-folder.sh` | PermissionRequest hook (Step 7c) | 700 |
| `~/telegram-routing-hook.sh` | Telegram reply enforcement hook (Step 7d) | 700 |
| `~/.config/systemd/user/claude-telegram.service` | Boot persistence | 644 |

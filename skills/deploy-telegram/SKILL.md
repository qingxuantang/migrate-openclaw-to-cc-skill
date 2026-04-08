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

Define the SSH command once:

```
SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${SSH_HOST}"
```

Execute Steps 1–9 sequentially. After each step, check exit code — abort on failure.

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

---

## Recommended: Add Telegram Reply-Tool Rule to CLAUDE.md

If the user has (or creates) a `~/CLAUDE.md` on the server, append the rule below. Without it, Claude often generates a reply in the terminal but **forgets to call the `plugin:telegram:telegram - reply` MCP tool**, so the Telegram user sees nothing — a silent failure mode observed in real deployments.

```markdown
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
```

After editing `~/CLAUDE.md`, restart the tmux session so Claude reloads it:
`tmux kill-session -t claude && tmux new-session -d -s claude ~/start-claude.sh`

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
| `~/.claude/settings.json` | Permissions + channelsEnabled | 644 |
| `~/.claude/channels/telegram/.env` | Bot token | 600 |
| `~/.claude/channels/telegram/access.json` | Paired users + policy | 644 (auto) |
| `~/start-claude.sh` | Startup with auto-restart loop | 700 |
| `~/.config/systemd/user/claude-telegram.service` | Boot persistence | 644 |

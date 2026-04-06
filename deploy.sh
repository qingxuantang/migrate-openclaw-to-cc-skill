#!/bin/bash
# deploy.sh — Human-friendly wrapper for the deploy-telegram skill
# Usage: ./deploy.sh --host HOST --token BOT_TOKEN --claude-token TOKEN [--user USER] [--port PORT]

set -euo pipefail

# Defaults
SSH_USER="ubuntu"
SSH_PORT="22"
SSH_HOST=""
BOT_TOKEN=""
CLAUDE_TOKEN=""

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --host) SSH_HOST="$2"; shift 2 ;;
    --user) SSH_USER="$2"; shift 2 ;;
    --port) SSH_PORT="$2"; shift 2 ;;
    --token) BOT_TOKEN="$2"; shift 2 ;;
    --claude-token) CLAUDE_TOKEN="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 --host HOST --token BOT_TOKEN --claude-token CLAUDE_TOKEN [--user USER] [--port PORT]"
      echo ""
      echo "  --host          Server IP or hostname (required)"
      echo "  --token         Telegram bot token from @BotFather (required)"
      echo "  --claude-token  Claude OAuth token from 'claude setup-token' (required)"
      echo "  --user          SSH username (default: ubuntu)"
      echo "  --port          SSH port (default: 22)"
      exit 0
      ;;
    *) echo "Unknown option: $1"; exit 1 ;;
  esac
done

# Validate required params
[[ -z "$SSH_HOST" ]] && { echo "ERROR: --host is required"; exit 1; }
[[ -z "$BOT_TOKEN" ]] && { echo "ERROR: --token is required"; exit 1; }
[[ -z "$CLAUDE_TOKEN" ]] && { echo "ERROR: --claude-token is required"; exit 1; }

SSH_CMD="ssh -p ${SSH_PORT} -o StrictHostKeyChecking=no -o ConnectTimeout=15 ${SSH_USER}@${SSH_HOST}"

step() {
  echo ""
  echo "=========================================="
  echo "  Step $1: $2"
  echo "=========================================="
}

# --- Network Check ---
step 0 "Network requirements check"
$SSH_CMD bash -s << 'EOF'
echo "=== Network Check ==="
FAIL=0

curl -sf --max-time 10 "https://api.telegram.org" >/dev/null 2>&1 \
  && echo "PASS: api.telegram.org reachable" \
  || { echo "FAIL: api.telegram.org blocked"; FAIL=1; }

curl -sf --max-time 10 "https://github.com" >/dev/null 2>&1 \
  && echo "PASS: github.com reachable" \
  || { echo "FAIL: github.com blocked"; FAIL=1; }

curl -sf --max-time 10 "https://api.anthropic.com" >/dev/null 2>&1 \
  && echo "PASS: api.anthropic.com reachable" \
  || { echo "FAIL: api.anthropic.com blocked"; FAIL=1; }

[ $FAIL -eq 1 ] && { echo "FATAL: Network requirements not met. Use a server outside mainland China."; exit 1; }
echo "=== All checks passed ==="
EOF

# --- Step 1: Install Node.js ---
step 1 "Install Node.js (if missing)"
$SSH_CMD bash -s << 'EOF'
set -e
if command -v node >/dev/null 2>&1; then
  NODE_MAJOR=$(node --version | grep -oP '(?<=v)\d+')
  if [ "$NODE_MAJOR" -ge 20 ]; then
    echo "OK: Node.js $(node --version) already installed"
    exit 0
  fi
fi
echo "Installing Node.js 22..."
if command -v sudo >/dev/null 2>&1; then
  curl -fsSL https://deb.nodesource.com/setup_22.x | sudo -E bash - 2>&1 | tail -3
  sudo apt-get install -y nodejs 2>&1 | tail -3
else
  curl -fsSL https://deb.nodesource.com/setup_22.x | bash - 2>&1 | tail -3
  apt-get install -y nodejs 2>&1 | tail -3
fi
echo "INSTALLED: Node.js $(node --version)"
EOF

# --- Step 2: Install Claude Code, tmux, Bun ---
step 2 "Install Claude Code, tmux, and Bun"
$SSH_CMD bash -s << 'EOF'
set -e
if ! command -v claude >/dev/null 2>&1; then
  echo "Installing Claude Code..."
  if command -v sudo >/dev/null 2>&1; then
    sudo npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  else
    npm install -g @anthropic-ai/claude-code 2>&1 | tail -1
  fi
fi
echo "CLAUDE: $(claude --version)"

if ! command -v tmux >/dev/null 2>&1; then
  if command -v sudo >/dev/null 2>&1; then
    sudo apt-get update -qq && sudo apt-get install -y -qq tmux >/dev/null 2>&1
  else
    apt-get update -qq && apt-get install -y -qq tmux >/dev/null 2>&1
  fi
fi
echo "TMUX: $(tmux -V)"

if [ ! -f "$HOME/.bun/bin/bun" ]; then
  curl -fsSL https://bun.sh/install | bash 2>&1 | tail -1
fi
echo "BUN: $($HOME/.bun/bin/bun --version)"
EOF

# --- Step 3: Configure authentication ---
step 3 "Configure authentication"
$SSH_CMD bash -s << ENDAUTH
set -e
cat > ~/.claude.json << 'CJSON'
{
  "hasCompletedOnboarding": true,
  "hasAcknowledgedCostThreshold": true
}
CJSON

RESULT=\$(CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}' claude auth status 2>&1)
echo "\$RESULT"
echo "\$RESULT" | grep -q '"loggedIn": true' || { echo "FATAL: Auth failed"; exit 1; }
echo "OK: Auth verified"
ENDAUTH

# --- Step 4: Write settings ---
step 4 "Write settings"
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
    "deny": []
  },
  "channelsEnabled": true,
  "skipDangerousModePermissionPrompt": true
}
SETTINGS
echo "OK: settings.json written"
EOF

# --- Step 5: Install Telegram plugin ---
step 5 "Install Telegram plugin"
$SSH_CMD bash -s << ENDPLUGIN
set -e
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"

claude plugin marketplace add anthropics/claude-plugins-official 2>&1 || true
claude plugin marketplace update claude-plugins-official 2>&1 | tail -1
claude plugin uninstall telegram@claude-plugins-official 2>/dev/null || true
claude plugin install telegram@claude-plugins-official 2>&1 | tail -1

claude plugin list 2>&1 | grep -q telegram || { echo "FATAL: Plugin install failed"; exit 1; }
echo "OK: telegram plugin installed"
ENDPLUGIN

# --- Step 6: Configure bot token ---
step 6 "Configure bot token"
$SSH_CMD bash -s << ENDBOT
set -e
mkdir -p ~/.claude/channels/telegram
echo "TELEGRAM_BOT_TOKEN=${BOT_TOKEN}" > ~/.claude/channels/telegram/.env
chmod 600 ~/.claude/channels/telegram/.env
echo "OK: bot token configured"
ENDBOT

# --- Step 7: Create startup script and systemd service ---
step 7 "Create startup script and systemd service"
$SSH_CMD bash -s << ENDSETUP
set -e

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

sudo loginctl enable-linger \$(whoami) 2>/dev/null || loginctl enable-linger \$(whoami) 2>/dev/null || true
systemctl --user daemon-reload
systemctl --user enable claude-telegram.service
echo "OK: startup script + systemd service created"
ENDSETUP

# --- Step 8: Launch and confirm ---
step 8 "Launch and confirm dialogs"
$SSH_CMD bash -s << 'EOF'
set -e
tmux kill-session -t claude 2>/dev/null || true
sleep 1
pkill -f 'claude --dangerously' 2>/dev/null || true
pkill -f 'bun.*server.ts' 2>/dev/null || true
sleep 2

tmux new-session -d -s claude ~/start-claude.sh
sleep 12

# Dialog 1: Trust folder
tmux send-keys -t claude Enter
sleep 4

# Dialog 2: Bypass permissions
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

echo "WARNING: Could not confirm 'Listening' state"
tmux capture-pane -t claude -p 2>&1 | tail -15
exit 1
EOF

# --- Step 9: Enable systemd service ---
step 9 "Start systemd service for reboot persistence"
$SSH_CMD bash -s << 'EOF'
systemctl --user start claude-telegram.service 2>/dev/null || true
echo "OK: systemd service active"
EOF

echo ""
echo "=========================================="
echo "  DEPLOYMENT COMPLETE"
echo "=========================================="
echo ""
echo "Next step: Open Telegram and message your bot."
echo "The bot will reply with a 6-character pairing code."
echo "Then run:"
echo "  $SSH_CMD bash -c \"tmux send-keys -t claude '/telegram:access pair CODE' Enter\""

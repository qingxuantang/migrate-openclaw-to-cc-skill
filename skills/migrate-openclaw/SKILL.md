---
name: migrate-openclaw
description: Migrate OpenClaw skills, agents, workspace identity, and memory to Claude Code format AND deploy them so Claude Code actually picks them up on next launch. Handles the full OpenClaw agent structure — SOUL.md, AGENTS.md, IDENTITY.md, memory files, skills, env vars, and model config. Agent-executable with deterministic steps and explicit automation-vs-manual tags.
disable-model-invocation: false
---

# Agent Runbook: Migrate OpenClaw → Claude Code

## Context

As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. This skill performs a **complete** migration of an OpenClaw agent to Claude Code — not just file conversion, but also the physical deployment into `~/.claude/` and (optionally) launching Claude Code in tmux with the Telegram channel attached.

> **Do NOT stop OpenClaw during migration.** The typical workflow is to run OpenClaw and Claude Code in parallel (dual-track) for a while. This skill never touches the running OpenClaw process or its cron jobs.

## Execution Policy Legend

Every step below is tagged with one of these labels. Agents must respect them.

| Tag | Meaning |
|-----|---------|
| 🤖 **AUTO** | Execute automatically without asking. |
| 🟡 **AUTO-FIRST** | Attempt automatically; if the environment blocks automation (e.g. no write permission, missing `tmux`), print the exact commands for the user to run manually. |
| 👤 **MANUAL** | Prepare commands and hand them to the user. Do not attempt to run interactively — these require credentials only the human has. |
| 🚫 **DO NOT** | Never do this. |

## How OpenClaw is Actually Structured

Before migrating, understand what you're working with. A real OpenClaw installation looks like this:

```
~/.openclaw/
├── openclaw.json              # Global config: env vars, auth, models, plugins (MCP), agent defaults, hooks
├── agents/
│   └── {agent-name}/
│       ├── agent/
│       │   ├── agent.yaml     # Model config: "model:\n  primary: provider/model-id"
│       │   ├── auth-profiles.json
│       │   └── models.json
│       └── sessions/          # Session history — NOT migrated (ephemeral)
├── memory/
│   └── {agent-name}.sqlite    # Vector/FTS index built from workspace memory files — NOT migrated directly
├── skills/                    # Global skills (same SKILL.md format as Claude Code)
│   └── {skill-name}/
│       ├── SKILL.md
│       ├── references/
│       └── assets/
└── workspace/                 # The actual agent "home" — most important directory
    ├── SOUL.md        # Personality, behavior rules, user isolation → maps to CLAUDE.md
    ├── AGENTS.md      # Session startup instructions, workspace rules → maps to CLAUDE.md
    ├── IDENTITY.md    # Agent name, persona, avatar → merge into CLAUDE.md
    ├── TOOLS.md       # Environment-specific notes → merge into CLAUDE.md
    ├── HEARTBEAT.md   # Periodic status summaries (keep as reference)
    ├── MEMORY.md      # Long-term memory index → convert to Claude Code memory format
    ├── memory/
    │   └── YYYY-MM-DD.md  # Daily memory logs (plain markdown, no frontmatter)
    └── skills/            # Agent-local inline skills (*.skill files or subdirs)
```

There may also be `workspace-{agent-name}/` directories for secondary agents (e.g. `workspace-work/`).

## Compatibility Matrix

| OpenClaw Component | Claude Code Equivalent | Migration Complexity |
|-------------------|----------------------|---------------------|
| `workspace/SOUL.md` | `CLAUDE.md` | **Merge** — primary content block |
| `workspace/AGENTS.md` | `CLAUDE.md` | **Merge** — session startup section |
| `workspace/IDENTITY.md` | `CLAUDE.md` section | **Merge** — persona section |
| `workspace/TOOLS.md` | `CLAUDE.md` section | **Merge** — environment notes |
| `workspace/MEMORY.md` | `~/.claude/projects/.../memory/MEMORY.md` + typed files | **Convert** — parse sections into typed memory files |
| `workspace/memory/*.md` | `~/.claude/projects/.../memory/archive/` | **Copy as reference** — not directly loadable |
| `skills/*/SKILL.md` | `~/.claude/skills/*/SKILL.md` | **Direct copy** — identical format |
| `workspace/skills/` | `~/.claude/skills/` | **Direct copy** |
| `openclaw.json` → `env` | `~/.claude/settings.json` → `env` | **Direct copy** |
| `agents/{name}/agent/agent.yaml` | `~/.claude/settings.json` → `model` | **Format convert** |
| `openclaw.json` → `plugins` | `~/.claude/settings.json` → `mcpServers` | **Manual** — different schema |
| `agents/{name}/sessions/` | Not applicable | **Skip** — session history is ephemeral |
| `memory/*.sqlite` | Not applicable | **Skip** — rebuilt automatically from memory files |
| Cron jobs | Not applicable | **Skip** — OpenClaw crons keep running untouched |

## Contract

**Required input** (collect before starting):

| Parameter | Format | Example | Notes |
|-----------|--------|---------|-------|
| `OPENCLAW_DIR` | absolute path | `/home/ubuntu/.openclaw` | |
| `TARGET_DIR` | absolute path | `/home/ubuntu/claude-migration` | Staging directory |
| `AGENT_NAME` | agent name | `main` (default) or `work` | Picks `agents/{name}/` and `workspace/` or `workspace-{name}/` |
| `CLAUDE_HOME` | absolute path | `~/.claude` | Almost always `~/.claude` |
| `CWD_FOR_MEMORY` | absolute path | `/home/ubuntu` or `/root` | The directory Claude Code will be launched from — used to compute the project-level memory path |

**Optional input** (only needed for Steps 10-12: creating the startup script and launching in tmux):

| Parameter | Format | How to obtain |
|-----------|--------|---------------|
| `CLAUDE_OAUTH_TOKEN` | `sk-ant-oat01-...` | From `claude setup-token` on a machine with a browser |
| `TELEGRAM_BOT_TOKEN` | `<bot_id>:<hash>` | From @BotFather — **must be a fresh bot, not the one OpenClaw uses** |

> ⚠️ **Tokens are secrets.** Never echo them back to the user in full, never write them into committed files, and never log them to stdout outside the exact `export` lines that need them.

### Computing the memory path

Claude Code stores project-level memory at `~/.claude/projects/<cwd-slug>/memory/`, where `<cwd-slug>` is the launch cwd with `/` replaced by `-`. Examples:

| `CWD_FOR_MEMORY` | `<cwd-slug>` | Memory path |
|------------------|--------------|-------------|
| `/root` | `-root` | `~/.claude/projects/-root/memory/` |
| `/home/ubuntu` | `-home-ubuntu` | `~/.claude/projects/-home-ubuntu/memory/` |

---

## 🚫 Do Not Do (read this first)

1. **Do NOT stop OpenClaw.** The user wants dual-track. Never `systemctl stop openclaw`, `pkill openclaw`, or delete `~/.openclaw`.
2. **Do NOT re-create OpenClaw cron jobs in Claude Code.** Existing crons still run on the OpenClaw side; duplicating them causes double execution.
3. **Do NOT reuse OpenClaw's Telegram bot token.** Claude Code must use a fresh bot from @BotFather. Sharing a token causes Telegram 409 Conflict errors (two processes long-polling the same bot).
4. **Do NOT write tokens into files under git control** (SKILL.md, README.md, committed configs). Only `start-claude.sh` (chmod 700) should contain them at rest.
5. **Do NOT attempt to migrate `memory/main.sqlite`.** Claude Code has no vector store; the text-based memory files cover what matters.
6. **Do NOT skip `--channels plugin:telegram@claude-plugins-official`** in the startup command. Without this flag, the Bun MCP server never starts and Telegram messages are silently dropped.
7. **Do NOT combine `--plugin-dir` with `--channels`.** They produce an "inline source mismatch" and messages are dropped.

---

## Execution

### Step 1 — 🤖 AUTO: Inventory OpenClaw structure

```bash
echo "=== OpenClaw Inventory for agent: ${AGENT_NAME} ==="
echo ""

# Determine workspace path
if [ "${AGENT_NAME}" = "main" ]; then
  WORKSPACE="${OPENCLAW_DIR}/workspace"
else
  WORKSPACE="${OPENCLAW_DIR}/workspace-${AGENT_NAME}"
  [ -d "$WORKSPACE" ] || WORKSPACE="${OPENCLAW_DIR}/workspace"
fi
echo "Workspace: $WORKSPACE"
[ -d "$WORKSPACE" ] && echo "  Status: FOUND" || echo "  Status: NOT FOUND — check AGENT_NAME and OPENCLAW_DIR"

# Core identity files
for f in SOUL.md AGENTS.md IDENTITY.md TOOLS.md MEMORY.md; do
  [ -f "${WORKSPACE}/${f}" ] && echo "  ${f}: FOUND" || echo "  ${f}: not found"
done

# Memory files
MEMORY_COUNT=$(find "${WORKSPACE}/memory" -name "*.md" 2>/dev/null | wc -l)
echo "  Daily memory files: ${MEMORY_COUNT}"

# Skills
SKILL_COUNT=$(find "${OPENCLAW_DIR}/skills" -name "SKILL.md" 2>/dev/null | wc -l)
echo ""
echo "Global skills: ${SKILL_COUNT}"
find "${OPENCLAW_DIR}/skills" -name "SKILL.md" 2>/dev/null | while read f; do
  echo "  - $(basename $(dirname $f))"
done

# Agent config
AGENT_YAML="${OPENCLAW_DIR}/agents/${AGENT_NAME}/agent/agent.yaml"
[ -f "$AGENT_YAML" ] && echo "" && echo "Agent model config: FOUND" && echo "  $(cat $AGENT_YAML)" || echo "Agent model config: not found"

# Env vars in openclaw.json
if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
  ENV_KEYS=$(python3 -c "import json; d=json.load(open('${OPENCLAW_DIR}/openclaw.json')); print('\n'.join(d.get('env',{}).keys()))" 2>/dev/null)
  if [ -n "$ENV_KEYS" ]; then
    echo ""
    echo "Environment variables in openclaw.json:"
    echo "$ENV_KEYS" | while read k; do echo "  - $k"; done
  fi
fi

echo ""
echo "=== End Inventory ==="
```

**Halt if workspace is not found.** The workspace is the core of an OpenClaw agent. Without it, there is nothing meaningful to migrate. Ask the user to verify `OPENCLAW_DIR` and `AGENT_NAME`.

### Step 2 — 🤖 AUTO: Create migration directory structure

```bash
mkdir -p "${TARGET_DIR}/skills"
mkdir -p "${TARGET_DIR}/memory"
echo "OK: target directories created at ${TARGET_DIR}"
```

### Step 3 — 🤖 AUTO: Merge workspace identity files → CLAUDE.md

This is the most important step. OpenClaw agents have their identity spread across `SOUL.md`, `AGENTS.md`, `IDENTITY.md`, and `TOOLS.md`. These all map to Claude Code's `CLAUDE.md`.

Read each source file that exists, then write a merged CLAUDE.md:

```
Source priority order:
1. SOUL.md      → leads the file (personality + behavior)
2. AGENTS.md    → session startup rules and workspace instructions
3. IDENTITY.md  → name and persona (short section)
4. TOOLS.md     → environment-specific notes (short section)
```

Do NOT blindly concatenate them. Synthesize them:
- Merge any duplicate concepts (both files may define memory startup behavior — keep one clear version)
- Remove OpenClaw-specific mechanics that don't apply to Claude Code (e.g. references to OpenClaw session startup commands, WhatsApp bindings if not relevant)
- Preserve user isolation rules, behavior rules, persona, and any project-specific context verbatim

Write the merged result to `${TARGET_DIR}/CLAUDE.md`.

**Mandatory addition at the end of CLAUDE.md** — append this rule verbatim. It fixes a real bug observed in production where Claude Code, inside a Telegram channel session, would write replies to its terminal instead of calling the telegram reply MCP tool (so users never received them):

```markdown
---

## Channel Routing 强制规则（最高优先级 / Highest Priority）

**General principle**: Always reply on the **same platform** the message came from. If a user messages you from Telegram, reply via the Telegram reply tool; if from Slack, use the Slack reply tool; if from the local terminal, stdout is fine. Never cross platforms and never assume terminal output is visible to a remote user.

### Telegram channel

When a message arrives via the Telegram channel (you see `← telegram · <user_id>:` in your input), you **MUST** reply by calling the `plugin:telegram:telegram - reply` MCP tool. Terminal text output is **NOT** delivered to the Telegram user — only explicit tool calls are.

Rules:
1. Every Telegram user message must be followed by at least one `plugin:telegram:telegram - reply` tool call targeted at the same `chat_id` that sent it.
2. Do not assume follow-up replies in the same session send automatically. Each new user message needs its own explicit reply call.
3. Markdown/text written to the terminal is invisible to the user unless passed through the reply tool.
4. If the reply tool call fails, retry — do not silently drop the reply.
5. The task is not complete until the reply tool has been called successfully.
6. Do not cross-route: never answer a Telegram message by printing to the terminal only, and never answer a terminal prompt by pushing it to Telegram.
```

After writing, print:
```
OK: CLAUDE.md written — review before deploying to ~/.claude/CLAUDE.md
```

**Important:** If SOUL.md references specific file paths like `/home/ubuntu/.openclaw/workspace/`, note them in the migration report but do NOT auto-change them — the user may want to keep using the same workspace.

### Step 4 — 🤖 AUTO: Migrate memory

OpenClaw memory lives in two forms:
1. `MEMORY.md` — a curated long-term memory document (structured markdown with named sections)
2. `memory/YYYY-MM-DD.md` — raw daily logs (plain markdown, no frontmatter)

Claude Code's memory system uses typed files with YAML frontmatter:
```markdown
---
name: memory name
description: one-line description for relevance matching
type: user | feedback | project | reference
---
Content here
```

And a `MEMORY.md` index file with one-line pointers:
```markdown
- [Title](file.md) — one-line hook
```

**Migrating MEMORY.md:**

Read `${WORKSPACE}/MEMORY.md`. Parse its top-level sections (e.g. `## People`, `## Work Principles`, `## Key Facts`, `## Server Infrastructure`). For each section, determine the best Claude Code memory type:

| Section type | Claude Code type |
|-------------|-----------------|
| People, relationships, user profile | `user` |
| Rules, preferences, how to behave | `feedback` |
| Ongoing projects, goals, context | `project` |
| External systems, URLs, tools | `reference` |

Create one memory file per meaningful section in `${TARGET_DIR}/memory/`. Name files descriptively (e.g. `user_profile.md`, `project_main.md`, `feedback_work_rules.md`, `reference_server_infra.md`).

Write `${TARGET_DIR}/memory/MEMORY.md` as the Claude Code index.

**Migrating daily memory files:**

Daily files (`memory/YYYY-MM-DD.md`) are raw session logs — not directly importable into Claude Code's typed memory system. Copy them as-is to `${TARGET_DIR}/memory/archive/` for reference. They can be manually reviewed for important facts worth extracting into typed memory files.

```bash
if [ -d "${WORKSPACE}/memory" ]; then
  mkdir -p "${TARGET_DIR}/memory/archive"
  cp "${WORKSPACE}"/memory/*.md "${TARGET_DIR}/memory/archive/" 2>/dev/null
  cp "${WORKSPACE}"/memory/*.json "${TARGET_DIR}/memory/archive/" 2>/dev/null
  ARCHIVE_COUNT=$(ls "${TARGET_DIR}/memory/archive/" 2>/dev/null | wc -l)
  echo "OK: ${ARCHIVE_COUNT} daily memory files copied to archive/"
fi
```

### Step 5 — 🤖 AUTO: Migrate skills (direct copy)

```bash
if [ -d "${OPENCLAW_DIR}/skills" ]; then
  find "${OPENCLAW_DIR}/skills" -name "SKILL.md" | while read skill_md; do
    src=$(dirname "$skill_md")
    SKILL_NAME=$(basename "$src")
    dest="${TARGET_DIR}/skills/${SKILL_NAME}"

    if [ -d "$dest" ]; then
      echo "SKIP: ${SKILL_NAME} — already exists"
      continue
    fi

    cp -r "$src" "$dest"
    echo "COPIED: ${SKILL_NAME}"
  done
else
  echo "SKIP: no global skills directory"
fi

# Also check workspace-local skills
if [ -d "${WORKSPACE}/skills" ]; then
  cp -r "${WORKSPACE}/skills/"* "${TARGET_DIR}/skills/" 2>/dev/null
  echo "OK: workspace-local skills copied"
fi
```

### Step 6 — 🤖 AUTO: Extract environment variables and model config

**Env vars from openclaw.json:**

```bash
if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
  ENV_JSON=$(python3 -c "
import json
d = json.load(open('${OPENCLAW_DIR}/openclaw.json'))
env = d.get('env', {})
if env:
    print(json.dumps({'env': env}, indent=2))
else:
    print('{}')
" 2>/dev/null)

  if [ "$ENV_JSON" != "{}" ] && [ -n "$ENV_JSON" ]; then
    echo "$ENV_JSON" > "${TARGET_DIR}/env_for_settings.json"
    echo "OK: env vars extracted to env_for_settings.json"
    echo "    Merge this into ~/.claude/settings.json under the 'env' key"
  fi
fi
```

**Model config from agent.yaml:**

```bash
AGENT_YAML="${OPENCLAW_DIR}/agents/${AGENT_NAME}/agent/agent.yaml"
if [ -f "$AGENT_YAML" ]; then
  # agent.yaml format: "model:\n  primary: provider/model-id"
  # Claude Code settings.json format: "model": "model-id" (no provider prefix for Anthropic)
  PRIMARY_MODEL=$(grep 'primary:' "$AGENT_YAML" | sed 's/.*primary: *//' | tr -d '"')

  # Strip provider prefix if it's anthropic/ — Claude Code uses bare model IDs for Anthropic
  CC_MODEL=$(echo "$PRIMARY_MODEL" | sed 's|^anthropic/||')

  echo "OpenClaw model: $PRIMARY_MODEL"
  echo "Claude Code model: $CC_MODEL"
  echo ""
  echo "Add to ~/.claude/settings.json:"
  echo "  \"model\": \"${CC_MODEL}\""
fi
```

### Step 7 — 🤖 AUTO: MCP / plugins migration guidance

OpenClaw's built-in plugins (`openclaw.json` → `plugins.entries`) are **not** MCP servers — they are native OpenClaw integrations. They do not have a direct auto-migration path to Claude Code.

```bash
if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
  PLUGINS=$(python3 -c "
import json
d = json.load(open('${OPENCLAW_DIR}/openclaw.json'))
plugins = d.get('plugins', {}).get('entries', {})
enabled = [k for k,v in plugins.items() if v.get('enabled')]
print('\n'.join(enabled))
" 2>/dev/null)

  if [ -n "$PLUGINS" ]; then
    echo "Enabled OpenClaw plugins detected:"
    echo "$PLUGINS" | while read p; do echo "  - $p"; done
    echo ""
    echo "Migration path for each:"
  fi
fi
```

For each detected plugin, provide this guidance:

**`telegram`** → Use the `deploy-telegram` skill in this repo. It sets up Claude Code with persistent Telegram access via a tmux session and MCP bot server. This is the full replacement. **Note**: use a *new* bot token from @BotFather, not the one OpenClaw is currently using.

**`duckduckgo`** (web search) → Claude Code has built-in WebSearch and WebFetch tools. No MCP server needed. Remove any explicit duckduckgo configuration.

**Any other plugin** → Check if a Claude Code MCP server equivalent exists. If OpenClaw had custom MCP server configs (separate from plugins), copy them to `${TARGET_DIR}/mcp_reference.json` for manual review and conversion to Claude Code's `mcpServers` schema in `settings.json`.

### Step 8 — 🤖 AUTO: Generate staged migration report

```bash
REPORT="${TARGET_DIR}/MIGRATION_REPORT.md"

cat > "$REPORT" << REPORTEOF
# OpenClaw → Claude Code Migration Report

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Agent: ${AGENT_NAME}
Source: ${OPENCLAW_DIR}
Target (staging): ${TARGET_DIR}

## Files Staged

| File | Purpose | Deploy to |
|------|---------|-----------|
| \`CLAUDE.md\` | Agent identity (SOUL + AGENTS + IDENTITY merged) + Telegram Channel rule | \`~/CLAUDE.md\` or \`~/.claude/CLAUDE.md\` |
| \`memory/MEMORY.md\` | Memory index | \`~/.claude/projects/<cwd-slug>/memory/MEMORY.md\` |
| \`memory/*.md\` | Typed long-term memory files | \`~/.claude/projects/<cwd-slug>/memory/\` |
| \`memory/archive/\` | Daily memory logs (for reference) | Review manually, do not deploy directly |
| \`skills/\` | All migrated skills | \`~/.claude/skills/\` |
| \`env_for_settings.json\` | Env vars to merge into settings | Merge into \`~/.claude/settings.json\` |

## What Was NOT Migrated (and Why)

| Component | Reason |
|-----------|--------|
| \`agents/*/sessions/\` | Session history is ephemeral — no equivalent concept |
| \`memory/*.sqlite\` | Vector index is rebuilt automatically from markdown files |
| OpenClaw plugins | Not MCP servers — see plugin guidance above |
| Auth profiles | Auth tokens are account-specific — set up fresh in Claude Code |
| Cron jobs | Still run on OpenClaw side — duplicating them causes double execution |

## Known Behavior Differences

| Feature | OpenClaw | Claude Code |
|---------|----------|-------------|
| Session startup | AGENTS.md defines explicit startup sequence | CLAUDE.md loaded automatically |
| Memory scope | Per-agent workspace isolation | Per-project directory isolation |
| Memory format | Plain markdown daily files + rich MEMORY.md | Typed frontmatter files + simple index |
| Model config | Per-agent agent.yaml | Global/project settings.json |
| Telegram | Native built-in plugin | External MCP server via deploy-telegram skill |
| Web search | duckduckgo plugin | Built-in WebSearch tool |
| Secondary agents | workspace-{name}/ directories | Separate Claude Code projects or sub-agents |

REPORTEOF

echo "OK: staging report written to ${REPORT}"
```

---

### Step 9 — 🤖 AUTO: Deploy staged files to `~/.claude/`

> This is the step that was missing in the v1 of this skill. Staging alone does nothing — files have to physically land where Claude Code looks for them.

```bash
# Compute memory destination from CWD_FOR_MEMORY
CWD_SLUG=$(echo "${CWD_FOR_MEMORY}" | sed 's|/|-|g')
MEM_DEST="${CLAUDE_HOME}/projects/${CWD_SLUG}/memory"
SKILL_DEST="${CLAUDE_HOME}/skills"

mkdir -p "${MEM_DEST}" "${SKILL_DEST}"

# 1. CLAUDE.md → ~/CLAUDE.md (home-level, loaded on every session)
cp "${TARGET_DIR}/CLAUDE.md" "${HOME}/CLAUDE.md"
echo "DEPLOYED: ~/CLAUDE.md ($(wc -l < "${HOME}/CLAUDE.md") lines)"

# 2. Memory files (both typed files and archive)
cp "${TARGET_DIR}/memory/"*.md "${MEM_DEST}/" 2>/dev/null
if [ -d "${TARGET_DIR}/memory/archive" ]; then
  mkdir -p "${MEM_DEST}/archive"
  cp "${TARGET_DIR}/memory/archive/"* "${MEM_DEST}/archive/" 2>/dev/null
fi
echo "DEPLOYED memory → ${MEM_DEST}"

# 3. Skills
for skill_dir in "${TARGET_DIR}/skills"/*/; do
  [ -d "$skill_dir" ] || continue
  SNAME=$(basename "$skill_dir")
  DEST="${SKILL_DEST}/${SNAME}"
  if [ -d "$DEST" ]; then
    echo "SKIP skill: ${SNAME} (already exists at destination)"
  else
    cp -r "$skill_dir" "$DEST"
    echo "DEPLOYED skill: ${SNAME}"
  fi
done

# 4. env_for_settings.json — show instructions only (do not auto-merge JSON)
if [ -f "${TARGET_DIR}/env_for_settings.json" ]; then
  echo ""
  echo "MANUAL: merge the contents of ${TARGET_DIR}/env_for_settings.json"
  echo "        into ${CLAUDE_HOME}/settings.json under the 'env' key"
fi
```

**Verification**:
```bash
test -f "${HOME}/CLAUDE.md" && echo "✓ CLAUDE.md" || echo "✗ CLAUDE.md MISSING"
ls "${MEM_DEST}" 2>/dev/null | head -5
ls -d "${CLAUDE_HOME}/skills/"*/ 2>/dev/null
```

### Step 10 — 🟡 AUTO-FIRST: Ensure Node.js / NVM is on PATH

Claude Code is usually installed under a Node version manager, and `claude` won't be found in non-interactive shells unless NVM is sourced from `.bashrc`.

```bash
if ! command -v claude >/dev/null 2>&1; then
  if [ -d "${HOME}/.nvm" ] && ! grep -q 'NVM_DIR' "${HOME}/.bashrc" 2>/dev/null; then
    cat >> "${HOME}/.bashrc" << 'NVMEOF'

# Added by migrate-openclaw skill
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
NVMEOF
    echo "OK: NVM added to ~/.bashrc — user must 'source ~/.bashrc' or open a new shell"
  fi
fi
```

**Fallback (if you can't write to bashrc):** show the user the exact three lines to append manually.

### Step 10b — 🤖 AUTO: Patch Telegram plugin to disable channel permission relay

**Skip this step if the user is not using the Telegram channel** (no `TELEGRAM_BOT_TOKEN`).

**Why**: As of Claude Code 2.1.92, the official Telegram plugin's `server.ts` declares an opt-in capability `'claude/channel/permission': {}`. When declared, Claude Code relays every tool-call permission prompt (Edit/Write/Bash/…) from channel sessions to Telegram as an Allow/Deny button card. This check is **independent of**:

- `--dangerously-skip-permissions` (terminal-only)
- `permissions.allow` in `settings.json` (terminal-only)
- `skipDangerousModePermissionPrompt: true` (terminal-only)

So even with all bypasses on, a migrated OpenClaw agent running over Telegram gets spammed with permission cards on every single tool call — a regression from the OpenClaw experience where the user never saw these prompts.

The fix: comment out the single capability declaration line. Channel sessions then fall back to the terminal permission flow, which the bypass flags correctly handle.

```bash
ssh ${SSH_USER}@${SSH_HOST} -p ${SSH_PORT} bash -s << 'EOF'
set -e
F=$HOME/.claude/plugins/marketplaces/claude-plugins-official/external_plugins/telegram/server.ts
if [ ! -f "$F" ]; then
  echo "FATAL: telegram plugin server.ts not found at $F — install the plugin first."; exit 1
fi
# Preserve original on first patch
[ ! -f "$F.bak" ] && cp "$F" "$F.bak"
sed -i "s|'claude/channel/permission': {},|// 'claude/channel/permission': {}, // DISABLED: relays tool prompts to TG despite --dangerously-skip-permissions|" "$F"
grep -q "^ *// 'claude/channel/permission'" "$F" \
  && echo "OK: channel permission relay disabled" \
  || { echo "WARNING: patch did not apply — plugin upstream may have changed. Inspect $F manually."; exit 1; }
EOF
```

> **Re-apply after plugin updates.** `claude plugin marketplace update` or a reinstall will overwrite `server.ts`. Re-run this step whenever the plugin is updated. A `.bak` copy is preserved on first run.
>
> **If running as root** (e.g. Gali-style deployments), the path is `/root/.claude/...` and the command above still works because `$HOME` is `/root` for root.

### Step 11 — 🟡 AUTO-FIRST: Create the startup script with tokens

**Skip this step if `CLAUDE_OAUTH_TOKEN` or `TELEGRAM_BOT_TOKEN` is not provided** — that means the user is only doing a file migration, not a full launch.

Do **not** write tokens into any file that might be committed. Put them in a `chmod 700` script only readable by the owner.

```bash
cat > "${HOME}/start-claude.sh" << STARTEOF
#!/bin/bash
export CLAUDE_CODE_OAUTH_TOKEN='${CLAUDE_OAUTH_TOKEN}'
export TELEGRAM_BOT_TOKEN='${TELEGRAM_BOT_TOKEN}'
export PATH="\$HOME/.bun/bin:\$PATH"
# If NVM is used, source it so 'claude' is on PATH
[ -s "\$HOME/.nvm/nvm.sh" ] && \. "\$HOME/.nvm/nvm.sh"
cd "${CWD_FOR_MEMORY}"
while true; do
  claude --dangerously-skip-permissions \
    --channels plugin:telegram@claude-plugins-official
  echo "Claude exited. Restarting in 3s..."
  sleep 3
done
STARTEOF
chmod 700 "${HOME}/start-claude.sh"
echo "OK: ~/start-claude.sh staged (chmod 700)"
```

### Step 12 — 🟡 AUTO-FIRST: Launch in tmux

**Skip if no `start-claude.sh` from Step 11.** Claude Code must run inside a detached tmux session, otherwise it dies when SSH disconnects.

```bash
# Clean any stale session / zombie processes
tmux kill-session -t claude 2>/dev/null || true
pkill -f 'claude --dangerously' 2>/dev/null || true
pkill -f 'bun.*server.ts' 2>/dev/null || true
sleep 2

# Launch detached
tmux new-session -d -s claude "${HOME}/start-claude.sh"
sleep 12

# Handle first-run "Trust this folder" dialog
tmux send-keys -t claude Enter
sleep 5

# Verify
OUTPUT=$(tmux capture-pane -t claude -p 2>&1)
if echo "$OUTPUT" | grep -q "Listening for channel messages"; then
  echo "SUCCESS: Claude Code is running in tmux and listening for Telegram messages"
else
  echo "WARN: could not confirm 'Listening' state — attach with 'tmux attach -t claude' to inspect"
fi
```

**Fallback (if automation is blocked):** Give the user these exact commands:

```
tmux new-session -s claude -d
tmux send-keys -t claude '~/start-claude.sh' Enter
tmux attach -t claude   # verify, then Ctrl+B, D to detach
```

### Step 13 — 👤 MANUAL: Telegram pairing and access control

After Claude Code is listening, the user must pair their Telegram account. This requires interactive input and should **not** be automated (it involves a code shown on the user's phone).

Tell the user:

> 1. Open Telegram and send any message to your bot.
> 2. The bot will reply with a 6-character pairing code like `ef9e47`.
> 3. Run inside the Claude Code tmux session:
>    ```
>    /telegram:access pair <CODE>
>    ```
> 4. (Optional) Lock down access to only your own account:
>    ```
>    /telegram:access policy allowlist
>    /telegram:access allow <your_telegram_user_id>
>    ```

### Step 14 — 🤖 AUTO: Final deployment report

```bash
CWD_SLUG=$(echo "${CWD_FOR_MEMORY}" | sed 's|/|-|g')

cat >> "${TARGET_DIR}/MIGRATION_REPORT.md" << REPORTEOF

---

## Deployment Results

- \`~/CLAUDE.md\` — $(wc -l < "${HOME}/CLAUDE.md" 2>/dev/null || echo 0) lines
- Memory files at \`${CLAUDE_HOME}/projects/${CWD_SLUG}/memory/\` — $(ls "${CLAUDE_HOME}/projects/${CWD_SLUG}/memory/" 2>/dev/null | wc -l) files
- Skills at \`${CLAUDE_HOME}/skills/\` — $(ls -d "${CLAUDE_HOME}/skills/"*/ 2>/dev/null | wc -l) skills
- tmux session: $(tmux ls 2>/dev/null | grep claude || echo 'not running')

## Remaining Manual Steps

- [ ] Review \`~/CLAUDE.md\` for OpenClaw-specific references
- [ ] Merge \`env_for_settings.json\` into \`~/.claude/settings.json\` (if generated)
- [ ] Pair Telegram account (see Step 13)
- [ ] Send a test Telegram message to verify end-to-end
- [ ] Keep OpenClaw running for the dual-track period
REPORTEOF

echo ""
echo "=== MIGRATION COMPLETE ==="
cat "${TARGET_DIR}/MIGRATION_REPORT.md"
```

---

## Troubleshooting

```
Problem: CLAUDE.md contains references to /home/ubuntu/.openclaw/workspace/
└─ These paths still work if running on the same server. Update them if migrating to a new machine.

Problem: Memory files not showing up in Claude Code
└─ Claude Code memory is per-project — deploy to ~/.claude/projects/<cwd-slug>/memory/
   The slug is the launch cwd with '/' replaced by '-'. Verify CWD_FOR_MEMORY matches
   where Claude Code actually launches (cd inside start-claude.sh).

Problem: Skills not found after migration
└─ Skills must be in ~/.claude/skills/ (global) or .claude/skills/ (project-local)
   Each skill needs a SKILL.md with valid YAML frontmatter (name + description fields)

Problem: Model not working after migration
└─ OpenClaw uses "provider/model-id" format. Claude Code uses bare model IDs for Anthropic.
   Example: "anthropic/claude-sonnet-4-6" → "claude-sonnet-4-6"
   For non-Anthropic models, Claude Code uses MCP or API key config — different setup required.

Problem: Secondary agent (e.g. workspace-work/) not migrated
└─ Re-run this skill with AGENT_NAME set to the secondary agent name (e.g. "work")
   Each agent becomes a separate Claude Code project or a separate CLAUDE.md profile.
```

### Telegram launch troubleshooting (Steps 11-13)

```
Problem: Messages sent to Telegram but Claude Code doesn't reply
│
├─ Check: Is tmux session alive?
│  $ tmux ls | grep claude
│  ├─ Missing → Re-run Step 12
│  └─ Alive ↓
│
├─ Check: Is the plugin enabled?
│  $ claude plugin list | grep telegram
│  ├─ Status: disabled → $ claude plugin enable telegram@claude-plugins-official
│  └─ Enabled ↓
│
├─ Check: Is bun server.ts running as a child of claude?
│  $ ps -ef | grep 'bun.*server.ts'
│  ├─ Missing → start-claude.sh is missing --channels flag; fix it, restart tmux
│  └─ Running ↓
│
├─ Check: tmux pane — does it say "Listening for channel messages"?
│  $ tmux capture-pane -t claude -p | grep Listening
│  ├─ Not there → First-run "Trust this folder" dialog may be stuck. Send Enter.
│  └─ Listening ↓
│
├─ Check: Did Claude reply in terminal but not call the reply tool?
│  $ tmux capture-pane -t claude -p | grep 'telegram - reply'
│  ├─ No tool call → CLAUDE.md Telegram rule not loaded. Restart tmux so the
│  │                  new session picks up the updated CLAUDE.md.
│  └─ Called ↓
│
└─ Check Telegram bot for 409 Conflict (another process polling the same bot)
   $ curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates"
   ├─ 409 → Kill zombie claude/bun processes, restart tmux
   └─ OK  → The reply was sent; check the user's Telegram client
```

## Post-Deploy Sanity Check

```bash
# 1. CLAUDE.md loaded
test -f ~/CLAUDE.md && echo "✓ CLAUDE.md" || echo "✗ CLAUDE.md"

# 2. Memory in place
CWD_SLUG=$(echo "${CWD_FOR_MEMORY}" | sed 's|/|-|g')
ls "${CLAUDE_HOME}/projects/${CWD_SLUG}/memory/" 2>/dev/null | head -5

# 3. Skills deployed
ls -d "${CLAUDE_HOME}/skills/"*/ 2>/dev/null

# 4. Plugin enabled (only if telegram launch was done)
claude plugin list 2>&1 | grep -A2 telegram

# 5. tmux alive (only if telegram launch was done)
tmux ls | grep claude

# 6. Full process chain (only if telegram launch was done)
ps -ef | grep -E 'tmux.*claude|start-claude|claude --dangerously|bun.*server.ts' | grep -v grep
```

Expected process chain when fully launched:
```
tmux new-session -d -s claude ~/start-claude.sh
 └─ bash ~/start-claude.sh
     └─ claude --dangerously-skip-permissions --channels plugin:telegram@claude-plugins-official
         └─ bun run ... telegram
             └─ bun server.ts
```

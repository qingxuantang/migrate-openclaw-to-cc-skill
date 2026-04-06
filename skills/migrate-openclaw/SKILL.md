---
name: migrate-openclaw
description: Migrate OpenClaw skills, agents, workspace identity, and memory to Claude Code format. Handles the full OpenClaw agent structure — SOUL.md, AGENTS.md, IDENTITY.md, memory files, skills, env vars, and model config. Agent-executable with deterministic steps.
disable-model-invocation: false
---

# Agent Runbook: Migrate OpenClaw → Claude Code

## Context

As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. This skill performs a **complete** migration of an OpenClaw agent to Claude Code — not just skill files, but the full agent identity, memory, and configuration.

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
| `workspace/memory/*.md` | `~/.claude/projects/.../memory/` | **Copy as reference** — not directly loadable |
| `skills/*/SKILL.md` | `~/.claude/skills/*/SKILL.md` | **Direct copy** — identical format |
| `workspace/skills/` | `~/.claude/skills/` | **Direct copy** |
| `openclaw.json` → `env` | `~/.claude/settings.json` → `env` | **Direct copy** |
| `agents/{name}/agent/agent.yaml` | `~/.claude/settings.json` → `model` | **Format convert** |
| `openclaw.json` → `plugins` | `~/.claude/settings.json` → `mcpServers` | **Manual** — different schema |
| `agents/{name}/sessions/` | Not applicable | **Skip** — session history is ephemeral |
| `memory/*.sqlite` | Not applicable | **Skip** — rebuilt automatically from memory files |

## Contract

**Input** (collect ALL before starting):

| Parameter | Format | Example |
|-----------|--------|---------|
| `OPENCLAW_DIR` | absolute path | `/home/ubuntu/.openclaw` |
| `TARGET_DIR` | absolute path | `/home/ubuntu/claude-migration` |
| `AGENT_NAME` | agent name | `main` (default) or `work` |

`AGENT_NAME` determines which `agents/{name}/` and `workspace/` (or `workspace-{name}/`) to use. Default to `main`.

**Output**: Complete Claude Code setup — CLAUDE.md, typed memory files, skills — in `TARGET_DIR`, plus instructions for deploying to `~/.claude/`.

---

## Execution

### Step 1: Inventory OpenClaw structure

```bash
echo "=== OpenClaw Inventory for agent: ${AGENT_NAME} ==="
echo ""

# Determine workspace path
if [ "${AGENT_NAME}" = "main" ]; then
  WORKSPACE="${OPENCLAW_DIR}/workspace"
else
  WORKSPACE="${OPENCLAW_DIR}/workspace-${AGENT_NAME}"
  # Fallback to generic workspace if agent-specific doesn't exist
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

**Stop if workspace is not found.** The workspace is the core of an OpenClaw agent. Without it, there is nothing meaningful to migrate. Ask the user to verify `OPENCLAW_DIR` and `AGENT_NAME`.

### Step 2: Create migration directory structure

```bash
mkdir -p "${TARGET_DIR}/skills"
mkdir -p "${TARGET_DIR}/memory"
echo "OK: target directories created at ${TARGET_DIR}"
```

### Step 3: Merge workspace identity files → CLAUDE.md

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

After writing, print:
```
OK: CLAUDE.md written — review before deploying to ~/.claude/CLAUDE.md
```

**Important:** If SOUL.md references specific file paths like `/home/ubuntu/.openclaw/workspace/`, note them in the migration report but do NOT auto-change them — the user may want to keep using the same workspace.

### Step 4: Migrate memory

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
  ARCHIVE_COUNT=$(ls "${TARGET_DIR}/memory/archive/" 2>/dev/null | wc -l)
  echo "OK: ${ARCHIVE_COUNT} daily memory files copied to archive/"
fi
```

### Step 5: Migrate skills (direct copy)

```bash
if [ -d "${OPENCLAW_DIR}/skills" ]; then
  MIGRATED=0
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

### Step 6: Extract environment variables and model config

**Env vars from openclaw.json:**

```bash
if [ -f "${OPENCLAW_DIR}/openclaw.json" ]; then
  # Extract env section as JSON
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

### Step 7: MCP / plugins migration guidance

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

**`telegram`** → Use the `deploy-telegram` skill in this repo. It sets up Claude Code with persistent Telegram access via a tmux session and MCP bot server. This is the full replacement.

**`duckduckgo`** (web search) → Claude Code has built-in WebSearch and WebFetch tools. No MCP server needed. Remove any explicit duckduckgo configuration.

**Any other plugin** → Check if a Claude Code MCP server equivalent exists. If OpenClaw had custom MCP server configs (separate from plugins), copy them to `${TARGET_DIR}/mcp_reference.json` for manual review and conversion to Claude Code's `mcpServers` schema in `settings.json`.

### Step 8: Generate migration report

```bash
REPORT="${TARGET_DIR}/MIGRATION_REPORT.md"

cat > "$REPORT" << REPORTEOF
# OpenClaw → Claude Code Migration Report

Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
Agent: ${AGENT_NAME}
Source: ${OPENCLAW_DIR}
Target: ${TARGET_DIR}

## Files Generated

| File | Purpose | Deploy to |
|------|---------|-----------|
| \`CLAUDE.md\` | Agent identity (SOUL + AGENTS + IDENTITY merged) | \`~/.claude/CLAUDE.md\` (global) or \`.claude/CLAUDE.md\` (per-project) |
| \`memory/MEMORY.md\` | Memory index | \`~/.claude/projects/{path}/memory/MEMORY.md\` |
| \`memory/*.md\` | Typed long-term memory files | \`~/.claude/projects/{path}/memory/\` |
| \`memory/archive/\` | Daily memory logs (for reference) | Review manually, do not deploy directly |
| \`skills/\` | All migrated skills | \`~/.claude/skills/\` |
| \`env_for_settings.json\` | Env vars to merge into settings | Merge into \`~/.claude/settings.json\` |

## Deployment Checklist

- [ ] Review \`CLAUDE.md\` — check for OpenClaw-specific references that need updating
- [ ] Deploy \`CLAUDE.md\` to \`~/.claude/CLAUDE.md\`
- [ ] Deploy memory files to \`~/.claude/projects/{workspace-path}/memory/\`
- [ ] Deploy skills to \`~/.claude/skills/\`
- [ ] Merge \`env_for_settings.json\` into \`~/.claude/settings.json\`
- [ ] Set model in \`~/.claude/settings.json\`
- [ ] Set up Telegram (if needed): run the \`deploy-telegram\` skill
- [ ] Review \`memory/archive/\` daily logs — extract any important facts into new typed memory files
- [ ] Verify skills work by invoking them in Claude Code

## What Was NOT Migrated (and Why)

| Component | Reason |
|-----------|--------|
| \`agents/*/sessions/\` | Session history is ephemeral — no equivalent concept |
| \`memory/*.sqlite\` | Vector index is rebuilt automatically from markdown files |
| OpenClaw plugins | Not MCP servers — see plugin guidance above |
| Auth profiles | Auth tokens are account-specific — set up fresh in Claude Code |

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

echo "OK: Migration report written to ${REPORT}"
echo ""
echo "=== MIGRATION COMPLETE ==="
echo ""
echo "Next step: review ${TARGET_DIR}/CLAUDE.md before deploying."
```

---

## Troubleshooting

```
Problem: CLAUDE.md contains references to /home/ubuntu/.openclaw/workspace/
└─ These paths still work if running on the same server. Update them if migrating to a new machine.

Problem: Memory files not showing up in Claude Code
└─ Claude Code memory is per-project — deploy to ~/.claude/projects/{hashed-path}/memory/
   The path hash is derived from the absolute project working directory.
   Run: claude --print-memory-path (or check ~/.claude/projects/)

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

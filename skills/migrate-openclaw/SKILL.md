---
name: migrate-openclaw
description: Migrate OpenClaw skills, agents, and configuration to Claude Code format. Agent-executable — deterministic steps with clear decision logic. Works for both local and server-based migrations.
disable-model-invocation: false
---

# Agent Runbook: Migrate OpenClaw → Claude Code

## Context

As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. This skill migrates existing OpenClaw skills, agents, and configurations to native Claude Code format so they continue to work.

## Contract

**Input** (collect ALL before starting):

| Parameter | Format | Example | How to obtain |
|-----------|--------|---------|---------------|
| `OPENCLAW_DIR` | absolute path | `/home/ubuntu/.openclaw` or `C:\Users\me\.openclaw` | User provides — typically `~/.openclaw` |
| `TARGET_DIR` | absolute path | `/home/ubuntu/my-skills` or `D:\git_repo\my-skills` | User provides — where to place migrated skills |

**Output**: All compatible skills and agents migrated to Claude Code format in `TARGET_DIR`, with a migration report.

## Compatibility Matrix

| OpenClaw Item | Claude Code Equivalent | Migration |
|---------------|----------------------|-----------|
| Custom Skill (SKILL.md) | Custom Skill (SKILL.md) | **Direct copy** — format is identical |
| Agent (agent.md) | Custom Skill (SKILL.md) | **Rename + minor edits** — add YAML frontmatter |
| Marketplace Skill | Claude Code Plugin | **Manual reinstall** — check if available in Claude Code marketplace |
| `.openclaw/config.json` | `.claude/settings.json` | **Manual mapping** — different schema |
| Environment variables (.env) | Environment variables (.env) | **Direct copy** — same format |
| MCP server configs | MCP server configs | **Format conversion** — different config location |

## Execution

### Step 1: Inventory OpenClaw assets

```bash
echo "=== OpenClaw Inventory ==="

# Skills
SKILL_COUNT=0
if [ -d "${OPENCLAW_DIR}/skills" ]; then
  SKILL_COUNT=$(find "${OPENCLAW_DIR}/skills" -name "SKILL.md" | wc -l)
  echo "Custom Skills: $SKILL_COUNT"
  find "${OPENCLAW_DIR}/skills" -name "SKILL.md" -exec dirname {} \; | while read d; do
    echo "  - $(basename "$d")"
  done
else
  echo "Custom Skills: 0 (no skills directory)"
fi

# Agents
AGENT_COUNT=0
if [ -d "${OPENCLAW_DIR}/agents" ]; then
  AGENT_COUNT=$(find "${OPENCLAW_DIR}/agents" -name "agent.md" | wc -l)
  echo "Agents: $AGENT_COUNT"
  find "${OPENCLAW_DIR}/agents" -name "agent.md" -exec dirname {} \; | while read d; do
    echo "  - $(basename "$d")"
  done
else
  echo "Agents: 0 (no agents directory)"
fi

# Config
[ -f "${OPENCLAW_DIR}/config.json" ] && echo "Config: found" || echo "Config: not found"

# MCP servers
if [ -f "${OPENCLAW_DIR}/mcp.json" ] || [ -f "${OPENCLAW_DIR}/mcp_servers.json" ]; then
  echo "MCP config: found"
else
  echo "MCP config: not found"
fi

# Environment
ENV_COUNT=0
if [ -d "${OPENCLAW_DIR}" ]; then
  ENV_COUNT=$(find "${OPENCLAW_DIR}" -name ".env" | wc -l)
  echo "Environment files: $ENV_COUNT"
fi

echo ""
echo "Total items to migrate: $((SKILL_COUNT + AGENT_COUNT))"
echo "=== End Inventory ==="
```

**If total is 0**: Tell the user there's nothing to migrate. Ask if the `OPENCLAW_DIR` path is correct.

### Step 2: Create target directory structure

```bash
mkdir -p "${TARGET_DIR}/skills"
echo "OK: target directory ready at ${TARGET_DIR}"
```

### Step 3: Migrate custom skills (direct copy)

OpenClaw custom skills use the same SKILL.md format as Claude Code. Copy them directly.

```bash
if [ -d "${OPENCLAW_DIR}/skills" ]; then
  MIGRATED=0
  find "${OPENCLAW_DIR}/skills" -name "SKILL.md" -exec dirname {} \; | while read src; do
    SKILL_NAME=$(basename "$src")
    dest="${TARGET_DIR}/skills/${SKILL_NAME}"

    if [ -d "$dest" ]; then
      echo "SKIP: ${SKILL_NAME} — already exists at destination"
      continue
    fi

    cp -r "$src" "$dest"
    echo "COPIED: ${SKILL_NAME}"
    MIGRATED=$((MIGRATED + 1))
  done
  echo "Skills migrated: check output above"
else
  echo "SKIP: no skills directory found"
fi
```

### Step 4: Convert agents to skills

OpenClaw agents use `agent.md` files. Claude Code uses `SKILL.md` with YAML frontmatter. The conversion is:

1. Read the agent.md content
2. Create SKILL.md with frontmatter wrapping the original content
3. Copy any supporting files (scripts, configs) alongside

```bash
if [ -d "${OPENCLAW_DIR}/agents" ]; then
  find "${OPENCLAW_DIR}/agents" -name "agent.md" -exec dirname {} \; | while read src; do
    AGENT_NAME=$(basename "$src")
    dest="${TARGET_DIR}/skills/${AGENT_NAME}"

    if [ -d "$dest" ]; then
      echo "SKIP: ${AGENT_NAME} — already exists at destination"
      continue
    fi

    mkdir -p "$dest"

    # Copy all supporting files first
    find "$src" -maxdepth 1 -type f ! -name "agent.md" -exec cp {} "$dest/" \;

    # Extract first line as description (strip markdown heading)
    FIRST_LINE=$(head -1 "$src/agent.md" | sed 's/^#\+ *//')

    # Check if agent.md already has YAML frontmatter
    if head -1 "$src/agent.md" | grep -q '^---$'; then
      # Already has frontmatter — copy as SKILL.md directly
      cp "$src/agent.md" "$dest/SKILL.md"
      echo "CONVERTED (with existing frontmatter): ${AGENT_NAME}"
    else
      # Add frontmatter
      cat > "$dest/SKILL.md" << SKILLEOF
---
name: ${AGENT_NAME}
description: ${FIRST_LINE}
disable-model-invocation: false
---

$(cat "$src/agent.md")
SKILLEOF
      echo "CONVERTED: ${AGENT_NAME}"
    fi
  done
else
  echo "SKIP: no agents directory found"
fi
```

### Step 5: Migrate MCP server configurations

OpenClaw and Claude Code both support MCP servers but store configs differently.

```bash
# Check for OpenClaw MCP config
MCP_FILE=""
[ -f "${OPENCLAW_DIR}/mcp.json" ] && MCP_FILE="${OPENCLAW_DIR}/mcp.json"
[ -f "${OPENCLAW_DIR}/mcp_servers.json" ] && MCP_FILE="${OPENCLAW_DIR}/mcp_servers.json"

if [ -n "$MCP_FILE" ]; then
  echo "Found MCP config at: $MCP_FILE"
  echo "Contents:"
  cat "$MCP_FILE"
  echo ""
  echo ""
  echo "ACTION REQUIRED: Copy relevant MCP server entries to Claude Code config."
  echo "Claude Code MCP config location: ~/.claude/mcp_servers.json (global) or .claude/mcp_servers.json (per-project)"
  echo ""
  echo "Format is the same — copy the server entries directly."

  # Create a reference copy
  cp "$MCP_FILE" "${TARGET_DIR}/mcp_servers_reference.json"
  echo "Reference copy saved to: ${TARGET_DIR}/mcp_servers_reference.json"
else
  echo "SKIP: no MCP config found"
fi
```

### Step 6: Migrate environment files

```bash
if [ -d "${OPENCLAW_DIR}" ]; then
  find "${OPENCLAW_DIR}" -name ".env" | while read envfile; do
    REL_PATH=$(realpath --relative-to="${OPENCLAW_DIR}" "$envfile")
    PARENT_DIR=$(dirname "$REL_PATH")

    echo "Found .env at: $envfile"
    echo "  Relative path: $REL_PATH"

    # Copy to target for reference (don't auto-deploy — may contain secrets)
    mkdir -p "${TARGET_DIR}/env_backup/${PARENT_DIR}"
    cp "$envfile" "${TARGET_DIR}/env_backup/${REL_PATH}"
    echo "  Backed up to: ${TARGET_DIR}/env_backup/${REL_PATH}"
  done
  echo ""
  echo "NOTE: .env files backed up for reference. Review and deploy manually to appropriate Claude Code locations."
else
  echo "SKIP: no .env files found"
fi
```

### Step 7: Generate migration report

```bash
cat > "${TARGET_DIR}/MIGRATION_REPORT.md" << 'REPORTEOF'
# OpenClaw → Claude Code Migration Report

Generated: $(date -u +"%Y-%m-%d %H:%M:%S UTC")

## Migrated Items

### Skills (direct copy)
REPORTEOF

# List migrated skills
if [ -d "${TARGET_DIR}/skills" ]; then
  for skill_dir in "${TARGET_DIR}/skills"/*/; do
    [ -d "$skill_dir" ] || continue
    SNAME=$(basename "$skill_dir")
    if [ -f "$skill_dir/SKILL.md" ]; then
      echo "- ✅ \`${SNAME}\` — ready to use" >> "${TARGET_DIR}/MIGRATION_REPORT.md"
    fi
  done
fi

cat >> "${TARGET_DIR}/MIGRATION_REPORT.md" << 'REPORTEOF'

## How to Use Migrated Skills in Claude Code

### Option A: Project-level skills
Copy skill directories into your project's `.claude/skills/` folder:
```bash
cp -r skills/my-skill /path/to/project/.claude/skills/
```

### Option B: Global custom skills
Add the skills directory to Claude Code's global config:
```bash
claude skill add /path/to/skills/my-skill
```

### Option C: Reference in conversation
Simply tell Claude Code: "Use the skill at /path/to/skills/my-skill/SKILL.md"

## Post-Migration Checklist

- [ ] Verify each skill works by invoking it in Claude Code
- [ ] Move .env files to appropriate Claude Code locations
- [ ] Update MCP server configs if applicable
- [ ] Remove OpenClaw installation if no longer needed
- [ ] Update any external integrations (webhooks, cron jobs) to use Claude Code

## Known Differences

| Feature | OpenClaw | Claude Code |
|---------|----------|-------------|
| Skill format | SKILL.md (identical) | SKILL.md |
| Agent format | agent.md | SKILL.md (with frontmatter) |
| Permissions | config.json | settings.json |
| MCP servers | mcp.json | mcp_servers.json |
| Telegram | Built-in | Channel plugin |
| Auto-start | PM2 / systemd | tmux + systemd |

REPORTEOF

echo "OK: Migration report written to ${TARGET_DIR}/MIGRATION_REPORT.md"
echo ""
echo "=== MIGRATION COMPLETE ==="
```

## Troubleshooting

```
Problem: Migrated skill not showing up in Claude Code
│
├─ Check: Is the skill in the right location?
│  $ ls .claude/skills/ or claude skill list
│  ├─ Not there → Copy skill directory to .claude/skills/
│  └─ There ↓
│
├─ Check: Does SKILL.md have valid YAML frontmatter?
│  $ head -5 .claude/skills/my-skill/SKILL.md
│  ├─ Missing --- block → Add frontmatter (name + description)
│  └─ Valid ↓
│
├─ Check: Is the skill name unique?
│  $ claude skill list | grep my-skill
│  ├─ Duplicate → Rename one of them
│  └─ Unique ↓
│
└─ Restart Claude Code session and try again
```

## File Manifest

| Source (OpenClaw) | Destination (Claude Code) | Action |
|-------------------|--------------------------|--------|
| `~/.openclaw/skills/*/SKILL.md` | `${TARGET_DIR}/skills/*/SKILL.md` | Direct copy |
| `~/.openclaw/agents/*/agent.md` | `${TARGET_DIR}/skills/*/SKILL.md` | Convert + add frontmatter |
| `~/.openclaw/mcp.json` | `${TARGET_DIR}/mcp_servers_reference.json` | Reference copy |
| `~/.openclaw/**/.env` | `${TARGET_DIR}/env_backup/**/.env` | Backup copy |

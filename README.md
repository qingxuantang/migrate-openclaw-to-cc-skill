# Claude Code Telegram Deploy

<p align="center">
  <a href="#english">English</a> | <a href="#中文">中文</a>
</p>

---

<a id="english"></a>

## English

Open-source skills for deploying Claude Code on remote servers with Telegram integration, and for migrating a full OpenClaw agent (Soul, Memory, Skills, workspace identity) over to Claude Code.

> **Background**: As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. These skills provide a first-party alternative using Claude Code's native Channels feature.

### Skills

#### 🚀 [deploy-telegram](skills/deploy-telegram/SKILL.md)

Deploy Claude Code on a remote Linux server and connect it to Telegram for remote access.

**What it does:**
- Installs Node.js, Claude Code, tmux, and Bun on the server
- Configures authentication via OAuth token
- Installs the official Telegram channel plugin
- Writes `settings.json` with the mandatory `channelsEnabled: true` flag
- Creates a startup script with auto-restart loop
- Sets up a systemd user service for auto-start on reboot
- Handles all interactive dialogs automatically (trust folder, bypass permissions)

**Requirements:**
- Linux server with SSH access
- Telegram bot token (from @BotFather) — must be a **fresh** bot, not one already used by another tool
- Claude OAuth token (from `claude setup-token` on a machine with a browser)
- Server must reach: `api.telegram.org`, `github.com`, `api.anthropic.com`

#### 🔄 [migrate-openclaw](skills/migrate-openclaw/SKILL.md)

Migrate a complete OpenClaw agent to Claude Code — not just files, but the full identity, memory, and deployment.

**What it does:**
- Inventories the real OpenClaw structure (`workspace/SOUL.md`, `AGENTS.md`, `IDENTITY.md`, `TOOLS.md`, `MEMORY.md`, `memory/`, `skills/`, `agents/{name}/agent/agent.yaml`, `openclaw.json`)
- Merges `SOUL.md` + `AGENTS.md` + `IDENTITY.md` + `TOOLS.md` into a single `CLAUDE.md`
- Auto-appends a **mandatory Telegram Channel reply-tool rule** to `CLAUDE.md` (fixes a real production bug — see Key Learnings)
- Parses `MEMORY.md` into Claude Code's typed memory files (`user` / `feedback` / `project` / `reference`)
- Archives daily memory logs for manual review
- Copies all global and workspace-local skills (format is identical)
- Extracts environment variables from `openclaw.json` for `settings.json`
- Extracts and converts the model ID from `agent.yaml` (strips the `anthropic/` provider prefix)
- Provides per-plugin migration guidance (telegram → deploy-telegram skill, duckduckgo → built-in WebSearch, etc.)
- Supports multi-agent setups (`workspace-{name}/` via the `AGENT_NAME` parameter)
- **Physically deploys** the migrated files into `~/.claude/` (not just a staging dir)
- Optionally creates `start-claude.sh` and launches it in tmux with the Telegram channel attached
- Never stops OpenClaw — designed for dual-track (OpenClaw + Claude Code running in parallel)

**Each step is tagged with an automation policy:** 🤖 AUTO / 🟡 AUTO-FIRST / 👤 MANUAL / 🚫 DO NOT — so agents know exactly what to execute and what to hand back to the user.

### Design: Agent-First

These skills are designed to be **executed by AI agents**, not read by humans. Any agent (Claude Code, OpenClaw, Codex) can:

1. Read the SKILL.md file
2. Collect the required inputs from the user
3. Execute each step sequentially
4. Handle errors using the troubleshooting decision tree

The skills use deterministic shell commands — no judgment calls required.

### Quick Start

#### For Claude Code users

```
# Option 1: Reference directly
"Use the skill at /path/to/skills/deploy-telegram/SKILL.md to deploy Claude Code on my server"

# Option 2: Copy to project
cp -r skills/deploy-telegram .claude/skills/
```

#### For humans (manual deployment)

<details>
<summary>Click to expand manual steps</summary>

1. Create a Telegram bot via @BotFather → get bot token
2. Run `claude setup-token` on a machine with a browser → get OAuth token
3. SSH into your server
4. Follow Steps 1–9 in [deploy-telegram/SKILL.md](skills/deploy-telegram/SKILL.md)
5. Message your bot on Telegram → get pairing code
6. Run the pairing command from the skill

</details>

### Key Learnings

Hard-won discoveries from real deployments:

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Missing `channelsEnabled: true` | Messages silently dropped, debug log shows "Channel notifications skipped" | Add to `~/.claude/settings.json` |
| Using `--plugin-dir` with `--channels` | "skipped...from inline" in debug log | Never combine these flags |
| Zombie bun/claude processes | Telegram 409 Conflict error | Kill all processes before restart |
| `setup-token` on headless server | "Raw mode is not supported" error | Run on machine with browser, copy token to server |
| Wrong env var name | Auth fails silently | Use `CLAUDE_CODE_OAUTH_TOKEN` (not `CLAUDE_CODE_USE_CLAUDE_AI_TOKEN`) |
| Mainland China servers | All network checks fail | Use servers in HK, SG, JP, US, EU |
| Plugin installed but disabled | Plugin shows `✘ disabled` in `claude plugin list` | `claude plugin enable telegram@claude-plugins-official` |
| Reusing OpenClaw's bot token for Claude Code | Telegram 409 Conflict (two polls) | Always create a **new** bot from @BotFather |
| Missing `--channels` flag in startup script | Bun MCP server never spawns | Add `--channels plugin:telegram@claude-plugins-official` |
| **Claude replies in terminal but user gets nothing** | tmux pane shows the reply, Telegram does not | Claude forgot to call `plugin:telegram:telegram - reply` MCP tool. Add the Telegram Channel reply-tool rule to `CLAUDE.md` and restart the session |
| Migrate-openclaw v1: files staged but not deployed | User sees staging dir but Claude Code sees nothing | Skill now has an explicit Step 9 that copies into `~/.claude/` |
| NVM not on PATH in non-interactive shells | `claude: command not found` in startup script | Source NVM in `~/.bashrc` and in `start-claude.sh` |
| **Telegram spams Allow/Deny permission cards on every tool call** | Edit/Write/Bash from Telegram triggers a `🔐 Permission: <tool>` card even with `--dangerously-skip-permissions` and a full `permissions.allow` list | Plugin `server.ts` declares `'claude/channel/permission': {}` as an opt-in capability. Claude Code relays channel-session permission prompts to Telegram **independently** of terminal bypass flags. Comment out that single line and restart. Skill auto-patches this as Step 10b. |
| **Claude silently stops responding mid-session** | tmux pane shows an "allow Claude to edit its own settings" dialog; Telegram gets no reply | Hard-coded safety prompt fires whenever Claude edits any file under `~/.claude/` (e.g. tweaking a skill's own source). Not covered by `--dangerously-skip-permissions`, no settings switch. Recover by sending `Down` then `Enter` via `tmux send-keys` to pick option 2 — unblocks the session until next restart. |
| **Local Claude Code keeps prompting for permission even with `permissions.allow` full-wildcard** | Edit/Write still pops a permission card despite `permissions.allow: ["Bash(*)","Edit(*)",…]` and `skipDangerousModePermissionPrompt: true` | Those two keys only control the *judgment* after a check is triggered, not the check itself. Add `permissions.defaultMode: "bypassPermissions"` to `~/.claude/settings.json` — equivalent to launching with `--dangerously-skip-permissions` every time. Six modes exist (`default`/`acceptEdits`/`plan`/`auto`/`dontAsk`/`bypassPermissions`); only the last truly silences prompts. Self-edit guard on `~/.claude/` files still cannot be bypassed. |

### The Telegram Channel Reply-Tool Rule

If you have a `CLAUDE.md` on a server running Claude Code with the Telegram channel, append this rule. It prevents a silent failure mode where Claude generates a reply but never actually sends it back to the user.

```markdown
## Telegram Channel 强制规则（最高优先级 / Highest Priority）

When a message arrives via the Telegram channel (you see `← telegram · <user_id>:` in your input), you **MUST** reply by calling the `plugin:telegram:telegram - reply` MCP tool. Terminal text output is **NOT** delivered to the user — only explicit tool calls are.

Rules:
1. Every Telegram user message must be followed by at least one `plugin:telegram:telegram - reply` tool call.
2. Do not assume follow-up replies in the same session send automatically. Each new message needs its own explicit reply call.
3. Markdown written to the terminal is invisible to the user unless passed through the reply tool.
4. The task is not complete until the reply tool has been called successfully.
```

The `migrate-openclaw` skill appends this automatically when generating `CLAUDE.md`.

### Architecture

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
└──────┬───────┘
       │ stdio (MCP protocol)
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

---

<a id="中文"></a>

## 中文

开源技能集：在远程服务器上部署 Claude Code 并通过 Telegram 进行远程访问，以及把一整个 OpenClaw agent（Soul、Memory、Skills、workspace 身份）完整迁移到 Claude Code。

> **背景**：2026 年 4 月 5 日起，Anthropic 封禁了 OpenClaw 使用 Claude Pro/Max 订阅。本项目提供基于 Claude Code 原生 Channels 功能的第一方替代方案。

### 技能列表

#### 🚀 [deploy-telegram](skills/deploy-telegram/SKILL.md) — 部署 Telegram 频道

在远程 Linux 服务器上部署 Claude Code，并连接 Telegram 实现远程访问。

**功能：**
- 在服务器上安装 Node.js、Claude Code、tmux 和 Bun
- 通过 OAuth Token 配置身份认证
- 安装官方 Telegram 频道插件
- 写入带有强制 `channelsEnabled: true` 的 `settings.json`
- 生成带自动重启循环的启动脚本
- 配置 systemd user service 实现开机自启
- 自动处理所有交互式对话框（trust folder、bypass permissions）

**前置条件：**
- 具有 SSH 访问权限的 Linux 服务器
- Telegram Bot Token（通过 @BotFather 创建）—— 必须是**全新的** bot，不能和其他工具共用
- Claude OAuth Token（在有浏览器的机器上运行 `claude setup-token` 获取）
- 服务器必须能访问：`api.telegram.org`、`github.com`、`api.anthropic.com`

#### 🔄 [migrate-openclaw](skills/migrate-openclaw/SKILL.md) — 迁移 OpenClaw

把一整个 OpenClaw agent 完整迁移到 Claude Code —— 不只是文件转换，还包括身份、记忆、部署全流程。

**功能：**
- 清点真实的 OpenClaw 目录结构（`workspace/SOUL.md`、`AGENTS.md`、`IDENTITY.md`、`TOOLS.md`、`MEMORY.md`、`memory/`、`skills/`、`agents/{name}/agent/agent.yaml`、`openclaw.json`）
- 把 `SOUL.md` + `AGENTS.md` + `IDENTITY.md` + `TOOLS.md` 合并成单个 `CLAUDE.md`
- 在 `CLAUDE.md` 末尾**自动追加 Telegram Channel 回复工具强制规则**（修复真实踩过的坑，见踩坑经验）
- 把 `MEMORY.md` 解析成 Claude Code 的 typed memory 文件（`user` / `feedback` / `project` / `reference` 四类）
- 把每日记忆日志归档到 `archive/` 供手动 review
- 复制所有全局和 workspace 级别的 skills（格式完全相同）
- 从 `openclaw.json` 提取环境变量供 `settings.json` 使用
- 从 `agent.yaml` 提取并转换模型 ID（自动去掉 `anthropic/` 前缀）
- 对每个插件给出迁移建议（telegram → deploy-telegram skill；duckduckgo → 内置 WebSearch 等）
- 支持多 agent 场景（通过 `AGENT_NAME` 参数迁移 `workspace-{name}/`）
- **实际把迁移产物部署到 `~/.claude/`**，不只是生成 staging 目录
- 可选地生成 `start-claude.sh` 并用 tmux 启动，自动挂上 Telegram channel
- 绝不停 OpenClaw —— 设计为双轨运行（OpenClaw 和 Claude Code 并行）

**每个步骤都有自动化策略标签：** 🤖 AUTO / 🟡 AUTO-FIRST / 👤 MANUAL / 🚫 DO NOT，让 agent 明确知道哪些自动执行、哪些交给用户。

### 设计理念：Agent-First（代理优先）

这些技能专为 **AI 代理执行**而设计，而非供人类阅读。任何代理（Claude Code、OpenClaw、Codex）都可以：

1. 读取 SKILL.md 文件
2. 向用户收集所需输入参数
3. 按顺序执行每个步骤
4. 使用故障排除决策树处理错误

所有技能使用确定性的 Shell 命令 —— 不需要任何主观判断。

### 快速开始

#### Claude Code 用户

```
# 方式一：直接引用
"使用 /path/to/skills/deploy-telegram/SKILL.md 这个 skill 在我的服务器上部署 Claude Code"

# 方式二：复制到项目
cp -r skills/deploy-telegram .claude/skills/
```

#### 手动部署

<details>
<summary>点击展开手动步骤</summary>

1. 通过 @BotFather 创建 Telegram Bot → 获取 Bot Token
2. 在有浏览器的机器上运行 `claude setup-token` → 获取 OAuth Token
3. SSH 登录服务器
4. 按照 [deploy-telegram/SKILL.md](skills/deploy-telegram/SKILL.md) 中的步骤 1–9 执行
5. 在 Telegram 上给你的 Bot 发消息 → 获取配对码
6. 执行 Skill 中的配对命令

</details>

### 踩坑经验

真实部署中的血泪教训：

| 坑 | 症状 | 解决方案 |
|----|------|----------|
| 缺少 `channelsEnabled: true` | 消息静默丢弃，调试日志显示 "Channel notifications skipped" | 添加到 `~/.claude/settings.json` |
| `--plugin-dir` 与 `--channels` 同时使用 | 调试日志中出现 "skipped...from inline" | 永远不要同时使用这两个标志 |
| 僵尸 bun/claude 进程 | Telegram 409 Conflict 错误 | 重启前先杀掉所有相关进程 |
| 在无头服务器上运行 `setup-token` | "Raw mode is not supported" 错误 | 在有浏览器的机器上运行，将 Token 复制到服务器 |
| 环境变量名错误 | 认证静默失败 | 使用 `CLAUDE_CODE_OAUTH_TOKEN`（不是 `CLAUDE_CODE_USE_CLAUDE_AI_TOKEN`） |
| 中国大陆服务器 | 所有网络检查失败 | 使用港、新、日、美、欧等地区的服务器 |
| 插件安装后状态为 disabled | `claude plugin list` 显示 `✘ disabled` | `claude plugin enable telegram@claude-plugins-official` |
| Claude Code 复用了 OpenClaw 的 bot token | Telegram 409 Conflict（两端抢 long-polling） | 一定要用 @BotFather 新建一个 bot |
| 启动脚本漏了 `--channels` 参数 | Bun MCP 服务器根本不会启动 | 加上 `--channels plugin:telegram@claude-plugins-official` |
| **Claude 在终端里写了回复，但用户没收到** | tmux 里能看到回复文本，Telegram 没收到 | Claude 忘了调 `plugin:telegram:telegram - reply` MCP 工具。把 Telegram Channel 回复工具规则写进 `CLAUDE.md` 并重启 session |
| v1 的 migrate-openclaw：文件只 staging 没部署 | 用户能看到 staging 目录，但 Claude Code 读不到任何东西 | 新版 Skill 增加了 Step 9，显式把文件复制到 `~/.claude/` |
| 非交互式 shell 里 NVM 不在 PATH | 启动脚本里 `claude: command not found` | 在 `~/.bashrc` 和 `start-claude.sh` 里 source NVM |
| **Telegram 每次调用工具都弹 Allow/Deny 权限卡片** | 即便 `--dangerously-skip-permissions` + `permissions.allow` 全开，Telegram 端一触发 Edit/Write/Bash 还是弹 `🔐 Permission: <tool>` | 插件 `server.ts` 里声明了 opt-in 能力 `'claude/channel/permission': {}`，Claude Code 会**独立于**终端 bypass 标志，把 channel 会话的权限请求转发到 Telegram。把那一行注释掉并重启即可。Skill 的 Step 10b 会自动打这个补丁。 |
| **Claude 跑着跑着突然不回复** | tmux pane 卡在 "allow Claude to edit its own settings" 对话框，Telegram 收不到任何回复 | 只要 Claude 要编辑 `~/.claude/` 目录下的文件（比如改 skill 自己的源码），就会触发这个硬编码的安全确认。`--dangerously-skip-permissions` 绕不过去，settings.json 也没开关。恢复方式：通过 `tmux send-keys` 发送 `Down` + `Enter` 选第 2 项，可以让本 session 剩余时间内都不再弹（重启后会再来）。 |
| **本地 Claude Code 即便 `permissions.allow` 全通配也仍弹权限卡片** | `permissions.allow: ["Bash(*)","Edit(*)",…]` + `skipDangerousModePermissionPrompt: true` 都加了，Edit/Write 还是弹卡 | 这两个 key 只控制"检查触发后的判定"，并不抑制检查本身。在 `~/.claude/settings.json` 里加 `permissions.defaultMode: "bypassPermissions"` 才是真正等价于每次都用 `--dangerously-skip-permissions` 启动。Schema 里六种 mode（`default`/`acceptEdits`/`plan`/`auto`/`dontAsk`/`bypassPermissions`），只有最后一个真正静默所有提示。但 `~/.claude/` 自编辑保护仍无法绕过。 |

### Telegram Channel 回复工具规则

如果你的服务器上运行着带 Telegram channel 的 Claude Code 且有 `CLAUDE.md`，务必把下面这条规则加进去。它防止一种静默失败：Claude 生成了回复，但从来没真正发回给用户。

```markdown
## Telegram Channel 强制规则（最高优先级）

当消息来源是 Telegram channel（输入中看到 `← telegram · <user_id>:` 标记时），你**必须**通过调用 `plugin:telegram:telegram - reply` MCP 工具来回复用户，**不能**只在终端输出文本。终端里写的任何内容，用户在 Telegram 端**完全看不到**。

规则：
1. 每一条来自 Telegram 的用户消息，都必须对应**至少一次** `plugin:telegram:telegram - reply` 工具调用
2. 不要假设同一 session 里后续回复会自动发出 —— 每一条新消息都要重新显式调用 reply 工具
3. 终端里的 markdown / 代码块 / 解释，如果不通过 reply 工具发出，用户就收不到
4. 回复工具调用成功前，不算任务完成
```

`migrate-openclaw` skill 在生成 `CLAUDE.md` 时会自动追加这条规则。

### 架构图

```
┌──────────────┐
│  Telegram    │
│  (手机)      │
└──────┬───────┘
       │ Bot API 长轮询
       v
┌──────────────┐
│  bun         │  MCP 服务器（claude 的子进程）
│  server.ts   │  Token 位置：~/.claude/channels/telegram/.env
└──────┬───────┘
       │ stdio（MCP 协议）
       v
┌──────────────┐
│  claude      │  在 tmux 中运行的 CLI，由 systemd 管理
│  --channels  │  settings.json 中需要 channelsEnabled: true
└──────┬───────┘
       │ 文件系统、git、bash、工具
       v
┌──────────────┐
│  服务器       │
└──────────────┘
```

---

## License

MIT

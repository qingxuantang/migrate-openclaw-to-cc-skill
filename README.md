# Claude Code Telegram Deploy

<p align="center">
  <a href="#english">English</a> | <a href="#中文">中文</a>
</p>

---

<a id="english"></a>

## English

Open-source skills for deploying Claude Code on remote servers with Telegram integration, and migrating from OpenClaw.

> **Background**: As of April 5, 2026, Anthropic blocked OpenClaw from using Claude Pro/Max subscriptions. These skills provide a first-party alternative using Claude Code's native Channels feature.

### Skills

#### 🚀 [deploy-telegram](skills/deploy-telegram/SKILL.md)

Deploy Claude Code on a remote Linux server and connect it to Telegram for remote access.

**What it does:**
- Installs Node.js, Claude Code, tmux, and Bun on the server
- Configures authentication via OAuth token
- Installs the official Telegram channel plugin
- Sets up systemd service for auto-start on reboot
- Handles all interactive dialogs automatically

**Requirements:**
- Linux server with SSH access
- Telegram bot token (from @BotFather)
- Claude OAuth token (from `claude setup-token`)
- Server must reach: api.telegram.org, github.com, api.anthropic.com

#### 🔄 [migrate-openclaw](skills/migrate-openclaw/SKILL.md)

Migrate OpenClaw skills, agents, and configuration to Claude Code format.

**What it does:**
- Inventories all OpenClaw assets (skills, agents, MCP configs, .env files)
- Copies custom skills directly (format is identical)
- Converts agents (agent.md → SKILL.md with frontmatter)
- Backs up MCP server configs and environment files
- Generates a migration report with post-migration checklist

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

Hard-won discoveries from the deployment process:

| Pitfall | Symptom | Fix |
|---------|---------|-----|
| Missing `channelsEnabled: true` | Messages silently dropped, debug log shows "Channel notifications skipped" | Add to `~/.claude/settings.json` |
| Using `--plugin-dir` with `--channels` | "skipped...from inline" in debug log | Never combine these flags |
| Zombie bun/claude processes | Telegram 409 Conflict error | Kill all processes before restart |
| `setup-token` on headless server | "Raw mode is not supported" error | Run on machine with browser, copy token to server |
| Wrong env var name | Auth fails silently | Use `CLAUDE_CODE_OAUTH_TOKEN` (not `CLAUDE_CODE_USE_CLAUDE_AI_TOKEN`) |
| Mainland China servers | All network checks fail | Use servers in HK, SG, JP, US, EU |

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

开源技能集：在远程服务器上部署 Claude Code 并通过 Telegram 进行远程访问，以及从 OpenClaw 迁移。

> **背景**：2026 年 4 月 5 日起，Anthropic 封禁了 OpenClaw 使用 Claude Pro/Max 订阅。本项目提供基于 Claude Code 原生 Channels 功能的第一方替代方案。

### 技能列表

#### 🚀 [deploy-telegram](skills/deploy-telegram/SKILL.md) — 部署 Telegram 频道

在远程 Linux 服务器上部署 Claude Code，并连接 Telegram 实现远程访问。

**功能：**
- 在服务器上安装 Node.js、Claude Code、tmux 和 Bun
- 通过 OAuth Token 配置身份认证
- 安装官方 Telegram 频道插件
- 配置 systemd 服务实现开机自启
- 自动处理所有交互式对话框

**前置条件：**
- 具有 SSH 访问权限的 Linux 服务器
- Telegram Bot Token（通过 @BotFather 创建）
- Claude OAuth Token（通过 `claude setup-token` 获取）
- 服务器必须能访问：api.telegram.org、github.com、api.anthropic.com

#### 🔄 [migrate-openclaw](skills/migrate-openclaw/SKILL.md) — 迁移 OpenClaw

将 OpenClaw 的技能、代理和配置迁移到 Claude Code 格式。

**功能：**
- 清点所有 OpenClaw 资产（技能、代理、MCP 配置、.env 文件）
- 直接复制自定义技能（格式完全相同）
- 转换代理（agent.md → SKILL.md + YAML 头部信息）
- 备份 MCP 服务器配置和环境变量文件
- 生成迁移报告和迁移后检查清单

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

部署过程中的血泪教训：

| 坑 | 症状 | 解决方案 |
|----|------|----------|
| 缺少 `channelsEnabled: true` | 消息静默丢弃，调试日志显示 "Channel notifications skipped" | 添加到 `~/.claude/settings.json` |
| `--plugin-dir` 与 `--channels` 同时使用 | 调试日志中出现 "skipped...from inline" | 永远不要同时使用这两个标志 |
| 僵尸 bun/claude 进程 | Telegram 409 Conflict 错误 | 重启前先杀掉所有相关进程 |
| 在无头服务器上运行 `setup-token` | "Raw mode is not supported" 错误 | 在有浏览器的机器上运行，将 Token 复制到服务器 |
| 环境变量名错误 | 认证静默失败 | 使用 `CLAUDE_CODE_OAUTH_TOKEN`（不是 `CLAUDE_CODE_USE_CLAUDE_AI_TOKEN`） |
| 服务器 | 所有网络检查失败 | 使用港、新、日、美、欧等地区的服务器 |

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

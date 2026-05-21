# CLAUDE.md rules to install (universal)

Every successful deploy of this skill appends **two** rule blocks to **both** `~/CLAUDE.md` (or `%USERPROFILE%\CLAUDE.md`) and `~/.claude/CLAUDE.md`. The rules are platform-agnostic — they're plain markdown text about agent behavior, not commands.

**Why both files**: Claude Code loads two layers of CLAUDE.md — `~/.claude/CLAUDE.md` (user-level, always loaded) and `~/CLAUDE.md` (project-level, loaded based on launch cwd). On long-running sessions, the model can re-read the user-level file mid-session and that becomes the dominant authority in context. A rule installed only in the project-level file gets effectively shadowed; the silent-drop bug returns.

Both blocks are fenced with HTML markers, so the install step is **idempotent** — re-running on a server that already has the rule is a no-op, and the markers protect adjacent CLAUDE.md content from being clobbered.

---

## Rule 1: Channel Routing Rule

**Purpose**: Force Claude to use the `plugin:telegram:telegram - reply` MCP tool for Telegram replies. Without this, Claude writes a beautiful reply to the terminal that the Telegram user never sees — observed on **every** deploy that omits this rule.

```markdown

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

### Telegram file uploads

User-uploaded files (images, PDFs, xlsx, etc.) arrive at `~/telegram-inbox/`
on Linux/macOS or `%USERPROFILE%\telegram-inbox\` on Windows. **Do not** read
from `~/.claude/channels/telegram/inbox/` — that path triggers a hard-coded
sensitive-file guard that no bypass flag silences. The inbox-mover
(systemd path-unit / launchd WatchPaths / FileSystemWatcher Task) moves files
out of `~/.claude/` within ~50 ms of landing.
<!-- END: channel-routing-rule -->
```

> **Production lesson** (2026-04 multi-server deployment): if the rule is installed only in `~/CLAUDE.md` (project-level), a session that runs for ~1 day starts to drift — the model re-reads `~/.claude/CLAUDE.md` (user-level) during introspection, finds no routing rule there, and the previously-loaded project rule loses dominance. Telegram replies stop going through the reply tool. **Always install in both files**.

> **Cannot fully prevent silent-drop via this rule alone** — after many `compact` operations the model may still forget. The `UserPromptSubmit` hook (see [`architecture-and-design.md`](./architecture-and-design.md) §"Telegram routing hook") is a code-level defense for the same failure mode.

---

## Rule 2: No Interactive Selects / Numbered Pickers (HARD RULE)

**Purpose**: Prevent `AskUserQuestion` and similar widget-driven dialogs from deadlocking the session. Originally documented as a macOS post-deploy lesson (a 1 h 15 min production outage on Mac mini, 2026-05); applies to **all platforms** because the failure mode is in the channel-vs-widget interaction, not the OS.

```markdown

<!-- BEGIN: no-interactive-select-rule -->
## No Interactive Selects / Numbered Pickers (HARD RULE)

**Never invoke `AskUserQuestion`, numbered select dialogs, or any other widget
that waits for local keyboard input — regardless of session mode (terminal,
Telegram channel, anything).**

**Why**: These widgets block the main input stream until someone hits arrow
keys + Enter locally. Inbound channel messages cannot drive them. A select
dialog locked one production deployment for 1 h 15 min; MCP stdio timed out;
the reply tool went silently dead; recovery required killing the daemon and
losing the session's context.

**Instead**: write the question + options as plain prose (with a brief
recommendation up front). Send via the appropriate channel (reply tool in
channel mode, stdout in terminal mode). Parse the answer from the user's
next free-form text message.

**Scope**: Hard rule, no exceptions. Applies even in pure terminal mode — a
channel can be attached later, and any lingering picker locks it out.
<!-- END: no-interactive-select-rule -->
```

> **Production lesson** (2026-05-14 → 2026-05-21 hardening window, Mac mini): a single `AskUserQuestion` widget invocation locked the entire session for 1 h 15 min. MCP stdio reached its idle timeout. The reply tool's response queue silently filled and was dropped. Only `pkill claude` recovered, at the cost of losing session context. The rule promotes the behavior from "best practice" to "deterministic do-not-do".

---

## Install order

In each platform overlay's deploy step:

1. Append Rule 1 to `~/CLAUDE.md` (or `%USERPROFILE%\CLAUDE.md`)
2. Append Rule 1 to `~/.claude/CLAUDE.md`
3. Append Rule 2 to `~/CLAUDE.md`
4. Append Rule 2 to `~/.claude/CLAUDE.md`

Each append uses `grep -q '<!-- BEGIN: <marker> -->'` first to skip if already present. Order doesn't matter (both rules are independent); appending both even if one was already present is safe.

After installing the rules, **restart the daemon** so it reloads CLAUDE.md. The platform overlays handle this as part of the deploy.

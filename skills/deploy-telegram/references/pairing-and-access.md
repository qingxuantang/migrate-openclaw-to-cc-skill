# Pairing and access control

The Telegram plugin enforces access at the bot level: only users explicitly paired via `/telegram:access` can send messages to the Claude session. This page documents the pairing flow and the resulting state file — universal across platforms; only how you send the `/telegram:access` slash command to the daemon differs (see each platform overlay).

## Flow

```
1. Operator finishes deploy steps; daemon shows "Listening for channel messages"
2. Operator opens Telegram, sends ANY message to the bot
3. Bot replies with a 6-character pairing code (e.g. "ef9e47")
4. Operator runs in daemon's session:
   /telegram:access pair <code>
5. Plugin writes <user_id> into access.json's allowFrom list
6. Operator runs:
   /telegram:access policy allowlist
7. Plugin changes dmPolicy from "pairing" to "allowlist"
8. From now on:
   - The paired <user_id> can send messages → routed to Claude
   - Any other sender → silently rejected
```

## State file: `~/.claude/channels/telegram/access.json`

After pairing succeeds, the file looks like:

```json
{
  "dmPolicy": "allowlist",
  "allowFrom": ["123456789"],
  "groups": {},
  "pending": {}
}
```

| Field | Purpose |
|---|---|
| `dmPolicy` | `"pairing"` (default — anyone can request a pairing code) or `"allowlist"` (only `allowFrom` accepted) |
| `allowFrom` | Array of Telegram user IDs (numeric strings) that can DM the bot |
| `groups` | Group chat configuration (advanced; not covered here) |
| `pending` | Pairing codes awaiting acceptance (auto-cleared after `pair`) |

The plugin manages this file directly through the `/telegram:access` skill — manual edits work but are error-prone. Always use the slash commands when possible.

## Why `policy allowlist` is non-optional

In the default `pairing` mode, any Telegram user who discovers the bot can:

1. Send a message → bot generates a pairing code
2. The pairing-code generation **consumes the bot's `getUpdates` channel** and tries to invoke your `/telegram:access pair` flow
3. Even if they can't actually pair (because they don't have access to your terminal), the noise floods your daemon's input stream

Switching to `allowlist` after your real users are paired closes this loop: unknown senders are silently rejected before the message reaches the Claude session.

**Always run `/telegram:access policy allowlist` immediately after pairing.**

## How each platform delivers the pairing commands

The slash commands must be entered **into the daemon's running claude session** (because slash commands are parsed by the local CLI, not by the model — see [`post-deploy-hardening.md`](./post-deploy-hardening.md) §"Slash commands over Telegram"). Each platform has a different mechanism:

| Platform | Delivery |
|---|---|
| **Linux** | `tmux send-keys -t claude '/telegram:access pair <code>' Enter` |
| **macOS** | `tmux send-keys -t claude '/telegram:access pair <code>' Enter` |
| **Windows** | **Human types it** in the visible PowerShell window spawned at deploy time. (No tmux on Windows; no reliable headless keystroke injection.) |

After both commands run successfully, send a test message from Telegram and confirm a reply lands on your phone. This is the **end-to-end smoke test** — the only way to verify all layers (Telegram API, bun, claude, reply tool, network) work together.

## Re-pairing

If you need to re-pair (lost phone, regenerated bot, want to add a second user):

1. Stop daemon (or accept that incoming messages are paused for a few minutes)
2. Edit `~/.claude/channels/telegram/access.json` directly:
   - To add a user: append their user_id to `allowFrom`
   - To reset: set `dmPolicy: "pairing"`, clear `allowFrom: []`, clear `pending: {}`
3. Restart daemon
4. If reset: re-run the full pairing flow from step 1 of "Flow" above

Or: kill the daemon, delete `access.json`, restart. The plugin will recreate it with defaults (`dmPolicy: "pairing"`) on first message.

## Finding your Telegram user ID

Useful for pre-flight (skill validation) or for re-pairing after a reset. Two methods:

1. **`@userinfobot`**: open Telegram, search for `@userinfobot`, send any message. It replies with your numeric user ID.
2. **From access.json**: if you've ever paired before, your user ID is in `allowFrom`.

The user ID is a pure numeric string (e.g. `123456789`), 7–10 digits typically. Stable for life — does not change if you change your Telegram username.

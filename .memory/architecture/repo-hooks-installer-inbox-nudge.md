---
title: Repo Hooks Installer — Inbox Nudge
type: note
permalink: dispatch/architecture/repo-hooks-installer-inbox-nudge
source_paths: [Dispatch/Services/MCPBus/RepoHooksInstaller.swift]
source_paths_inferred: false
source_sha: 773387c86eee060e6d47db6e231db0763e659f56
created: 2026-07-30
updated: 2026-07-30
---

RepoHooksInstaller.swift is the opt-in, default-OFF nudge half of the install path: `.mcp.json` gives a repo's Claude Code session the four bus verbs, but nothing makes the session ever call `check_messages` on its own. Dogfooding found the gap — a question could sit in a receiving session's inbox for an entire conversation. The fix merges three Claude Code hooks (SessionStart, UserPromptSubmit, Stop) into the repo's own `.claude/settings.local.json`, all running the same self-contained shell command.

## Observations
- [fact] Three hook events share one command: SessionStart and UserPromptSubmit surface one line of pending-question context (startup and per-turn respectively); Stop is the end-of-turn drain that empties the inbox before control returns to the human #hooks
- [constraint] The hook command NEVER blocks or fails a session: curl --max-time 2, every error swallowed, exit 0 on every path — a down bus, a missing entry, no python3 all resolve to silence, never a broken session #reliability
- [constraint] The command carries NO interpolated data — no project name, path, token, or id is embedded; everything is read at runtime from $CLAUDE_PROJECT_DIR/.mcp.json, which is also why there is no shell-injection surface #security
- [fact] The endpoint the hook polls returns a COUNT only, never message content, so a shell script never holds question text #privacy
- [gotcha] Stop hooks have a different stdout contract than SessionStart/UserPromptSubmit: Claude Code discards a Stop hook's plain stdout (debug log only) unless it emits the JSON decision form `{"decision":"block","reason":"…"}` — so the Stop variant wraps the same sentence in that object #hooks

## Relations
- relates_to [[Repo Install Architecture — .mcp.json Merge Contract]]

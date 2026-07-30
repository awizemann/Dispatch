---
title: Memophant project namespace rename requires the GUI, not file edits
type: note
permalink: dispatch/operations/memophant-project-namespace-rename-requires-the-gui-not
source_paths: [.mcp.json, .cursor/mcp.json, .codex/config.toml, .gemini/settings.json, .claude/memophant-memory-hook.sh, AGENTS.md]
source_paths_inferred: true
source_sha: f83faa8105b92054c6b79a9b0ebfb028d1718ea1
created: 2026-07-30
updated: 2026-07-30
---

Renaming a repo's Memophant project namespace is NOT durable by hand-editing the generated files. Memophant.app regenerates `.mcp.json`, `.cursor/mcp.json`, `.codex/config.toml`, `.gemini/settings.json`, `.claude/memophant-memory-hook.sh`, and the `AGENTS.md` project references from its OWN stored project registration (those files carry a `# managed by Memophant.app (regenerated)` marker). Sed/Edit on them reverts within the session while the app runs.

## Observations
- [gotcha] During the 1.0 release, a sed renamed the `--default-project` value and the `AGENTS.md` sub-project refs to the new namespace; the release commit captured the new name (so `origin/main` @ 9bdad0f is clean), but the running Memophant.app immediately regenerated all six managed files back to the old name in the working tree #release
- [fact] The `.memory` tier permalinks DID stick at the new namespace (35/35) and `list_memory_projects` reflected it — so the memory tier and MCP resolution rename cleanly from files alone; only the app-regenerated config files revert #namespace
- [gotcha] Durable fix: rename the linked project inside the Memophant.app GUI. Until then the six managed files keep reverting, and a `git add -A` + push would republish the old name into `.mcp.json`/`AGENTS.md`. Do not hand-edit them expecting it to hold #workflow

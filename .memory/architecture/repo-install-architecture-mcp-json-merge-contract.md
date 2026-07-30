---
title: Repo Install Architecture — .mcp.json Merge Contract
type: note
permalink: dispatch/architecture/repo-install-architecture-mcp-json-merge-contract
source_paths: [Dispatch/Services/MCPBus/RepoMCPInstaller.swift]
source_paths_inferred: false
source_sha: 773387c86eee060e6d47db6e231db0763e659f56
created: 2026-07-30
updated: 2026-07-30
---

RepoMCPInstaller.swift owns the ONLY file Dispatch writes inside a user's repo: a value-faithful merge of exactly one key, `"dispatch"`, into that repo's `.mcp.json` under `mcpServers`. This is a pure-function transform over JSON bytes (no file system, no state) so every merge rule is unit-testable from raw `Data`.

## Observations
- [constraint] VALUE-FAITHFUL MERGE: only the `dispatch` key under `mcpServers` is added/replaced — every other server and every unknown top-level key round-trips untouched #install
- [decision] FAIL CLOSED on invalid JSON: a `.mcp.json` Dispatch cannot parse is refused, never clobbered — surfaced as an `.invalid` install state #safety
- [decision] Dispatch only takes the key if it wrote it: a `dispatch` entry it did not create is a naming conflict (`.conflict`) and install refuses until the human explicitly asks for a replace; uninstall leaves foreign entries alone #consent
- [convention] Uninstall deletes only what Dispatch created — the key is removed, and the FILE itself is unlinked only when removing that key leaves a literal empty `{"mcpServers":{}}` shell AND the ledger says Dispatch created the file #cleanup
- [fact] The URL embeds the project's bus token, so it is a credential: never logged, never in an error message, never in a health event — errors carry the file PATH only #security

## Relations
- relates_to [[Decision: MCP Bus via Official Swift SDK]]
- relates_to [[Decision: Bus Capability Tokens Not Keychain]]

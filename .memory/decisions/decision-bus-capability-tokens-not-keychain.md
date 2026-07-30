---
title: Decision: Bus Capability Tokens Not Keychain
type: note
permalink: dispatch/decisions/decision-bus-capability-tokens-not-keychain
tags: [decision, security, bus, mcp]
created: 2026-07-05
updated: 2026-07-29
---

Ruled at the P2 bus-core GO (2026-07-05). Bus messages remain data-not-commands per guardrails §7-8; agents are told the bus is human-visible and arbitrable (transparency invariant added to the BUS PROTOCOL prompt section).

## Observations
- [decision] Bus credentials are 128-bit CAPABILITY TOKENS carried in the MCP config URL, NOT Keychain items — the CLI's only injection channel for an MCP credential is that file, and the token secures a localhost capability, not a durable vendor credential #tokens
- [decision] AMENDED by the Dispatch pivot (2026-07-28): tokens are now DURABLE and PER-PROJECT, written into the repo's own `.mcp.json` (`http://127.0.0.1:<port>/bus/<token>`), because Dispatch serves EXTERNAL Claude Code sessions it never spawned — there is no per-launch attach to scope them to. The capability-token reasoning is unchanged; the lifetime is not. Consequences: the token lives in a user-readable repo file (so it must never be committed or logged), and rotation/uninstall must revoke the listener route and rewrite the entry #tokens
- [decision] Bus identity is STRUCTURAL: one MCP Server+transport pair per project endpoint, routed by the unguessable URL token, handlers closing over that project's fixed identity — project A physically cannot reach B's endpoint; no header trust involved #identity
- [gotcha] mcp swift-sdk 0.12.1 server hazards (verified in source): transports ship LISTENER-LESS (bring your own HTTP server); a Server instance rejects a second initialize (CLI respawn ⇒ recreate the pair); StatelessHTTPServerTransport keys response waiters by JSON-RPC id — SHARING one transport across clients cross-wires responses #sdk
- [convention] Do NOT 'fix' the bus token into the Keychain in a future audit — the secrets→Keychain rule applies to vendor/user credentials; a localhost capability token with route-revocation and rewrite-on-rotate is the correct pattern here #guardrails

## Relations
- relates_to [[Decision: MCP Bus via Official Swift SDK]]
- relates_to [[File Safety and Security Rules]]


**Shipped (commit 3c13c2d) — probe-verified CLI facts:** stateless streamable HTTP works against claude 2.1.201 end-to-end; the CLI re-initializes on every process run (pair recreation is mandatory); it probes GET for SSE and tolerates 405; sends no Origin header; MCP tools must be pre-allowed via --allowedTools in -p mode or they permission-prompt. Known residues: an ordinary crash keeps the endpoint/config file until next detach (dead process, same-user 0600 exposure — acceptable); MCPBusListener.shutdownAll has no app-teardown caller yet (pre-existing gap, listed for Phase 4 polish).

---
title: Decision: MCP Bus via Official Swift SDK
type: note
permalink: dispatch/decisions/decision-mcp-bus-via-official-swift-sdk
tags: [decision, mcp, bus]
created: 2026-07-05
updated: 2026-07-30
---
**Why in-process hosting:** a separate bus daemon adds process supervision, versioning, and crash-recovery surface with zero user-visible benefit; the app is always running when the bus must answer. Decided 2026-07-05, and it survived the Dispatch pivot unchanged — only the CLIENTS changed (2026-07-28): Dispatch no longer spawns agents, so the connecting MCP clients are the user's OWN Claude Code sessions, reaching the bus through a `dispatch` http entry Dispatch merges into each repo's `.mcp.json` instead of an ephemeral `--mcp-config` at spawn.

## Observations
- [decision] The message bus is an MCP server HOSTED BY the app process using the official modelcontextprotocol/swift-sdk (0.12.x), exposed over streamable HTTP on 127.0.0.1 at a kernel-assigned port, one route per project (`/bus/<token>`) #bus
- [decision] The agent-facing tool surface is exactly four verbs: `ask_agent`, `answer_agent`, `check_messages`, `list_projects` (DispatchEndpoint.tools). Anything larger was the prior work-queue/gate surface from an earlier in-app prototype and is gone #tools
- [fact] The essential requirement was only ever that AGENTS are separate processes connecting as MCP clients; hosting the server in-app avoids IPC and the lifecycle management of a second daemon while keeping identical semantics — and it is what makes serving external sessions cheap #rationale
- [gotcha] swift-sdk is pre-1.0 — breaking changes possible in minors; pin it, and keep the transport-level hazards in mind: transports ship LISTENER-LESS (MCPBusListener is our own SwiftNIO server), and a Server instance rejects a second initialize #pinning

## Relations
- relates_to [[Decision: Bus Capability Tokens Not Keychain]]
- relates_to [[Sendable DTO Boundary Architecture]]

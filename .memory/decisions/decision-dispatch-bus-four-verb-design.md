---
title: Decision: Dispatch Bus Four-Verb Design
type: note
permalink: dispatch/decisions/decision-dispatch-bus-four-verb-design
source_paths: [Dispatch/Services/MCPBus/DispatchEndpoint.swift, Dispatch/Services/MCPBus/DispatchRouter.swift]
source_paths_inferred: false
source_sha: 773387c86eee060e6d47db6e231db0763e659f56
created: 2026-07-30
updated: 2026-07-30
---

The entire agent-facing surface of Dispatch's bus is four MCP tools, implemented in DispatchEndpoint.swift and routed by DispatchRouter. There is no work queue, no task/board surface, and no larger protocol — every prior larger surface belonged to an earlier in-app prototype and is gone.

## Observations
- [decision] Exactly four verbs: ask_agent, answer_agent, check_messages, list_projects — no fifth tool, no admin/config verb on the same endpoint #tools
- [decision] ask_agent is sync-when-live: it accepts an optional wait_seconds and long-polls, returning status:"answered" with the answer inline if it arrives in time, else status:"pending" — the asking session is never told the question was lost if the target is offline #longpoll
- [decision] answer_agent resolves a SPECIFIC question_id rather than sending a free reply — this is the structural fix for flat-bus crossed-traffic pathologies (a reply always closes the exact question it answers, never opens a new one) #protocol
- [fact] Answers and inbound questions cross into the receiving session's context inside BusPromptFraming's untrusted-content markers, identical framing for both ask_agent's inline answer and a check_messages delivery — data, never instructions #security
- [constraint] The tool surface is per-project: projectID scopes every call, so one endpoint instance physically cannot answer for or leak into another project #identity

## Relations
- relates_to [[Decision: MCP Bus via Official Swift SDK]]
- relates_to [[Decision: Bus Capability Tokens Not Keychain]]
- relates_to [[Field report: bus coordination failure modes and the improvement backlog]]

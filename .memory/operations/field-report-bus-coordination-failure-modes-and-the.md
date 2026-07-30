---
title: Field report: bus coordination failure modes and the improvement backlog
type: note
permalink: dispatch/operations/field-report-bus-coordination-failure-modes-and-the
source_paths: [Dispatch/Services/MCPBus/DispatchRouter.swift, Dispatch/Services/MCPBus/BusProtocolText.swift]
source_paths_inferred: false
source_sha: a71c2b9eeb17dacf71380d0688ea097252aad6be
created: 2026-07-15
updated: 2026-07-30
reviewed: 2026-07-23
reviewed_by: audit:claude-code (background)
---
**DISTILLED 2026-07-30 from a much longer field report on an earlier in-app multi-agent prototype's bus.** The failure modes below were observed on that prototype's flat message bus, but the coordination pathology is protocol-shaped, not runtime-shaped, and it applies to Dispatch: a FLAT bus with no reply linkage makes agents answer with a fresh ask instead of an answer, spawning parallel open questions and crossed/stale traffic. Dispatch's `answer_agent`-by-`question_id` design and exactly-once outcome reporting are the direct answer to exactly this failure class.

## Observations
- [gotcha] A flat bus (no reply linkage, no supersede marker) lets a multi-round negotiation spawn parallel OPEN questions, because a reply arrives as a fresh ask instead of an explicit answer to the original question — any staleness/nudge monitor built on "still open" then correctly nudges questions that are actually resolved, generating more crossing traffic #bus
- [decision] Dispatch's fix is structural, not a monitor: `answer_agent` answers a specific `question_id`, so a reply always resolves the exact question it responds to rather than opening a new one; delivery is exactly-once per outcome, closing the crossed-traffic class at the protocol level rather than patching it with better nudge heuristics #bus
- [fact] The original incident was a cross-agent contract negotiation that converged correctly but expensively — crossed messages, agents acting on superseded positions, false stall nudges — which is the motivating case for the `question_id`-linked design #history

## Relations
- relates_to [[Decision: MCP Bus via Official Swift SDK]]

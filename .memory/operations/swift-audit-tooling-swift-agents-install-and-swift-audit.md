---
title: Swift audit tooling — swift-agents install and /swift-audit skill
type: note
permalink: dispatch/operations/swift-audit-tooling-swift-agents-install-and-swift-audit
tags: [tooling, audit, agents]
grounding: durable
created: 2026-07-14
updated: 2026-07-14
---

## Observations
- [fact] Techopolis swift-agents specialists live in ~/.claude/agents/ (16 agents) with 10 reference skills symlinked into ~/.claude/skills/ from ~/.agents/skills/ #tooling
- [decision] The swift-agents global hooks (UserPromptSubmit + SubagentStop) were removed 2026-07-14 at Alan's request — per-prompt token overhead; the agents and skills remain and are leveraged via /swift-audit and project guardrails instead #agents
- [gotcha] Do not orchestrate through the swift-lead agent — subagents cannot spawn subagents; run specialists directly from the main conversation via parallel Agent calls, using swift-lead's routing table as the map #agents
- [fact] /swift-audit (global skill, ~/.claude/skills/swift-audit/) runs a multi-specialist read-only audit: platform/domain detection via signal greps, parallel specialist fan-out with project-convention briefs, synthesized P1/P2/P3 report written to audits/ #audit
- [gotcha] This app ships no PrivacyInfo.xcprivacy — flagged during the swift-audit dry run (2026-07-14); required-reason API coverage applies to macOS too #ship-readiness

## Relations
- relates_to [[Build and Toolchain Rules]]
- relates_to [[Build Environment]]

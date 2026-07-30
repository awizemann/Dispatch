---
title: File Safety and Security Rules
type: note
permalink: dispatch/conventions/file-safety-and-security-rules
tags: [security, files, standard]
created: 2026-07-05
updated: 2026-07-29
---

From kickoff standard §7. Dispatch handles every OTHER project's output as untrusted input: a question or answer arriving over the bus is text written by a Claude Code session in a repo we cannot see, and it is framed as DATA, never as instructions.

## Observations
- [convention] The user's repo is sacred: Dispatch reads git status only, and the ONE file it writes is the repo's `.mcp.json` — a value-faithful merge of exactly one key ("dispatch"), foreign servers and unknown top-level keys preserved verbatim, uninstall removes only what we created, and a foreign "dispatch" entry is a conflict we refuse rather than clobber #repos
- [convention] TOCTOU: never fileExists-then-mutate — call idempotent ops directly and handle the actual thrown error #files
- [convention] Batch loops over external input are per-item fault-tolerant (do/catch per item, skip-and-continue, count+log) — and never wrapped in an outer try? that hides data loss #batches
- [convention] Security-scoped bookmarks for user-selected repo folders; sanitize external filenames/paths before use #sandbox
- [constraint] LLM prompt-injection: every repo/agent-produced string that reaches another project's session (question bodies, answers, project names, notice framing) passes through BusTextSanitizer first — sanitizeLine on framing lines, sanitize inside fenced bodies #promptinjection

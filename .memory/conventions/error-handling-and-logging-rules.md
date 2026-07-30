---
title: Error Handling and Logging Rules
type: note
permalink: dispatch/conventions/error-handling-and-logging-rules
tags: [errors, logging, standard]
created: 2026-07-05
updated: 2026-07-29
---

From kickoff standard §8, adapted: Dispatch serves concurrent MCP callers it does not own — a swallowed error on one project's route must never silently strand a long-polling caller or drop a durable question. Surface it as a refusal the caller can read, and as bus health in the UI.

## Observations
- [convention] Every catch logs via logger.error/.warning, re-throws, or returns .failure — never swallow silently; bare try? only for truly ignorable ops #errors
- [convention] logger.warning for expected conditions (file missing, timeout); logger.error for the unexpected (encode failure, logic error) #levels
- [convention] No print() in production — os.Logger only; print allowed only in #Preview blocks and test helpers #logging
- [convention] Multi-step operations roll back on failure; cleanup on every early-return path via defer #rollback
- [convention] Redact user file paths and PII in production logs — Dispatch logs must never contain repo file contents, bus question/answer bodies, or credentials (the bus token is a credential: log the project, never the URL) #privacy

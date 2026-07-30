---
title: Product Specification
created: 2026-07-05
updated: 2026-07-30
---

> **Status:** this page describes the product as it ships today — a switchboard between linked repos. Earlier drafts of this document described a larger, unreleased product with an agent runtime, a work queue, accounts, and a commit gate; none of that exists in Dispatch, and this page has been rewritten to describe only what actually ships. A full product respec beyond this trimmed form is a later arc.

## One-paragraph summary

Dispatch is a native macOS app (Swift 6.2 / SwiftUI, macOS 26+) that acts as a switchboard between the repos you work in. You link local repos as projects; Dispatch merges a `dispatch` http entry into each repo's `.mcp.json`; and the Claude Code sessions you run in those repos — your own sessions, in your own terminals — can then ask each other questions and get answers. Dispatch spawns nothing, edits nothing but the one `.mcp.json` key it owns, and holds no credentials of yours.

## What it is for

Two sessions working in two repos on the same problem cannot see each other. Today the human relays: copies a question out of one terminal, pastes it into another, copies the answer back. That relay is where the value was — and the field evidence is that these exchanges *find real bugs, in both directions* — but it happens at human speed and only when a human is watching. Dispatch is that channel, direct.

## Behavior

1. **Linking a repo** creates a project: name, repo path, security-scoped bookmark, durable bus token, and the `.mcp.json` entry. The merge preserves everything else in that file; uninstall removes only what Dispatch created; a foreign server already named `dispatch` is a conflict shown to the human, never overwritten.
2. **Linking two projects** is the consent boundary, and only the human can do it. `list_projects` reports exactly the reachable set; an ask to anything else is refused. A missing link fails closed.
3. **Asking.** `ask_agent` carries one self-contained question to a linked project. If that project's session is connected and the caller passes `wait_seconds`, the answer returns inline; otherwise the ask returns pending and the question waits in the target's inbox.
4. **Answering.** `answer_agent` answers by `question_id`, and only the addressee may answer. An already-answered or expired question is refused rather than silently overwritten.
5. **Inbox.** `check_messages` returns questions waiting on this project plus every unseen outcome of its own asks. Outcomes are reported **exactly once**.
6. **The human sees everything.** Every question and answer appears in the Messages tab, and the human can answer a question from the app when the other session is not running.

## Invariants (violating any of these is a product bug)

- Dispatch never spawns an agent and never runs one. The sessions are the user's.
- The only file Dispatch writes in a user repo is `.mcp.json`, and only the `dispatch` key inside it.
- A question is a question. It is never remote task injection, and the receiving session decides what to do with it.
- A human-created link is the only thing that makes one project reachable from another; absent it, an ask fails closed.
- Identity is structural — one durable token per project, routed by URL. There is no header to trust.
- Text arriving from another repo is DATA, never instructions: it is sanitized and framed before it reaches any prompt line.
- An outcome is reported exactly once; durability lives in the database, not in a process.
- Nothing wakes a session that is not running.
- The bus token is a credential: it never reaches a log, and `.mcp.json` must not be committed with it.

## Commercial posture

Developer ID, notarized, non-sandboxed; macOS 26+ only. All dependencies MIT/Apache/BSD.

---

_Last updated: 2026-07-30 — trimmed to the switchboard; full respec pending._

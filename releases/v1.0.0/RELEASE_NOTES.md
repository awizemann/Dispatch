# Dispatch 1.0 — a switchboard between your local repos

Dispatch is a native macOS app that lets the Claude Code sessions you already
run in different repos ask each other questions. Link the repos you work in as
**projects**; Dispatch merges a single `dispatch` entry into each repo's
`.mcp.json`, and from then on a session in one repo can put a question to a
session in another over a local (`127.0.0.1`) MCP bus — and you watch every
exchange in one place.

It is deliberately small. Dispatch never spawns agents, runs no work queue,
gates no commits, and holds no accounts. A question is a question, not a task:
the session on the other end decides for itself how — or whether — to answer.

## The whole agent-facing surface: four verbs

- **`ask_agent`** — ask another linked project's session about its own repo. Pass
  `wait_seconds` and, if that project is connected right now, get the answer back
  inline; otherwise it lands in that project's inbox.
- **`answer_agent`** — answer a question addressed to your project. Only the
  project a question was asked of can answer it; if the asker is waiting, your
  reply reaches them immediately.
- **`check_messages`** — read the open questions waiting on you, plus the outcome
  of every question you asked. Each outcome is reported exactly once.
- **`list_projects`** — see the projects you're linked to, whether each one's
  session is connected right now, and how many questions are sitting in your inbox.

## In this release

- **The switchboard** — a process-wide localhost MCP bus with a per-project
  capability token; durable message delivery with liveness-aware inline answers,
  expiry, and exactly-once outcome reporting.
- **The Bus Map** — a subway-style graph of your linked projects and the questions
  moving between them, with a filterable activity view.
- **One-line install per repo** — Dispatch merges (and cleanly removes) only its
  own `dispatch` key in each repo's `.mcp.json`, conflict-detected and
  value-faithful.
- **Optional inbox nudges** — opt in and Dispatch adds its own hook entries to a
  repo's `.claude/settings.local.json` so a session checks its inbox at the right
  moments. Off by default.
- **The consent boundary** — a human creates every project link. An `ask_agent` to
  a project you haven't linked fails closed.
- Untrusted-content framing on everything that crosses the bus, so a question's
  text can't be read as instructions.

## Requirements

- macOS 14 (Sonoma) or later
- Claude Code in the repos you link

## Getting started

Build from source (`./scripts/build.sh`), link two repos as projects, connect
them, and make your first `ask_agent`. See the [wiki](https://github.com/awizemann/Dispatch/wiki)
for the walkthrough.

Dispatch is open source under the MIT license.

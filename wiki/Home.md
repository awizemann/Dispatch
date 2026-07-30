# Dispatch Wiki

Long-form reference documentation for **Dispatch**, maintained alongside the code.

Dispatch is a native macOS switchboard between your repos. You link local repos as projects; Dispatch merges a `dispatch` entry into each repo's `.mcp.json`; and the Claude Code sessions you run in those repos — in your own terminals, started by you — can then ask each other questions and get answers.

Dispatch does **not** spawn agents, run a work queue, gate commits, or manage accounts. It carries questions between sessions that would otherwise have no way to talk.

## Start here

- [Getting Started](Getting-Started) — build it, link two repos, make the first ask.
- [How Dispatch Works](How-Dispatch-Works) — the switchboard mechanism: the bus, the localhost MCP transport, identity, delivery, and the untrusted-content framing.
- [Linking Projects](Linking-Projects) — the consent boundary: how a repo becomes a project, and how two projects become reachable from each other.
- [The Four Verbs](The-Four-Verbs) — `ask_agent`, `answer_agent`, `check_messages`, `list_projects`, argument by argument.
- [Architecture Overview](Architecture-Overview) — how the whole app is put together.

## The four verbs

Everything an agent can do on the bus:

| Tool | What it does |
| --- | --- |
| `list_projects` | The projects this one is LINKED to — the only ones reachable. Reports who is connected right now. |
| `ask_agent` | Ask a linked project a question. With `wait_seconds`, waits inline for the answer when that project is connected; otherwise returns `{status:"pending", question_id}`. |
| `answer_agent` | Answer a question addressed to THIS project, by `question_id`. |
| `check_messages` | This project's inbox: questions waiting on you, plus outcomes of your own asks (answers, expiries). Each outcome is reported exactly once. |

See [The Four Verbs](The-Four-Verbs) for the full detail.

## Reference

- [Product Specification](product-specification) — what Dispatch is, its behavior, and its invariants.
- [Technical Specification](technical-specification) — the implementation, layer by layer.
- [Wiki Maintenance](Wiki-Maintenance) — how this wiki is edited and kept safe.

---
_Last updated: 2026-07-30._

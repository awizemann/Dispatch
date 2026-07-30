# Security Policy

## Supported versions

Dispatch is pre-1.0. Only the latest release on `main` is supported — please update before reporting.

## Reporting a vulnerability

Please **do not** open a public issue for a security vulnerability. Instead, use [GitHub's private vulnerability reporting](https://github.com/awizemann/Dispatch/security/advisories/new) for this repository, or email the maintainer directly (see the GitHub profile at [github.com/awizemann](https://github.com/awizemann) for contact info).

Include what you can:

- A description of the issue and its impact
- Steps to reproduce (ideally with two linked repos, if the bus is involved)
- Affected version / commit SHA

You should get an initial response within a few days.

## Scope notes

A few things about Dispatch's design that are relevant to security reports:

- **The bus is localhost-only.** Dispatch's MCP server binds to `127.0.0.1` on a kernel-assigned port and is never reachable from the network. Anything that lets a request reach the bus from outside the local machine is a valid report.
- **Identity is a token in the URL.** Each linked project's `/bus/<token>` route is protected only by that token (a durable 128-bit id) — there's no additional header or session concept. Treat a repo's `.mcp.json` `dispatch` entry as a credential; a way to obtain or guess another project's token without local access to its `.mcp.json` is a valid report.
- **The consent boundary is human-created links.** `ask_agent` should never reach a project that hasn't been explicitly linked by a person in the app. A way to reach an unlinked project, or to have Dispatch write outside the `dispatch` key in `.mcp.json` (or outside its own hook markers in `.claude/settings.local.json`), is a valid report.
- **Dispatch never executes agent-controlled shell commands.** The optional check-messages hooks it can install run a fixed, non-interpolated command — no project name, path, token, or message content is ever substituted into it. A way to get arbitrary or attacker-influenced content into that command is a valid report.
- Dispatch holds no API keys, no credentials for third-party services, and has no server-side or cloud component — reports should be scoped to the local app and the local bus.

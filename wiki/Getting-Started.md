# Getting Started

This guide gets you building Dispatch locally, linking two repos, and watching one Claude Code session ask the other a question.

## Prerequisites

- **macOS 26 (Tahoe) or later**
- **Xcode 27 beta** at `/Applications/Xcode-beta.app` — `xcode-select` points at CommandLineTools on this machine, so `DEVELOPER_DIR` must be set explicitly (the build scripts do it for you).
- **Claude Code CLI** installed (`claude` on `$PATH`) — Dispatch never spawns it, but you need it to *be* the sessions on either end. Verify: `claude --version`.
- **Two git repositories** you actually work in. One repo alone has nobody to ask.

## Build Dispatch

```bash
git clone https://github.com/awizemann/Dispatch.git
cd Dispatch
./scripts/build.sh
```

`scripts/build.sh` is the commit gate: it runs a **Release compile check first** (`#Preview` bodies are type-checked in Release, so a Debug-only reference breaks only Release and stays invisible otherwise), then the Debug `build test` pass. Both use an isolated DerivedData at `/tmp/dispatch-ci-dd` so they never share build state with the Xcode GUI.

For a dogfood copy that will not fight your installed build:

```bash
./scripts/build-detached.sh
```

In Xcode: scheme **Dispatch**, destination **My Mac**, Cmd+B / Cmd+R. All configurations sign with Developer ID (see `scripts/SIGNING.md`) — do not revert Debug to ad-hoc signing, or keychain and TCC grants reset on every rebuild.

## First steps in the app

### 1. Link your repos

Dispatch opens on the Projects rail. Click **+** and pick a git repository folder. The card shows real git status (branch, dirty count, unpushed).

Repeat for the second repo. A project is just: a name, a repo path, a security-scoped bookmark, and a durable bus token.

### 2. Install the bus entry

Linking a project merges one key into that repo's `.mcp.json`:

```json
{ "mcpServers": { "dispatch": { "type": "http",
  "url": "http://127.0.0.1:<port>/bus/<token>" } } }
```

The merge is value-faithful: your own servers and any unknown top-level keys survive verbatim, uninstall removes only the `dispatch` key, and a *foreign* server already named `dispatch` is reported as a conflict rather than clobbered.

The URL embeds the project's bus token. **Do not commit it** — treat `.mcp.json` as carrying a credential, and let the URL be the only place the token appears.

### 3. Create the link between two projects

`ask_agent` reaches nothing until you say two projects may talk. Open the second repo's project card, choose Edit, and use **"+ Link a project…"** to pick the first one — that's the consent boundary, and only the human can create it. Without it, an ask fails closed — a missing link is a refusal, never a silent drop. See [Linking Projects](Linking-Projects) for the full mechanics.

### 4. Start Claude Code in each repo, as usual

```bash
cd ~/Developer/repo-a && claude
```

Nothing special: your own terminal, your own session. It picks up the `dispatch` server from `.mcp.json` on start. Ask it to run `list_projects` and it will report the projects it is linked to and whether each is connected right now.

### 5. Make the first ask

In repo A's session:

> Use `ask_agent` to ask repo-b whether its `/v2/orders` response still includes the `legacy_id` field, and wait for the answer.

If repo B's session is connected, pass `wait_seconds` and the answer comes back inline. If it is not, the ask returns `{status:"pending", question_id}`, the question sits in repo B's inbox, and repo B picks it up on its next `check_messages`. The answer reaches repo A the same way.

Watch both sides in the app's **Messages** tab. Every question and answer is visible to you, and you can answer one yourself from the app if the other session is not around.

### 6. What to ask, and what not to

A question is a question, not a task. Ask about things that live in the *other* repo — its contract, its behavior, whether a change is safe there. The other session cannot see your repo or your conversation, so make each question self-contained.

## Running tests

Dispatch uses **Swift Testing** (`@Suite` / `@Test` / `#expect`), not XCTest. `./scripts/build.sh` builds and runs the suite. To isolate one failure:

```bash
xcodebuild -only-testing:DispatchTests/<SuiteStructName>/<testName> ...
```

Beware the zero-select trap: a `-only-testing:` selector that matches nothing still prints `** TEST SUCCEEDED **`. Confirm the test name actually appears in the log before trusting a green. Suite *struct* names are not file names.

## Verifying the UI

`--mock-scenario` launches the app against scripted actor fakes — no persistence, no live bus traffic — which is how UI changes get verified headlessly. See `.claude/skills/verify/SKILL.md`. Launch through Launch Services (`open -n <app> --args --mock-scenario`), never by exec'ing the binary while another Dispatch instance runs, and match windows by PID.

## Troubleshooting

**The session doesn't see the dispatch tools.** Check the repo's `.mcp.json` actually holds the `dispatch` key and that the port matches the running app — a stale entry from a previous run points at a dead port. Re-install from the project card. Restart the Claude Code session after any change: MCP servers are read at start.

**An ask is refused.** Almost always the missing link. `list_projects` reports exactly what is reachable; anything else is refused by design.

**A pending ask never comes back.** The other project has to *run* `check_messages` — nothing wakes a session that isn't there. Outcomes are reported exactly once, so if a session read the outcome and dropped it, it is gone from the inbox.

**Database is locked.** GRDB runs in WAL mode; this is normal under concurrent load. If it persists, quit fully and relaunch, and check for an orphaned process (`ps aux | grep Dispatch`).

## Next steps

- **[How Dispatch Works](How-Dispatch-Works)** — the switchboard mechanism in full: transport, identity, delivery, and the untrusted-content framing.
- **[Linking Projects](Linking-Projects)** — the consent boundary in detail, including unlink and delete behavior.
- **[The Four Verbs](The-Four-Verbs)** — every tool's arguments and outcomes.
- **[Architecture Overview](Architecture-Overview)** — how the pieces fit together.
- **[Technical Specification](technical-specification)** — implementation detail.

_Last updated: 2026-07-30._

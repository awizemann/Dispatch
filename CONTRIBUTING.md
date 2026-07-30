# Contributing to Dispatch

Thanks for the interest. Dispatch is a native macOS switchboard between local repos — it links repos as projects and lets the Claude Code sessions running in each one ask each other questions over a small app-hosted MCP bus. This doc covers what you need to build, contribute, and ship changes that fit the project.

## Getting started

**Requirements:**

- macOS 14 (Sonoma) or later
- Xcode 27 (beta) or later — Swift 6 strict concurrency
- The [Claude Code](https://claude.com/claude-code) CLI on your `$PATH` if you want to exercise the bus end to end (`claude --version` to check)
- Two git repositories to link as projects — one repo alone has nobody to ask

**First clone:**

```bash
git clone https://github.com/awizemann/Dispatch.git
cd Dispatch
./scripts/build.sh
```

`Dispatch.xcodeproj` is checked into the repo directly — there's no project-generation step to run. `./scripts/build.sh` runs a Release compile check first, then a Debug `build test` pass; it's the same gate a commit is expected to pass. For a dogfood copy that won't collide with an app you already have installed, use `./scripts/build-detached.sh`.

All build configurations sign with a Developer ID identity (see [`scripts/SIGNING.md`](scripts/SIGNING.md)). If you don't have that identity, point `DEVELOPMENT_TEAM` / `CODE_SIGN_IDENTITY` at your own team for local Debug builds — just don't commit that change.

## Architecture at a glance

Dispatch follows an `@Observable` / `@MainActor` store layer over protocol-seamed services and actors — see [`CLAUDE.md`](CLAUDE.md) for the project's conventions where they differ from typical SwiftUI/macOS patterns (persistence, design tokens, file ops, logging). The deeper "why does this live here, how do I extend it" reference lives on the [GitHub Wiki](https://github.com/awizemann/Dispatch/wiki) — start at [Architecture Overview](https://github.com/awizemann/Dispatch/wiki/Architecture-Overview).

## Guidelines

- **Swift 6 strict concurrency.** No synchronous file I/O on `@MainActor`. View bodies never spawn subprocesses or hit the filesystem.
- **GRDB, not SwiftData.** Reads go through the logged `safeRead` helpers in `Dispatch/Persistence/PersistenceReading.swift` — never bare `try?` on a database read or write.
- **Design tokens, not magic numbers.** UI uses `Theme` / `Palette` / `Metrics` / `Motion` / `Shadows` / `TypeScale` from `Dispatch/DesignSystem/`. Off-scale fonts use the `TextStyle(TypeScale.ui(N, .weight))` factory, never raw `.font(.system(size:))`.
- **File ops.** No FileCoordinator/AsyncFileManager — use `PathSafety` and `RepoBookmark` security-scoped sessions, and prefer an idempotent-op-then-catch over a check-then-act on the filesystem. The only file Dispatch writes inside a linked repo is `.mcp.json` (and, opt-in, `.claude/settings.local.json` for the check-messages hooks) — both go through their dedicated installer actors.
- **Logging.** File-scope `private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: …)`. A plain `private let` becomes `@MainActor`-isolated and unusable from an actor — use `nonisolated`.
- **Tests.** Swift Testing (`@Suite` / `@Test` / `#expect`), not XCTest. No timing-dependent tests.

## Verifying the UI

`--mock-scenario` launches the app against scripted actor fakes — no persistence, no live bus traffic — which is how UI changes get verified headlessly. Launch through Launch Services (`open -n <app> --args --mock-scenario`), never by exec'ing the binary while another Dispatch instance is running, and match windows by PID.

## Pull requests

- One topic per PR.
- Title in conventional-commit style: `feat:`, `fix:`, `chore:`, `refactor:`, `docs:`, `test:`.
- `./scripts/build.sh` passes (Release compile check + Debug build and test).
- User-visible changes update the corresponding surface in the same PR — `README.md` for a behavior or requirement change, the [wiki](https://github.com/awizemann/Dispatch/wiki) for architecture or tool-schema changes.

## Reporting issues

Use the [bug report template](.github/ISSUE_TEMPLATE/bug_report.md). Include:

- macOS version, Xcode version
- Dispatch version / commit SHA
- What you were doing on the bus (linking, an `ask_agent` call, a hook) and what you expected instead
- Whether the issue is reproducible with two fresh repos

## License

By contributing, you agree your contributions are licensed under the [MIT License](LICENSE).

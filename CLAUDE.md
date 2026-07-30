<!-- memophant:begin -->
<!-- memophant:shim -->
## Memory System (managed by Memophant) — core rules. Full reference: [AGENTS.md](./AGENTS.md).
1. **Memory is the source of truth.** Search it before assuming; record durable decisions/learnings as memory notes or wiki pages — never in this file or session-private/model memory. Search before writing and edit an existing note (`edit_memory`) rather than forking a near-duplicate.
2. **Prefer the `memophant` MCP tools** for every read/write (search/read/write/edit/move) — read each tool's description (they document their args). Tools own slug-gen, structure validation, and the write-time secret scan; direct edits reconcile automatically but skip those guards. Tools absent → grep `.memory/` + `wiki/`.
3. **Don't `git add`/`commit` the managed tiers** (`.memory/`, `wiki/`, `design/`, `code/`, `sessions/`, `documents/`, `vendors/`, `templates/`, `TASKS.md`, `tasks/`) — the user commits each via Memophant's per-tier secret-scanned bar; leave them dirty. Everything else is yours.
4. **Secrets → Keychain, never chat or files.** Found or made a credential? Store it with `set_vendor_credential` (fetch later with `get_vendor_credential`); never leave it loose in chat.
5. **Agent artifacts (plans/reports/briefs) → `documents/` (exact lowercase), via `write_tier_file(tier: "documents", path: …)`** — never a repo's `docs/` folder (that's the project's own documentation) and never a case-variant like `Documents/`.
File memory notes under one of six folders (architecture/conventions/decisions/operations/project/roadmap), never the root. When a note is grounded in code, pass `source_paths` (the repo files it depends on) so Memory Health can drift-check it — an unanchored code note can't be kept current.
<!-- memophant:end -->

## The product
**Dispatch** is a macOS switchboard between local repos. The human links repos as projects; Dispatch merges one `dispatch` http entry into each repo's `.mcp.json`; the user's OWN Claude Code sessions in those repos then ask each other questions over an app-hosted localhost MCP bus. The whole agent-facing surface is four verbs: `ask_agent`, `answer_agent`, `check_messages`, `list_projects`. Dispatch never spawns agents, has no work queue, no commit gate, no QA pipeline, and no accounts. A human-created project link is the consent boundary — an ask without one fails closed.

## Conventions
Project-specific conventions that differ from typical SwiftUI/macOS app patterns:
- **Persistence is GRDB/SQLite** (`Dispatch/Persistence/`), not SwiftData — no `@Model`/`@Query`/`modelContext`. GRDB reads go through the logged `safeRead` helpers in `PersistenceReading.swift`; never use bare `try?` on database reads/writes.
- **Design tokens** are `Theme`/`Palette`/`Metrics`/`Motion`/`Shadows`/`TypeScale` in `Dispatch/DesignSystem/` (not `AppTheme`/`DS.*`). Off-scale fonts use the `TextStyle(TypeScale.ui(N, .weight))` factory idiom, never raw `.font(.system(size:))`.
- **File ops**: no FileCoordinatorService/AsyncFileManager here — use `PathSafety`, `RepoBookmark` security-scoped sessions, and idempotent-op-then-catch (no fileExists check-then-act). Dispatch writes narrowly into a user repo: the `dispatch` key in `.mcp.json` (`RepoMCPInstaller`), and — only when the user opts into inbox nudges — its own hook entries in `.claude/settings.local.json` (`RepoHooksInstaller`).
- **Logger** is file-scope `private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: …)` — a plain `private let` becomes MainActor-isolated and unusable from actors.
- **Build** with `./scripts/build.sh` (Release compile check first, then Debug build+test); chain it into the commit with `&&` so a commit cannot run on a red build.

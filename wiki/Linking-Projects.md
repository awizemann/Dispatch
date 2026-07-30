---
source_paths: Dispatch/Services/MCPBus/RepoMCPInstaller.swift, Dispatch/Stores/CrossProjectStore.swift, Dispatch/Views/Modals/ProjectModalView.swift, Dispatch/Models/DomainModels.swift
source_paths_inferred: false
created: 2026-07-30
updated: 2026-07-30
---

# Linking Projects

Nothing on the bus is reachable until a human says so. There are two separate acts of linking in Dispatch, and it's worth keeping them apart:

1. **Linking a repo** — turning a git repository on disk into a **project** Dispatch knows about, with a bus identity of its own.
2. **Linking two projects to each other** — the actual **consent boundary**: the thing that makes `ask_agent` between them possible at all.

Both are entirely human actions, done from the app. Neither an agent nor Dispatch itself can create either kind of link — an unlinked project simply cannot be asked anything, and `ask_agent` fails closed rather than guessing.

## 1. Linking a repo (adding a project)

From the Projects rail, **+** opens the Add Project modal. You pick a folder with a native `NSOpenPanel` — there is no typed-path field, so Dispatch never has to trust a string a user could mistype into the wrong directory. A project, once added, is:

- a **name** (yours to pick, editable later — the repo path is not, once set),
- the **repo path**, held as a security-scoped bookmark (`RepoBookmark`) so Dispatch can read git status without broader filesystem access,
- a **durable bus token**, a 128-bit value minted at link time and stored in the global database (`projectBusToken`) — it is what makes the project's endpoint reachable at all, and
- the **`dispatch` entry** merged into that repo's `.mcp.json`.

### What actually lands in `.mcp.json`

`RepoMCPInstaller` (`Dispatch/Services/MCPBus/RepoMCPInstaller.swift`) owns this, and it is deliberately conservative — this is the *only* file Dispatch ever writes inside a repo you didn't ask it to write to, and even then it only ever touches one key:

```json
{ "mcpServers": { "dispatch": { "type": "http",
  "url": "http://127.0.0.1:<port>/bus/<token>" } } }
```

Four rules, each backed by a test:

- **Value-faithful merge.** Only the `dispatch` key inside `mcpServers` is added or replaced. Every other server you already had configured, and every unknown top-level key in the file, round-trips byte-for-byte (formatting aside — see below).
- **Fail closed on invalid JSON.** A `.mcp.json` Dispatch cannot parse is never overwritten. It reports the state as `invalid` and leaves the file exactly as it found it.
- **We only take the key if it's ours.** If a `dispatch` entry is already present but its URL doesn't have the shape Dispatch writes (loopback `http`, a `/bus/<token>` path), install refuses it as a `conflict` rather than clobbering someone else's MCP server of the same name. You have to explicitly ask to replace it.
- **We only delete what we created.** Uninstall removes the `dispatch` key and nothing else. If Dispatch also created the file itself (there was no `.mcp.json` before), removing the key down to an empty `{"mcpServers": {}}` shell deletes the file too — but only then; a file that pre-existed keeps its shell.

The write re-serializes the whole file pretty-printed with sorted keys, so repeated installs of the same URL produce byte-identical output and a repo's git diff settles after one write. Values you already had are never rewritten, only the `dispatch` entry's own value changes.

### The token is a credential

The URL embeds the project's bus token, and that token is what makes the project's endpoint reachable — treat it like any other credential. If Dispatch *created* `.mcp.json` for you, it also adds a marked line to `.gitignore` so the token never ends up in a commit. If `.mcp.json` already existed before you linked the repo, Dispatch does not touch your `.gitignore` unilaterally — it's a file you had opinions about already — and instead surfaces a quiet notice that the entry now inside it carries a token, so you can decide how to keep it out of your history.

Rotating a token (or removing the project) revokes the old route on the listener immediately — a leaked or stale config file goes dead, not just unreferenced.

## 2. Linking two projects together (the consent boundary)

Adding a project makes it *exist* on the bus. It does not make it *reachable*. Two projects can only ask each other questions once a human links them to each other — a separate, explicit step.

From the Edit Project modal, a **"+ Link a project…"** menu lists every other project not already linked to this one; picking one creates a `ProjectLink` row in the global database. A link is a pair, not a direction — canonicalized so the same pair can never produce two rows regardless of which side you started from — and either project can ask the other.

This row is the whole consent model. `DispatchRouter.resolvePeer` will not resolve a target project name or id to anything outside the caller's linked set:

- Ask about a project that doesn't exist → refused (unknown project).
- Ask about a real project you're just not linked to → refused (not linked) — distinguished on purpose, so the agent's own error tells it whether to ask the human to link the project or to check for a typo.
- `list_projects` reports **exactly** the reachable set — nothing more. If the project you need isn't listed, linking it is a request to the human, never something an agent can do on its own.

### Unlinking

The same modal lets you unlink a project. If there are still-open questions between the two projects, Dispatch warns you first — unlinking always closes them (an answer can't cross a link that's gone), and any session still waiting on one sees it close, not hang. Unlink is never blocked, only warned.

### Deleting a project

Deleting a project closes every question it has open with anyone, on either end, before the project's rows are removed — the same reasoning as unlink: a long-polling `ask_agent` call must learn the truth (the question closed) rather than sit out its full wait window and then fail against a row that's already gone.

## Seeing the link graph

The **Bus Map** view draws every project as a station and every `ProjectLink` as a line between them, with a live dot on any station whose repo session is actually connected right now, and a traveling pulse for each question or answer as it crosses. It's a read-only status surface — clicking a station selects it in the rail, but the map itself has no drag or zoom, because it's meant to answer "what's reachable from what" at a glance, not to be rearranged.

## Next

- [The Four Verbs](The-Four-Verbs) — what becomes possible once two projects are linked.
- [How Dispatch Works](How-Dispatch-Works) — the transport and identity model underneath all of this.

---
_Last updated: 2026-07-30._

---
created: 2026-07-30
updated: 2026-07-30
---

# Runbook: Project Management

Common operational tasks: adding a project, linking projects, unlinking, rotating tokens, and troubleshooting.

## Adding a Project (Linking a Repo)

1. In Dispatch, click the **+** button on the Projects rail.
2. A native file picker (`NSOpenPanel`) opens. Navigate to a git repository folder and click **Open**.
3. Dispatch creates a project record with:
   - A user-visible name (editable, defaults to the folder name)
   - The repo path (immutable after creation)
   - A durable 128-bit bus token (minted at link time, stored in `GlobalDatabase`)
4. Dispatch merges the `dispatch` entry into that repo's `.mcp.json`:
   ```json
   { "mcpServers": { "dispatch": { "type": "http",
     "url": "http://127.0.0.1:<port>/bus/<token>" } } }
   ```
   If the repo had no `.mcp.json`, Dispatch creates one and adds a marked line to `.gitignore` so the token is never committed.
5. The project card appears in the rail, shows real git status, and is ready to be linked to other projects.

**What gets written:** Only the `dispatch` key under `mcpServers`; all other servers and top-level keys are untouched (value-faithful merge).

## Linking Two Projects (the Consent Boundary)

1. Open the second project's card in the rail (click it, or right-click and **Edit**).
2. Scroll to the **"Cross-project links"** section.
3. Click **"+ Link a project…"** and choose the first project from the dropdown.
4. Dispatch creates a `projectLink` row in `GlobalDatabase`.

**Result:** `list_projects` in the second project now reports that it can reach the first one. `ask_agent` calls between them are no longer refused.

**Bidirectionality:** Linking is one-way at the MCP level. If you want two projects to ask each other, link both directions (A→B and B→A).

## Unlinking Two Projects

1. Open the project's card and click **Edit**.
2. In the **"Cross-project links"** section, find the link you want to remove and click the **X** button.
3. Dispatch deletes the `projectLink` row.

**Result:** `ask_agent` calls from one project to the other are refused with "not linked". Any pending questions between them remain in the database until they expire (1 week).

## Removing a Project

1. Right-click the project card on the rail and select **Delete** (or open Edit and click the red **Delete** button at the bottom).
2. Dispatch:
   - Removes the project record from `GlobalDatabase`
   - Rotates the bus token (revokes the old route on `MCPBusListener`)
   - Removes the `dispatch` key from that repo's `.mcp.json` (value-faithful merge)
   - Deletes the `.mcp.json` file only if Dispatch created it (pre-existing files are left with their shell `{"mcpServers": {}}` intact)
3. That repo's Claude Code session can no longer reach the bus; its next `initialize` call reports "dispatch server not found".

## Renaming a Project

1. Open the project's card and click **Edit**.
2. Change the **Name** field at the top.
3. Click **Save**.

The user-visible name is updated in the rail and in `list_projects` output. The repo path and bus token are unchanged.

## Rotating a Bus Token (Revoking Access)

To invalidate old `.mcp.json` files without changing the repo:

1. Delete the project (see "Removing a Project" above).
2. Re-link the same repo.

A new token is minted, a new entry is written to `.mcp.json`, and the old route is immediately dead on `MCPBusListener`. Any client holding an old `.mcp.json` fails with 404 on the next request.

## Troubleshooting: Session Can't Reach the Bus

**Symptom:** A Claude Code session in a linked repo reports "dispatch server is not available", "404", or "connection refused".

**Diagnosis:**
1. Check that the project is still linked in Dispatch (it appears in the Projects rail).
2. Check the **Bus Health** footer in Dispatch (click the footer to open the popover). It shows whether the listener is up and on which port.
3. Check that the repo's `.mcp.json` still contains the `dispatch` entry — verify with `cat <repo>/.mcp.json | grep dispatch`.

**Likely causes and fixes:**
- **The project was deleted.** Dispatch removed the `dispatch` entry from `.mcp.json`. **Fix:** Re-link the repo in Dispatch.
- **The token was rotated.** The `.mcp.json` on disk has a stale token (e.g., the session is using an old copy of the file). **Fix:** Restart the Claude Code session to re-read `.mcp.json` from disk, or re-link the project.
- **The Dispatch app crashed and restarted on a different port.** The listener picked a new port, but old `.mcp.json` files still point at the old one. **Fix:** Restart the Claude Code session, or re-link the project (Dispatch will rewrite `.mcp.json` with the current port).
- **Firewall or network issue.** The session cannot reach `127.0.0.1:<port>`. **Fix:** Check firewall rules, verify the port in Dispatch's Bus Health footer, and ensure the session's process can bind to loopback.

## Troubleshooting: Questions Appear but Answers Don't Arrive

**Symptom:** `ask_agent` returns `{status: "pending"}`, the question sits in the target's inbox, but `answer_agent` calls fail or timeout, or the answer never arrives at the asking session.

**Likely causes:**
1. **The target session never called `check_messages`.** The other session doesn't know there's a question waiting. It might be idle or running a different task. **Fix:** Wait for it to call `check_messages`, or answer from Dispatch's **Messages** tab (open the question card and click **Answer**).
2. **The answer already arrived but was marked seen.** Outcomes are reported exactly once per session. If the asking session already received and displayed the outcome, a second `check_messages` won't report it again. **Fix:** Check Dispatch's Messages tab — the answer is there.
3. **The question expired.** Messages expire 1 week after creation. A very old pending question is no longer in the inbox. **Fix:** Ask again.
4. **The link was deleted.** If the inter-project link was removed, pending messages are orphaned. **Fix:** Re-link the projects and ask again.

## Troubleshooting: Messages Tab Shows Nothing but Sessions Are Asking

**Symptom:** Bus traffic is happening (you see errors or confirmations in the Claude sessions), but Dispatch's **Messages** tab is empty or incomplete.

**Likely causes:**
1. **No linked projects.** If there are fewer than two linked projects, there's nobody to ask. **Fix:** Link two or more projects.
2. **Old questions expired.** Questions are cleaned up 1 week after creation. **Fix:** Make a fresh ask to populate the inbox.
3. **Database corruption or disk issue.** `GlobalDatabase` cannot read or write. **Fix:** Check system logs, verify disk space, and restart the app.

---

_Last updated: 2026-07-30 — new_
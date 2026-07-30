// RepoHooksInstaller.swift
// The NUDGE half of the install path. `.mcp.json` gives a repo's
// Claude Code session the four verbs; it does not make the session ever LOOK.
// Dogfooding found the gap: a question can sit in a receiving session's inbox
// for an entire conversation because nothing ever prompts it to call
// check_messages.
//
// So, OPT-IN and default OFF, Dispatch merges three hooks into the repo's own
// `<repoRoot>/.claude/settings.local.json`:
//
//   SessionStart      — one line of session context at startup, if any question waits
//   UserPromptSubmit  — the same line per turn, which is what gets a question
//                       answered MID-conversation instead of at the next launch
//   Stop              — the END-OF-TURN drain: a session that is
//                       about to hand control back to its human first empties
//                       its dispatch inbox
//
// All three run the SAME self-contained shell command (`hookCommand(for:)`),
// differing ONLY in how the one line is emitted — see the STOP note below.
// Four properties of that command are load-bearing, and each is a test:
//
//   1. IT NEVER BLOCKS OR FAILS A SESSION. `curl --max-time 2`, every error
//      swallowed, `exit 0` on every path. A bus that is down, a repo with no
//      entry, a machine with no python3 — all of them are SILENCE, never a
//      broken session. This is somebody's actual editor.
//   2. IT CARRIES NO INTERPOLATED DATA. There is no project name, no repo path,
//      no token, no id anywhere in it. Everything it needs it reads at RUNTIME
//      from `$CLAUDE_PROJECT_DIR/.mcp.json`. That is what makes token rotation
//      and port changes never touch this file — and it is also why there is no
//      shell-injection surface: nothing the human can name ever reaches a shell
//      word (see the audit note on `hookCommand`).
//   3. IT HANDLES NO MESSAGE CONTENT. The endpoint it polls answers a COUNT and
//      nothing else, precisely so a shell script never holds question text.
//   4. IT IS IDENTIFIABLE. Every command we write opens with the `marker`, so
//      install replaces exactly our entries and uninstall removes exactly ours.
//
// The FILE is the user's, so the merge rules are `RepoMCPConfig`'s, verbatim:
// parse-don't-clobber, fail closed on invalid JSON, foreign hooks and unknown
// keys round-trip untouched, delete the file only when we created it and our
// removal left nothing.
//
// STOP NOTE (the reason the command is not byte-identical across events).
// Claude Code's stdout contract is NOT the same for all three events:
// SessionStart and UserPromptSubmit put a hook's plain stdout in front of the
// model as context, but a Stop hook that exits 0 has its plain stdout thrown
// away (debug log only). The only way a Stop hook keeps the turn going is the
// JSON decision form on stdout — `{"decision":"block","reason":"…"}`. So the
// Stop variant prints the SAME sentence wrapped in that object, and nothing
// else about the command changes. (`reason` needs no escaping: the only value
// interpolated into it is `$n`, which the command has already proved is digits,
// so there is no quote or backslash to escape.)
//
// AND IT CANNOT LOOP. Two independent guards, because a blocking hook that
// nudges forever is how this feature would ruin somebody's afternoon:
//   a. `stop_hook_active` — Claude Code sets it on the hook input of a stop
//      that a Stop hook already blocked. We read it (and ONLY in Stop mode) and
//      exit silently, so we can extend a turn at most once per stop.
//   b. The COUNT itself. Draining the inbox is what makes `/pending` answer 0,
//      and 0 is silence. A bus that cannot count fails closed to 0 as well
//      (`DispatchRouter.pendingCount`), so a broken bus is silence, never a
//      block.
//
// LOCAL-FILE NOTE: we write `.claude/settings.local.json` — Claude Code's
// PER-MACHINE settings file, the one it keeps out of git — not the checked-in
// `.claude/settings.json`. Correctness never depended on that (the command is a
// constant with no port, token or path in it, so a committed copy would still
// have been harmless), but a teammate should not inherit a hook they never
// opted into. An earlier build DID write `settings.json`, so install also takes
// our entries back out of it (`legacyFileName`) — nobody is left running two
// copies of the same hook.
//
// JSONC NOTE: Claude Code reads these settings files as PLAIN JSON. A file
// carrying comments or trailing commas is one neither it nor we can parse, and
// we fail closed on it rather than rewriting it into something that would
// silently change what the user's own hooks do.

import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "repo-hooks")

// MARK: - Pure JSON surface

/// The `.claude/settings.json` transformations, as pure functions over bytes.
nonisolated enum RepoHooksConfig {

    /// The directory and file inside the repo we touch. NOTHING else in
    /// `.claude/` is ours.
    static let directoryName = ".claude"

    /// Claude Code's PER-MACHINE settings file. This is the one we write.
    static let fileName = "settings.local.json"

    /// The checked-in, team-shared file an EARLIER build wrote into. We never
    /// add to it again; install and uninstall both clean our marked entries out
    /// of it, and touch nothing else in it.
    static let legacyFileName = "settings.json"

    /// The hook events we install under. All three, always: SessionStart alone
    /// would only ever nudge at launch, UserPromptSubmit catches the
    /// mid-conversation case, and Stop is the end-of-turn drain.
    static let events = ["SessionStart", "UserPromptSubmit", stopEvent]

    /// The one event whose stdout contract differs (see the STOP note at the
    /// top of this file).
    static let stopEvent = "Stop"

    /// The string that makes an entry OURS. Present in every command we write,
    /// as a leading `:` no-op so it is both machine-identifiable and the first
    /// thing a human reading the file sees.
    static let marker = "dispatch-bus-hook"

    /// The one sentence, in both numbers. Identical for every event: the Stop
    /// variant only changes the ENVELOPE it travels in, never the words.
    static let singularMessage =
        "Dispatch: 1 update from a linked project is waiting (a question for you, "
        + "or an answer to yours) — call check_messages."
    /// `$n` is expanded by the SHELL, and only after the command has proved it
    /// is a run of digits.
    static let pluralMessageTemplate =
        "Dispatch: $n updates from linked projects are waiting (questions for you, "
        + "or answers to yours) — call check_messages."

    /// The hook for `event`, as ONE self-contained `sh` command.
    ///
    /// Read it in five moves: find the repo's `.mcp.json`; pull our bus URL out
    /// of it (python3 first, `sed` when python3 is missing or the file shape
    /// surprises it); REFUSE anything that is not a loopback `/bus/` URL; ask
    /// `<url>/pending` with a two-second ceiling; print one line if — and only
    /// if — a positive count came back. The Stop variant adds the loop guard in
    /// front and the JSON envelope at the end; nothing between them differs.
    ///
    /// SHELL SAFETY: every variable expansion is double-quoted, and the only
    /// values that ever reach one come from the repo's own `.mcp.json` (via a
    /// JSON parse), from curl's response (via a digits-only regex), or from the
    /// hook's own stdin (compared, never expanded as code). No Dispatch-side
    /// string — project name, repo path, token — is interpolated into this
    /// command at ALL; for a given event it is a constant. A repo whose
    /// `.mcp.json` holds a hostile "url" gets it quoted, `case`-filtered against
    /// the loopback bus shape, and handed to curl as a single argv element; it
    /// is never re-parsed by the shell.
    ///
    /// `$CLAUDE_PROJECT_DIR` is what Claude Code exports; `$PWD` is the
    /// fallback for a runner that does not.
    static func hookCommand(for event: String) -> String {
        let isStop = event == stopEvent
        var parts: [String] = [
            // The marker, as a no-op. `:` ignores its arguments.
            ": \(marker);"
        ]
        if isStop {
            // LOOP GUARD, Stop only. Claude Code pipes the hook's input JSON on
            // stdin and closes it, so this read returns at once; `[ -t 0 ]`
            // keeps a runner that hands us a TERMINAL from ever blocking here,
            // and stdin is not read at all for the other two events.
            parts += [
                #"if [ -t 0 ]; then i=""; else i=$(cat 2>/dev/null); fi;"#,
                #"a=$(printf '%s' "$i" | sed -n 's/.*"stop_hook_active"[[:space:]]*:[[:space:]]*\([a-z][a-z]*\).*/\1/p' | head -n 1);"#,
                // Already blocked once for this stop: say nothing at all.
                #"if [ "$a" = true ]; then exit 0; fi;"#,
            ]
        }
        parts += Self.probeParts
        parts.append(
            #"if [ "$n" -eq 1 ]; then m="\#(singularMessage)"; else m="\#(pluralMessageTemplate)"; fi;"#
        )
        if isStop {
            // The decision form: plain stdout from a Stop hook never reaches the
            // model.
            parts.append(#"printf '{"decision":"block","reason":"%s"}\n' "$m";"#)
        } else {
            parts.append(#"printf '%s\n' "$m";"#)
        }
        parts.append("exit 0")
        return parts.joined(separator: " ")
    }

    /// The SessionStart command, kept as a name for the many places that want
    /// "the hook" without naming an event.
    static var hookCommand: String { hookCommand(for: "SessionStart") }

    /// Find the repo's `.mcp.json`, get our bus URL out of it, refuse anything
    /// that is not a loopback `/bus/` URL, and leave `$n` holding a positive
    /// count — or exit 0 having said nothing.
    private static let probeParts: [String] = [
        #"d="${CLAUDE_PROJECT_DIR:-$PWD}";"#,
        #"f="$d/.mcp.json";"#,
        #"[ -r "$f" ] || exit 0;"#,
        // Preferred parse: real JSON, no jq dependency.
        #"u=$(python3 -c "import json,sys;c=json.load(open(sys.argv[1]));print(c.get('mcpServers',{}).get('dispatch',{}).get('url',''))" "$f" 2>/dev/null);"#,
        // Defensive fallback for a machine with no python3: the first loopback
        // bus URL in the file. Shape-pinned, so it cannot pick up an unrelated
        // server's address.
        #"[ -n "$u" ] || u=$(sed -n 's|.*"url"[[:space:]]*:[[:space:]]*"\(http://127\.0\.0\.1:[0-9][0-9]*/bus/[^"]*\)".*|\1|p' "$f" 2>/dev/null | head -n 1);"#,
        // Whatever we found must LOOK like our bus before we call it.
        //
        // REJECT USERINFO FIRST. The accept-pattern below ends its port in a
        // shell glob, and a glob happily swallows a whole authority: in
        // `http://127.0.0.1:1@evil.example.com/bus/x` the "127.0.0.1:1" is URL
        // USERINFO and the real host is the attacker's, so a crafted .mcp.json
        // in a cloned repo would beacon out on every hook run. An `@` has no
        // business in a loopback bus URL, so refuse it outright — before the
        // shape check, not inside it.
        #"case "$u" in *@*) exit 0 ;; esac;"#,
        #"case "$u" in http://127.0.0.1:[0-9]*/bus/?*) ;; *) exit 0 ;; esac;"#,
        #"r=$(curl -s --max-time 2 "$u/pending" 2>/dev/null) || exit 0;"#,
        #"n=$(printf '%s' "$r" | sed -n 's/.*"pending"[[:space:]]*:[[:space:]]*\([0-9][0-9]*\).*/\1/p' | head -n 1);"#,
        #"[ -n "$n" ] || exit 0;"#,
        #"[ "$n" -gt 0 ] 2>/dev/null || exit 0;"#,
    ]

    /// What a repo's settings file says about our hooks.
    enum InstallState: Sendable, Equatable {
        /// Both events carry our current command.
        case installed
        /// No file, or a file with none of our entries.
        case missing
        /// Our marker is there but the command has changed (an older Dispatch
        /// wrote it) or only one of the two events has it.
        case stale
        /// The file exists but is not something we may safely rewrite. The
        /// payload is a HUMAN reason, never file contents.
        case invalid(String)
    }

    enum ConfigError: Error, Equatable {
        case invalidJSON(path: String)
        case unreadable(path: String)
        case repoUnavailable(path: String)
    }

    static let invalidReason =
        "This repo's .claude/settings.local.json isn't plain JSON (Claude Code doesn't accept "
        + "comments or trailing commas there either) — Dispatch left it alone."

    // MARK: Parsing

    /// Same tolerances as `.mcp.json`: BOM stripped, empty/whitespace reads as
    /// `{}`, anything else that will not parse fails closed.
    static func parse(_ data: Data, path: String) throws -> [String: Any] {
        let bytes = stripBOM(data)
        if bytes.allSatisfy({ $0 == 0x20 || $0 == 0x09 || $0 == 0x0a || $0 == 0x0d }) {
            return [:]
        }
        guard let object = try? JSONSerialization.jsonObject(with: bytes),
              let root = object as? [String: Any] else {
            throw ConfigError.invalidJSON(path: path)
        }
        return root
    }

    /// The `hooks` object, or an empty one. Throws when the key exists as
    /// something other than an object — we will not reshape a user's value.
    static func hooks(in root: [String: Any], path: String) throws -> [String: Any] {
        guard let raw = root["hooks"] else { return [:] }
        guard let hooks = raw as? [String: Any] else {
            throw ConfigError.invalidJSON(path: path)
        }
        return hooks
    }

    /// True when this hook ENTRY (`{"type":"command","command":…}`) is one of
    /// ours. Marker-based, not command-equality-based, so an entry written by
    /// an older Dispatch is still recognised as ours to replace or remove.
    static func isOurs(entry: Any) -> Bool {
        guard let object = entry as? [String: Any],
              let command = object["command"] as? String else { return false }
        return command.contains(marker)
    }

    /// One event's matcher-group array with every trace of Dispatch removed:
    /// our entries dropped from each group, and any group left with no entries
    /// at all dropped too. A group that also holds the USER's hooks keeps them
    /// and keeps its matcher.
    private static func strippingOurs(from groups: [Any]) -> [Any] {
        groups.compactMap { group -> Any? in
            guard var object = group as? [String: Any],
                  let entries = object["hooks"] as? [Any] else {
                // Not a shape we understand — leave it EXACTLY as it is.
                return group
            }
            let kept = entries.filter { !isOurs(entry: $0) }
            if kept.count == entries.count { return group }
            guard !kept.isEmpty else { return nil }
            object["hooks"] = kept
            return object
        }
    }

    /// Our group for one event: no matcher (these events do not take one), one
    /// command entry.
    static func ourGroup(for event: String) -> [String: Any] {
        ["hooks": [["type": "command", "command": hookCommand(for: event)]]]
    }

    /// The bytes to write for `existing` (nil = no file) carrying our hooks.
    /// Every foreign hook, every other event, and every unknown top-level key
    /// round-trips verbatim. Idempotent: installing twice produces identical
    /// bytes, because our old entries are stripped before ours are appended.
    static func merged(existing: Data?) throws -> Data {
        let path = fileName
        var root = try parse(existing ?? Data(), path: path)
        var hooks = try hooks(in: root, path: path)
        for event in events {
            var groups: [Any]
            if let raw = hooks[event] {
                guard let array = raw as? [Any] else {
                    // The user's `hooks.<event>` is not an array — not a shape
                    // we can merge into without changing its meaning.
                    throw ConfigError.invalidJSON(path: path)
                }
                groups = strippingOurs(from: array)
            } else {
                groups = []
            }
            groups.append(ourGroup(for: event))
            hooks[event] = groups
        }
        root["hooks"] = hooks
        return try serialize(root)
    }

    /// The result of taking our hooks back out.
    struct Removal: Sendable {
        /// The bytes to write back. nil when there was nothing of ours.
        var data: Data?
        /// True when removing our hooks left a literally empty object — the
        /// only shape whose FILE may be unlinked (and only if we created it).
        var isEmptyShell: Bool
    }

    static func removing(from existing: Data) throws -> Removal {
        let path = fileName
        var root = try parse(existing, path: path)
        var hooks = try hooks(in: root, path: path)
        var removedAnything = false
        // EVERY event in the file, not just the ones we install under today: an
        // older build's event list is exactly what a migration has to be able to
        // clean up, and `isOurs` is the only membership test that matters.
        for event in hooks.keys.sorted() {
            // A `hooks.<event>` that is not an array cannot hold an entry of
            // ours, so it is left exactly as the user wrote it.
            guard let groups = hooks[event] as? [Any],
                  groups.contains(where: { groupHoldsOurs($0) }) else { continue }
            removedAnything = true
            let stripped = strippingOurs(from: groups)
            // An event left with no groups is an empty key we introduced —
            // drop it rather than leave `"SessionStart": []` behind.
            if stripped.isEmpty {
                hooks.removeValue(forKey: event)
            } else {
                hooks[event] = stripped
            }
        }
        guard removedAnything else { return Removal(data: nil, isEmptyShell: false) }
        if hooks.isEmpty {
            root.removeValue(forKey: "hooks")
        } else {
            root["hooks"] = hooks
        }
        return Removal(data: try serialize(root), isEmptyShell: root.isEmpty)
    }

    /// True when this matcher-group holds at least one entry of ours.
    private static func groupHoldsOurs(_ group: Any) -> Bool {
        guard let entries = (group as? [String: Any])?["hooks"] as? [Any] else { return false }
        return entries.contains { isOurs(entry: $0) }
    }

    /// What `existing` says about our hooks.
    static func state(existing: Data?) -> InstallState {
        guard let existing else { return .missing }
        do {
            let root = try parse(existing, path: fileName)
            let hooks = try hooks(in: root, path: fileName)
            var present = 0
            var current = 0
            for event in events {
                guard let groups = hooks[event] as? [Any] else { continue }
                let ours = groups
                    .compactMap { ($0 as? [String: Any])?["hooks"] as? [Any] }
                    .flatMap { $0 }
                    .filter { isOurs(entry: $0) }
                guard !ours.isEmpty else { continue }
                present += 1
                if ours.contains(where: {
                    ($0 as? [String: Any])?["command"] as? String == hookCommand(for: event)
                }) {
                    current += 1
                }
            }
            if present == 0 { return .missing }
            return current == events.count ? .installed : .stale
        } catch {
            return .invalid(invalidReason)
        }
    }

    // MARK: Serialization / paths

    /// Deterministic, human-editable output — the `.mcp.json` rules exactly:
    /// pretty-printed, sorted keys, real slashes, trailing newline.
    private static func serialize(_ root: [String: Any]) throws -> Data {
        var data = try JSONSerialization.data(
            withJSONObject: root,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        )
        data.append(0x0a)
        return data
    }

    private static func stripBOM(_ data: Data) -> Data {
        let bom: [UInt8] = [0xEF, 0xBB, 0xBF]
        guard data.count >= 3, Array(data.prefix(3)) == bom else { return data }
        return data.dropFirst(3)
    }

    static func directoryURL(repoPath: String) -> URL {
        URL(fileURLWithPath: RepoMCPConfig.canonicalRepoPath(repoPath), isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
    }

    static func fileURL(repoPath: String) -> URL {
        directoryURL(repoPath: repoPath).appendingPathComponent(fileName)
    }

    /// The file a PREVIOUS build wrote into — read to clean, never to add.
    static func legacyFileURL(repoPath: String) -> URL {
        directoryURL(repoPath: repoPath).appendingPathComponent(legacyFileName)
    }

    /// True when `existing` carries at least one entry of ours, under any event.
    /// The migration question, asked of the legacy file: is there anything of
    /// ours still in there? Unparseable reads as "nothing we may touch".
    static func holdsOurs(_ existing: Data?) -> Bool {
        guard let existing,
              let root = try? parse(existing, path: legacyFileName),
              let hooks = try? hooks(in: root, path: legacyFileName) else { return false }
        return hooks.values.contains { value in
            guard let groups = value as? [Any] else { return false }
            return groups.contains { group in
                guard let entries = (group as? [String: Any])?["hooks"] as? [Any] else {
                    return false
                }
                return entries.contains { isOurs(entry: $0) }
            }
        }
    }
}

// MARK: - The installer (serialized I/O)

/// The file-touching half. An ACTOR for the same reason `RepoMCPInstaller` is:
/// read-modify-write of a config file we do not own must never interleave.
actor RepoHooksInstaller {

    static let shared = RepoHooksInstaller()

    /// Reuses the `RepoMCPLedger` SHAPE under its own defaults key: this is a
    /// different file, and "Dispatch created your .mcp.json" must never license
    /// deleting your `.claude/settings.json`.
    private let ledger: RepoMCPLedger

    static let ledgerDefaultsKey = "dispatchCreatedClaudeSettingsFiles"

    /// The live, UserDefaults-backed ledger for THIS file.
    static let userDefaultsLedger = RepoMCPLedger(
        wasCreatedByDispatch: { path in
            (UserDefaults.standard.stringArray(forKey: ledgerDefaultsKey) ?? []).contains(path)
        },
        setCreatedByDispatch: { path, created in
            var paths = Set(UserDefaults.standard.stringArray(forKey: ledgerDefaultsKey) ?? [])
            if created { paths.insert(path) } else { paths.remove(path) }
            UserDefaults.standard.set(paths.sorted(), forKey: ledgerDefaultsKey)
        }
    )

    init(ledger: RepoMCPLedger = RepoHooksInstaller.userDefaultsLedger) {
        self.ledger = ledger
    }

    /// The ledger key for ONE file in ONE repo. The two files have separate
    /// answers to "did Dispatch create this?", and conflating them would let a
    /// `settings.local.json` we made license unlinking a `settings.json` the
    /// user has had in git for a year. The LEGACY key is the bare repo path —
    /// the spelling the shipped build already wrote — so a dogfooding install
    /// still knows which `settings.json` files were its own.
    private func ledgerKey(_ canonical: String, file: String) -> String {
        file == RepoHooksConfig.legacyFileName ? canonical : "\(canonical)\u{1}\(file)"
    }

    struct InstallOutcome: Sendable, Equatable {
        var createdFile: Bool
        var changed: Bool
    }

    /// Merges (or refreshes) our hooks into `repoPath/.claude/settings.local.json`,
    /// then takes any entry an EARLIER build left in the committed
    /// `settings.json` back out. Throws — never clobbers — when the file we
    /// write will not parse.
    @discardableResult
    func install(repoPath: String) throws -> InstallOutcome {
        let fileURL = RepoHooksConfig.fileURL(repoPath: repoPath)
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: canonical, isDirectory: true)
        )
        defer { access.end() }

        let existing = try read(fileURL)
        let merged = try RepoHooksConfig.merged(existing: existing)
        var changed = false
        if existing != merged {
            try write(merged, to: fileURL, creating: existing == nil)
            changed = true
            if existing == nil {
                ledger.setCreatedByDispatch(
                    ledgerKey(canonical, file: RepoHooksConfig.fileName), true)
            }
            logger.info("installed dispatch session hooks in \(fileURL.path, privacy: .public)")
        }
        // MIGRATION. Best-effort ON PURPOSE: the install itself has
        // already succeeded, and a legacy file we cannot parse is one we must
        // not rewrite — the user is told nothing false either way, because
        // `state` keeps reading `.stale` while our entries are still in there.
        let migrated = (try? removeOurs(from: RepoHooksConfig.legacyFileURL(repoPath: repoPath),
                                        repoPath: repoPath, file: RepoHooksConfig.legacyFileName))
            ?? false
        return InstallOutcome(createdFile: existing == nil && changed,
                              changed: changed || migrated)
    }

    /// Removes ONLY our marked entries — from BOTH files, because a repo that
    /// upgraded mid-flight may carry them in either. Each file's FILE goes only
    /// when our removal emptied it AND Dispatch created that one.
    func uninstall(repoPath: String) throws {
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: canonical, isDirectory: true)
        )
        defer { access.end() }

        // The legacy file first and WITHOUT throwing: a `settings.json` the user
        // has since filled with JSONC must not be able to block the uninstall of
        // the file we actually write.
        _ = try? removeOurs(from: RepoHooksConfig.legacyFileURL(repoPath: repoPath),
                            repoPath: repoPath, file: RepoHooksConfig.legacyFileName)
        _ = try removeOurs(from: RepoHooksConfig.fileURL(repoPath: repoPath),
                           repoPath: repoPath, file: RepoHooksConfig.fileName)
    }

    /// Takes our entries out of ONE settings file. Returns whether anything
    /// changed on disk. Caller holds the security-scoped access.
    @discardableResult
    private func removeOurs(from fileURL: URL, repoPath: String, file: String) throws -> Bool {
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let key = ledgerKey(canonical, file: file)
        guard let existing = try read(fileURL) else {
            ledger.setCreatedByDispatch(key, false)
            return false
        }
        let removal = try RepoHooksConfig.removing(from: existing)
        guard let data = removal.data else {
            ledger.setCreatedByDispatch(key, false)
            return false
        }
        if removal.isEmptyShell, ledger.wasCreatedByDispatch(key) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — idempotent.
            }
            // The `.claude` directory too, but ONLY if our file was the only
            // thing in it. POSIX `rmdir`, deliberately, NOT
            // `FileManager.removeItem`: removeItem deletes a directory and
            // everything under it, which would take the user's own `.claude`
            // contents with our file. `rmdir` fails with ENOTEMPTY instead —
            // the guard is the kernel's, not a check we could race.
            _ = RepoHooksConfig.directoryURL(repoPath: repoPath)
                .withUnsafeFileSystemRepresentation { path in
                    path.map { rmdir($0) } ?? -1
                }
            logger.info("removed dispatch-created \(fileURL.path, privacy: .public)")
        } else {
            try write(data, to: fileURL, creating: false)
            logger.info("removed dispatch session hooks from \(fileURL.path, privacy: .public)")
        }
        ledger.setCreatedByDispatch(key, false)
        return true
    }

    /// Reads the repo's current hook state (never writes).
    ///
    /// LEFTOVERS COUNT AS STALE: a repo whose committed `settings.json` still
    /// carries our entries is a repo running the hook twice, so it reads
    /// `.stale` however healthy `settings.local.json` looks — and the modal's
    /// off-and-on repair is what cleans it.
    func state(repoPath: String) -> RepoHooksConfig.InstallState {
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: RepoMCPConfig.canonicalRepoPath(repoPath), isDirectory: true)
        )
        defer { access.end() }
        do {
            let state = RepoHooksConfig.state(
                existing: try read(RepoHooksConfig.fileURL(repoPath: repoPath)))
            if case .invalid = state { return state }
            let legacy = try? read(RepoHooksConfig.legacyFileURL(repoPath: repoPath))
            if RepoHooksConfig.holdsOurs(legacy) { return .stale }
            return state
        } catch {
            return .invalid("Dispatch couldn't read this repo's .claude/settings.local.json.")
        }
    }

    // MARK: - I/O primitives (op-then-catch; no fileExists check-then-act)

    private func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        } catch {
            throw RepoHooksConfig.ConfigError.unreadable(path: url.path)
        }
    }

    /// Atomic replace, creating `.claude/` if it is not there. Unlike
    /// `.mcp.json` this file carries NO credential (the command is a constant),
    /// so a created file takes the user's normal umask rather than 0600 — a
    /// repo may well want it committed and readable by their own tooling.
    private func write(_ data: Data, to url: URL, creating: Bool) throws {
        if creating {
            // Idempotent-op-then-catch: `withIntermediateDirectories` succeeds
            // on an existing directory, so there is no check to race.
            do {
                try FileManager.default.createDirectory(
                    at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            } catch {
                throw RepoHooksConfig.ConfigError.repoUnavailable(
                    path: url.deletingLastPathComponent().path)
            }
        }
        do {
            try data.write(to: url, options: [.atomic])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileWriteInvalidFileNameError) {
            throw RepoHooksConfig.ConfigError.repoUnavailable(
                path: url.deletingLastPathComponent().path)
        }
    }
}

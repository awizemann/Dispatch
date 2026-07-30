// RepoMCPInstaller.swift
// P4: the install path. Dispatch spawns no agents, so the ONLY way an external
// Claude Code session reaches the bus is the `dispatch` entry this file merges
// into the repo's own `<repoRoot>/.mcp.json`:
//
//     { "mcpServers": { "dispatch": { "type": "http",
//       "url": "http://127.0.0.1:<port>/bus/<token>" } } }
//
// That file is the USER'S, not ours. Three rules follow, and every one of them
// is a test:
//   1. VALUE-FAITHFUL MERGE. We add/replace exactly one key — "dispatch" —
//      inside "mcpServers". Every other server, and every unknown TOP-LEVEL key
//      (a repo may carry whatever it likes there), round-trips untouched.
//   2. FAIL CLOSED ON INVALID JSON. A `.mcp.json` we cannot parse is a file we
//      do not understand, so we refuse to write it at all and surface the state
//      (`.invalid`) instead of clobbering the user's config.
//   3. WE ONLY TAKE THE KEY IF IT IS OURS. A `dispatch` entry that Dispatch
//      could not have written (see `isDispatchWrittenURL`) is another tool
//      sitting on the same name: install REFUSES it (`.conflict`) until the
//      human explicitly asks for a replace, and uninstall leaves it alone.
//   4. WE ONLY DELETE WHAT WE CREATED. Uninstall removes the "dispatch" key. The
//      FILE is unlinked only when removing our key leaves a literally empty
//      `{"mcpServers":{}}` shell AND the ledger says Dispatch created that file
//      in the first place. Anything else keeps the shell.
//
// FORMATTING: round-tripping through JSONSerialization loses the original key
// order and whitespace, so we re-emit pretty-printed with SORTED keys — a
// deterministic shape, so repeated installs of the same URL produce byte-
// identical files and a repo's git diff settles after one write. VALUES are
// never rewritten. (Correctness first, per the phase brief; a formatting-
// preserving editor would be a much larger surface for a cosmetic win.)
//
// CREDENTIAL POSTURE: the URL embeds the project's bus token. It is a per-repo
// config value, but it is still a credential — it is never logged, never put in
// an error, and never in a health event. Errors carry the PATH only.

import Defaults
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "repo-install")

// MARK: - Pure JSON surface

/// The `.mcp.json` transformations, as pure functions over bytes. No file
/// system, no state — every merge rule is unit-testable from a `Data`.
nonisolated enum RepoMCPConfig {

    /// The one key Dispatch owns in a repo's `mcpServers`.
    static let serverName = "dispatch"
    static let fileName = ".mcp.json"

    /// What a repo's file says about our entry.
    enum InstallState: Sendable, Equatable {
        /// Our entry is present and points at the expected URL.
        case installed
        /// No file, or a file with no `dispatch` entry.
        case missing
        /// Our entry is present but points somewhere else (stale port/token).
        case stale
        /// A `dispatch` entry is present that DISPATCH DID NOT WRITE — someone
        /// else's server is sitting on our one key. Never overwritten without
        /// an explicit human "Replace entry".
        case conflict(String)
        /// The file exists but is not something we may safely rewrite. The
        /// payload is a HUMAN reason, never file contents.
        case invalid(String)
    }

    enum ConfigError: Error, Equatable {
        /// The file is not parseable JSON, or not a JSON object, or its
        /// `mcpServers` is not an object. We refuse to write over it.
        case invalidJSON(path: String)
        /// The file exists but could not be read.
        case unreadable(path: String)
        /// The repo folder is gone / not writable.
        case repoUnavailable(path: String)
        /// A foreign `dispatch` entry is already there. Refused rather than
        /// clobbered — the caller must come back with an explicit replace.
        case foreignEntry(path: String)
    }

    /// Parses `.mcp.json` bytes into a top-level object.
    ///
    /// Tolerances, all deliberate: a UTF-8 BOM is stripped (editors add it, and
    /// JSONSerialization treats it as garbage), and a whitespace-only/empty file
    /// reads as `{}` (an empty file carries no configuration to preserve).
    /// TRAILING GARBAGE after the object is NOT tolerated — that is a file with
    /// content we do not understand, so it fails closed.
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

    /// The `mcpServers` object, or an empty one. Throws when the key exists but
    /// is not an object — we will not turn a user's array/string into a dict.
    static func servers(in root: [String: Any], path: String) throws -> [String: Any] {
        guard let raw = root["mcpServers"] else { return [:] }
        guard let servers = raw as? [String: Any] else {
            throw ConfigError.invalidJSON(path: path)
        }
        return servers
    }

    /// The bytes to write for `existing` (nil = no file) with our entry pointing
    /// at `url`. Foreign servers and unknown top-level keys survive verbatim.
    static func merged(existing: Data?, url: String, path: String) throws -> Data {
        var root = try parse(existing ?? Data(), path: path)
        var servers = try servers(in: root, path: path)
        servers[serverName] = ["type": "http", "url": url]
        root["mcpServers"] = servers
        return try serialize(root)
    }

    /// The result of taking our entry out.
    struct Removal: Sendable {
        /// The bytes to write back. nil when there was nothing of ours to remove.
        var data: Data?
        /// True when removing our key left exactly `{"mcpServers": {}}` — the
        /// only shape whose FILE may be unlinked (and only if we created it).
        var isEmptyShell: Bool
    }

    static func removing(from existing: Data, path: String) throws -> Removal {
        var root = try parse(existing, path: path)
        var servers = try servers(in: root, path: path)
        guard servers.removeValue(forKey: serverName) != nil else {
            return Removal(data: nil, isEmptyShell: false)
        }
        root["mcpServers"] = servers
        let isEmptyShell = servers.isEmpty && root.count == 1
        return Removal(data: try serialize(root), isEmptyShell: isEmptyShell)
    }

    /// What `existing` says about our entry, against the URL we expect. A nil
    /// `expectedURL` (the bus never came up) only asks presence and AUTHORSHIP,
    /// not freshness.
    ///
    /// AUTHORSHIP is checked before freshness: a `dispatch` entry whose URL is
    /// not one Dispatch could have written belongs to someone else's server that
    /// happens to share the name, and overwriting it would be exactly the
    /// clobber rule 1 exists to prevent.
    static func state(existing: Data?, expectedURL: String?, path: String) -> InstallState {
        guard let existing else { return .missing }
        do {
            let root = try parse(existing, path: path)
            let servers = try servers(in: root, path: path)
            guard let entry = servers[serverName] else { return .missing }
            guard let object = entry as? [String: Any],
                  let url = object["url"] as? String else {
                return .conflict(conflictReason)
            }
            guard isDispatchWrittenURL(url) else { return .conflict(conflictReason) }
            guard let expectedURL else { return .installed }
            return url == expectedURL ? .installed : .stale
        } catch {
            return .invalid("the repo's .mcp.json is not valid JSON — Dispatch left it alone")
        }
    }

    static let conflictReason =
        "This repo's .mcp.json already has a “dispatch” server Dispatch didn't write, so "
        + "Dispatch left it alone. Replace it only if you know it isn't in use."

    /// Whether `url` has the shape Dispatch writes:
    /// `http://127.0.0.1:<port>/bus/<token>`. The question it answers is "could
    /// WE have written this?", so it pins the parts that are OURS — loopback
    /// http, the `/bus/` route — and deliberately NOT the token's spelling: that
    /// is an internal detail, and hard-coding it here would turn every installed
    /// repo into a false conflict the day it changes.
    static func isDispatchWrittenURL(_ url: String) -> Bool {
        guard let components = URLComponents(string: url),
              components.scheme == "http",
              components.host == "127.0.0.1",
              let port = components.port, (1...65_535).contains(port),
              components.query == nil, components.fragment == nil
        else { return false }
        let parts = components.path.split(separator: "/", omittingEmptySubsequences: true)
        return parts.count == 2 && parts[0] == "bus" && !parts[1].isEmpty
    }

    /// Deterministic, human-editable output: pretty-printed, sorted keys, real
    /// slashes (an escaped `http:\/\/` URL is legal JSON but reads as damage),
    /// trailing newline.
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

    /// The canonical key for one repo: symlinks resolved and path standardized,
    /// so `/tmp/x` and `/private/tmp/x` (and a symlinked checkout) are ONE repo
    /// to the ledger and to state lookups.
    static func canonicalRepoPath(_ repoPath: String) -> String {
        URL(fileURLWithPath: repoPath, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
            .path
    }

    static func fileURL(repoPath: String) -> URL {
        URL(fileURLWithPath: canonicalRepoPath(repoPath), isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

// MARK: - .gitignore hygiene

/// The `.mcp.json` we write carries a bus TOKEN, and a token in a committed file
/// is a token every clone of that repo has. Dispatch cannot fix that in general
/// — the file is the user's — but there is one case where it plainly should:
/// when Dispatch CREATED `.mcp.json`, the file exists only because of us, so
/// keeping it out of git is our mess to clean up.
///
/// So: created-by-us → make sure `.gitignore` covers it. Pre-existing → touch
/// NOTHING (see `RepoMCPInstaller.tokenExposure`, which surfaces a quiet notice
/// instead). Two rules, and the second one is the important one: a `.gitignore`
/// is a file people care about, and a tool that rewrites it uninvited is a tool
/// you uninstall.
///
/// Everything here is a pure function over the file's TEXT, so every claim about
/// CRLF, a missing trailing newline, and never disturbing a foreign line is a
/// unit test.
nonisolated enum RepoGitignore {

    static let fileName = ".gitignore"

    /// The comment that makes our line ours. Without it, uninstall could not
    /// tell a line we appended from one the user typed — and would have to
    /// choose between leaving litter and deleting somebody's rule.
    static let marker = "# Dispatch bus entry (local tokens)"

    /// The one path we ever ask for.
    static let entry = RepoMCPConfig.fileName

    /// Whether this `.gitignore` text already keeps `.mcp.json` out of git.
    ///
    /// Deliberately a PARSE, not a `git check-ignore` subprocess: spawning git
    /// from an app that has security-scoped access to somebody's repo is a much
    /// bigger thing to be sure about than reading one file, and the answer only
    /// has to be right about the root-level `.mcp.json`.
    ///
    /// Understood: comments, blank lines, CRLF, trailing whitespace, a leading
    /// `/` or `**/`, negation (last match wins, as in git), and globs (via
    /// `fnmatch`, so `*.json` counts). Rules naming a SUBDIRECTORY, and
    /// directory-only rules (a trailing `/`), cannot match a root-level file and
    /// are skipped.
    static func ignoresEntry(_ text: String) -> Bool {
        var ignored = false
        for raw in lines(text) {
            var line = raw
            if line.hasSuffix("\r") { line.removeLast() }
            while line.hasSuffix(" ") || line.hasSuffix("\t") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") {
                negated = true
                line.removeFirst()
            }
            // A directory rule never matches a file.
            if line.hasSuffix("/") { continue }
            if line.hasPrefix("/") { line.removeFirst() }
            if line.hasPrefix("**/") { line.removeFirst(3) }
            guard !line.isEmpty, !line.contains("/") else { continue }
            if fnmatch(line, entry, 0) == 0 { ignored = !negated }
        }
        return ignored
    }

    /// The text to write so `.mcp.json` is ignored, or nil when it already is
    /// (which is what makes this idempotent, and what makes a repo that ignores
    /// it some other way never grow a redundant line).
    ///
    /// `existing` nil = no `.gitignore` at all; we create a two-line one.
    static func adding(to existing: String?) -> String? {
        let text = existing ?? ""
        guard !ignoresEntry(text) else { return nil }
        // Match the file's own line ending. A repo full of CRLF that suddenly
        // grows one LF line is a diff nobody asked for.
        let newline = text.contains("\r\n") ? "\r\n" : "\n"
        var out = text
        if !out.isEmpty {
            // A file whose last line has no terminator gets one, or our comment
            // would land on the end of the user's rule. Asked of the SCALARS:
            // `hasSuffix("\n")` is false for a CRLF file, because Swift reads
            // "\r\n" as one Character.
            if out.unicodeScalars.last != "\n" { out += newline }
            out += newline
        }
        out += marker + newline + entry + newline
        return out
    }

    /// The text with OUR block taken out (the marker, the entry line under it,
    /// and the blank line we put in front of it), or nil when there is nothing
    /// of ours in there. Every other line survives byte for byte, CR included.
    static func removing(from existing: String) -> String? {
        guard existing.contains(marker) else { return nil }
        // Split on "\n" only, so a CRLF file keeps its "\r" on every kept line.
        var kept: [String] = []
        let lines = lines(existing)
        var index = 0
        var removedAnything = false
        while index < lines.count {
            if trimmed(lines[index]) == marker {
                removedAnything = true
                index += 1
                if index < lines.count, trimmed(lines[index]) == entry { index += 1 }
                if let last = kept.last, trimmed(last).isEmpty { kept.removeLast() }
                continue
            }
            kept.append(lines[index])
            index += 1
        }
        guard removedAnything else { return nil }
        return kept.joined(separator: "\n")
    }

    private static func trimmed(_ line: String) -> String {
        line.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The text as lines, split on the LINE FEED SCALAR.
    ///
    /// Not `split(separator: "\n")` and not `components(separatedBy:)`: Swift
    /// reads "\r\n" as ONE Character, so a Character-level split silently sees a
    /// CRLF file as a single line — which is exactly how a `.gitignore` with
    /// Windows line endings would have been mangled. Each returned line keeps
    /// its own trailing "\r", so re-joining with "\n" is byte-faithful.
    private static func lines(_ text: String) -> [String] {
        text.unicodeScalars
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { String(String.UnicodeScalarView($0)) }
    }

    static func fileURL(repoPath: String) -> URL {
        URL(fileURLWithPath: RepoMCPConfig.canonicalRepoPath(repoPath), isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

// MARK: - Created-by-Dispatch ledger

/// Remembers which repos had their `.mcp.json` CREATED by Dispatch, so uninstall
/// knows whether it may unlink the file or must leave the shell. Injectable so
/// tests never touch the user's defaults.
nonisolated struct RepoMCPLedger: Sendable {
    var wasCreatedByDispatch: @Sendable (_ canonicalRepoPath: String) -> Bool
    var setCreatedByDispatch: @Sendable (_ canonicalRepoPath: String, _ created: Bool) -> Void

    /// The persisted key. Read straight off `UserDefaults` rather than through
    /// the `Defaults` wrapper: this ledger is consulted from the installer
    /// actor, off the main actor, and `Defaults.Keys` are main-actor isolated.
    static let defaultsKey = "dispatchCreatedMCPFiles"

    /// The live, UserDefaults-backed ledger.
    static let userDefaults = RepoMCPLedger(
        wasCreatedByDispatch: { path in
            let stored = UserDefaults.standard.stringArray(forKey: defaultsKey) ?? []
            return stored.contains(path)
        },
        setCreatedByDispatch: { path, created in
            var paths = Set(UserDefaults.standard.stringArray(forKey: defaultsKey) ?? [])
            if created { paths.insert(path) } else { paths.remove(path) }
            UserDefaults.standard.set(paths.sorted(), forKey: defaultsKey)
        }
    )

    /// An in-memory ledger for tests.
    static func inMemory() -> RepoMCPLedger {
        let box = LedgerBox()
        return RepoMCPLedger(
            wasCreatedByDispatch: { box.contains($0) },
            setCreatedByDispatch: { box.set($0, $1) }
        )
    }

    private final class LedgerBox: @unchecked Sendable {
        private let lock = NSLock()
        private var paths: Set<String> = []
        func contains(_ path: String) -> Bool { lock.withLock { paths.contains(path) } }
        func set(_ path: String, _ created: Bool) {
            lock.withLock {
                if created { paths.insert(path) } else { paths.remove(path) }
            }
        }
    }
}

// MARK: - The installer (serialized I/O)

/// The file-touching half. An ACTOR on purpose: a token rotation and a
/// port-change rewrite can arrive at the same repo in the same instant, and
/// read-modify-write of someone else's config file is exactly the place a race
/// would silently drop a foreign server. Every install/uninstall in the app
/// goes through `shared`, so they are serialized app-wide.
actor RepoMCPInstaller {

    static let shared = RepoMCPInstaller()

    private let ledger: RepoMCPLedger

    init(ledger: RepoMCPLedger = .userDefaults) {
        self.ledger = ledger
    }

    struct InstallOutcome: Sendable, Equatable {
        /// The file did not exist and Dispatch created it.
        var createdFile: Bool
        /// The bytes on disk changed (false = the entry was already correct).
        var changed: Bool
    }

    /// Merges (or refreshes) the `dispatch` entry in `repoPath/.mcp.json`.
    /// Throws — never clobbers — when the existing file is not parseable, or
    /// when a FOREIGN `dispatch` entry is already sitting on our key and
    /// `replacingForeignEntry` was not explicitly granted by the human.
    @discardableResult
    func install(
        repoPath: String, url: String, replacingForeignEntry: Bool = false
    ) throws -> InstallOutcome {
        let fileURL = RepoMCPConfig.fileURL(repoPath: repoPath)
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: canonical, isDirectory: true)
        )
        defer { access.end() }

        let existing = try read(fileURL)
        // Name-collision guard: somebody else's "dispatch" server is not ours to
        // rewrite, however much we would like the key.
        if !replacingForeignEntry,
           case .conflict = RepoMCPConfig.state(
               existing: existing, expectedURL: nil, path: fileURL.path
           ) {
            throw RepoMCPConfig.ConfigError.foreignEntry(path: fileURL.path)
        }
        let merged = try RepoMCPConfig.merged(
            existing: existing, url: url, path: fileURL.path
        )
        if let existing, existing == merged {
            return InstallOutcome(createdFile: false, changed: false)
        }
        try write(merged, to: fileURL, creating: existing == nil)
        if existing == nil {
            ledger.setCreatedByDispatch(canonical, true)
        }
        // A file that exists only because of us must not carry a token into the
        // user's history. Best-effort: a `.gitignore` we cannot write is a
        // hygiene miss, never a failed install.
        // (Only under git: a folder with no `.git` has nothing to keep the file
        // out of, and a `.gitignore` we invented there would be pure litter.)
        if ledger.wasCreatedByDispatch(canonical), isGitRepo(canonical) {
            try? ensureGitignored(repoPath: repoPath)
        }
        // Path only — the URL carries the project's token.
        logger.info("installed dispatch entry in \(fileURL.path, privacy: .public)")
        return InstallOutcome(createdFile: existing == nil, changed: true)
    }

    /// Removes the `dispatch` entry. The FILE goes only when our removal left an
    /// empty `{"mcpServers":{}}` shell AND Dispatch created that file.
    func uninstall(repoPath: String) throws {
        let fileURL = RepoMCPConfig.fileURL(repoPath: repoPath)
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: canonical, isDirectory: true)
        )
        defer { access.end() }

        guard let existing = try read(fileURL) else {
            ledger.setCreatedByDispatch(canonical, false)
            return
        }
        // We only delete what we created (rule 3): a foreign `dispatch` entry we
        // refused to install over is also one we must refuse to remove.
        if case .conflict = RepoMCPConfig.state(
            existing: existing, expectedURL: nil, path: fileURL.path
        ) {
            ledger.setCreatedByDispatch(canonical, false)
            return
        }
        // Read the ledger BEFORE it is cleared: whether the `.gitignore` line is
        // ours to remove is the same question as whether the file was ours.
        if ledger.wasCreatedByDispatch(canonical) {
            try? removeGitignoreLine(repoPath: repoPath)
        }
        let removal = try RepoMCPConfig.removing(from: existing, path: fileURL.path)
        guard let data = removal.data else {
            // Nothing of ours in there; leave the file exactly as it is.
            ledger.setCreatedByDispatch(canonical, false)
            return
        }
        if removal.isEmptyShell, ledger.wasCreatedByDispatch(canonical) {
            do {
                try FileManager.default.removeItem(at: fileURL)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — idempotent.
            }
            logger.info("removed dispatch-created \(fileURL.path, privacy: .public)")
        } else {
            try write(data, to: fileURL, creating: false)
            logger.info("removed dispatch entry from \(fileURL.path, privacy: .public)")
        }
        ledger.setCreatedByDispatch(canonical, false)
    }

    /// Reads the repo's current install state (never writes).
    func state(repoPath: String, expectedURL: String?) -> RepoMCPConfig.InstallState {
        let fileURL = RepoMCPConfig.fileURL(repoPath: repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: RepoMCPConfig.canonicalRepoPath(repoPath), isDirectory: true)
        )
        defer { access.end() }
        do {
            let existing = try read(fileURL)
            return RepoMCPConfig.state(
                existing: existing, expectedURL: expectedURL, path: fileURL.path
            )
        } catch {
            return .invalid("Dispatch couldn't read the repo's .mcp.json")
        }
    }

    // MARK: - .gitignore hygiene

    /// Whether this repo's bus token is sitting in a file git will commit.
    enum TokenExposure: Sendable, Equatable {
        /// Nothing to say: not a git repo, no `.mcp.json`, or git already
        /// ignores it (whether by our line or the user's own).
        case none
        /// The `.mcp.json` pre-existed — a team-shared file we will not
        /// unilaterally gitignore — and nothing keeps it out of git.
        case committedFile
    }

    static let committedTokenHelp =
        "This repo's .mcp.json was already here, so Dispatch didn't touch its .gitignore — but "
        + "the dispatch entry inside it holds this repo's bus token. Keep that entry out of your "
        + "commits (or add .mcp.json to .gitignore), so the token stays on this machine."

    /// Reads the exposure state. Never writes, and never shells out.
    func tokenExposure(repoPath: String) -> TokenExposure {
        let canonical = RepoMCPConfig.canonicalRepoPath(repoPath)
        let access = RepoBookmark.beginAccess(
            URL(fileURLWithPath: canonical, isDirectory: true)
        )
        defer { access.end() }

        // A file we created is one we gitignored; a repo that is not under git
        // has nothing to commit the token to.
        guard !ledger.wasCreatedByDispatch(canonical), isGitRepo(canonical) else { return .none }
        guard bytes(at: RepoMCPConfig.fileURL(repoPath: repoPath)) != nil else { return .none }
        let text = gitignoreText(repoPath: repoPath) ?? ""
        return RepoGitignore.ignoresEntry(text) ? .none : .committedFile
    }

    /// `.git` is a directory in a checkout and a FILE in a worktree/submodule;
    /// either answers "git will see this".
    private func isGitRepo(_ canonicalRepoPath: String) -> Bool {
        FileManager.default.fileExists(
            atPath: URL(fileURLWithPath: canonicalRepoPath, isDirectory: true)
                .appendingPathComponent(".git").path)
    }

    /// The file's bytes, or nil for "not there / not readable" — the flattened
    /// form of `read`, for the places that treat both the same.
    private func bytes(at url: URL) -> Data? {
        guard let data = try? read(url) else { return nil }
        return data
    }

    private func gitignoreText(repoPath: String) -> String? {
        guard let data = bytes(at: RepoGitignore.fileURL(repoPath: repoPath)) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The ledger key for the repo's `.gitignore`. A SEPARATE record from the
    /// `.mcp.json` one under the same key space (the convention
    /// `RepoHooksInstaller.ledgerKey` already uses): "Dispatch created your
    /// `.mcp.json`" must not license deleting a `.gitignore` you had.
    private func gitignoreLedgerKey(_ canonical: String) -> String {
        "\(canonical)\u{1}\(RepoGitignore.fileName)"
    }

    /// Appends our ignore line unless `.mcp.json` is already covered. Caller
    /// holds the security-scoped access.
    private func ensureGitignored(repoPath: String) throws {
        let url = RepoGitignore.fileURL(repoPath: repoPath)
        let existing = gitignoreText(repoPath: repoPath)
        // A `.gitignore` that exists but is not UTF-8 is one we do not
        // understand — the same fail-closed posture the JSON files take.
        let rawBytes = bytes(at: url)
        if existing == nil, rawBytes != nil { return }
        guard let updated = RepoGitignore.adding(to: existing) else { return }
        try Data(updated.utf8).write(to: url, options: [.atomic])
        // Whether the FILE is ours has to be recorded, not inferred: a user's
        // pre-existing ZERO-BYTE `.gitignore` produces byte-for-byte the same
        // result as one we created, so uninstall reading the bytes back could
        // only guess — and it guessed "ours", and unlinked somebody's file.
        if rawBytes == nil {
            ledger.setCreatedByDispatch(
                gitignoreLedgerKey(RepoMCPConfig.canonicalRepoPath(repoPath)), true)
        }
        logger.info("gitignored \(RepoMCPConfig.fileName, privacy: .public) in \(url.path, privacy: .public)")
    }

    /// Removes OUR marked line, and only ours.
    ///
    /// The FILE goes only when our removal left it literally empty AND the
    /// ledger says Dispatch created it — the same two-part rule `.mcp.json`
    /// uses, and for the same reason: emptiness alone cannot tell our file from
    /// the empty one the user already had.
    private func removeGitignoreLine(repoPath: String) throws {
        let url = RepoGitignore.fileURL(repoPath: repoPath)
        let key = gitignoreLedgerKey(RepoMCPConfig.canonicalRepoPath(repoPath))
        defer { ledger.setCreatedByDispatch(key, false) }
        guard let existing = gitignoreText(repoPath: repoPath),
              let updated = RepoGitignore.removing(from: existing) else { return }
        if updated.isEmpty, ledger.wasCreatedByDispatch(key) {
            do {
                try FileManager.default.removeItem(at: url)
            } catch CocoaError.fileNoSuchFile {
                // Already gone — idempotent.
            }
        } else {
            try Data(updated.utf8).write(to: url, options: [.atomic])
        }
        logger.info("removed dispatch's gitignore line from \(url.path, privacy: .public)")
    }

    // MARK: - I/O primitives (op-then-catch; no fileExists check-then-act)

    /// The file's bytes, or nil when it is not there. A repo folder that has
    /// been deleted out from under us reads as "no file" here and surfaces on
    /// the WRITE as `.repoUnavailable` — we never invent a missing directory.
    private func read(_ url: URL) throws -> Data? {
        do {
            return try Data(contentsOf: url)
        } catch let error as NSError
        where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileReadNoSuchFileError) {
            return nil
        } catch {
            throw RepoMCPConfig.ConfigError.unreadable(path: url.path)
        }
    }

    /// Atomic replace. On CREATE the file is 0600 — the URL inside carries a
    /// credential and there is no reason for it to land world-readable; an
    /// EXISTING file's permissions (the user's, possibly a committed file) are
    /// left exactly as they are.
    private func write(_ data: Data, to url: URL, creating: Bool) throws {
        do {
            try data.write(to: url, options: [.atomic])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
            && (error.code == NSFileNoSuchFileError || error.code == NSFileWriteInvalidFileNameError) {
            // The repo folder itself is gone (unlinked/unmounted while linked).
            throw RepoMCPConfig.ConfigError.repoUnavailable(path: url.deletingLastPathComponent().path)
        }
        if creating {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        }
    }
}

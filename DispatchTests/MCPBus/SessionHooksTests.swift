// SessionHooksTests.swift
// The session-hook installer, tested the way the `.mcp.json`
// installer is: against REAL files, a REAL listener, and — for the hook itself
// — a REAL `/bin/sh`.
//
// The reason is the same. Every claim here is about not damaging a file we do
// not own and not breaking a session we do not control, and a mock would only
// assert our own beliefs back at us. So the shell tests execute the command
// EXACTLY as it is written into `.claude/settings.json`, byte for byte, read
// back out of the file.

import Foundation
import Testing
@testable import DispatchApp

// MARK: - Fixture

/// A throwaway directory standing in for a linked repo.
private struct HooksTempRepo {
    let url: URL

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-hooks-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    var path: String { url.path }
    var claudeURL: URL { url.appendingPathComponent(".claude", isDirectory: true) }
    /// The file we WRITE: Claude Code's per-machine settings.
    var settingsURL: URL { claudeURL.appendingPathComponent("settings.local.json") }
    /// The committed file an EARLIER build wrote into — read here only to prove
    /// we migrate out of it and never back into it.
    var legacySettingsURL: URL { claudeURL.appendingPathComponent("settings.json") }
    var mcpURL: URL { url.appendingPathComponent(".mcp.json") }

    func writeSettings(_ text: String) throws {
        try write(text, to: settingsURL)
    }

    func writeLegacySettings(_ text: String) throws {
        try write(text, to: legacySettingsURL)
    }

    private func write(_ text: String, to fileURL: URL) throws {
        try FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: fileURL)
    }

    func settingsData() -> Data? { try? Data(contentsOf: settingsURL) }
    func legacyData() -> Data? { try? Data(contentsOf: legacySettingsURL) }

    func legacyJSON() throws -> [String: Any] {
        let data = try #require(legacyData(), "no .claude/settings.json at \(legacySettingsURL.path)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var legacySettingsExist: Bool {
        FileManager.default.fileExists(atPath: legacySettingsURL.path)
    }

    func settingsJSON() throws -> [String: Any] {
        let data = try #require(settingsData(), "no .claude/settings.json at \(settingsURL.path)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var settingsExist: Bool { FileManager.default.fileExists(atPath: settingsURL.path) }
    var claudeDirExists: Bool {
        FileManager.default.fileExists(atPath: settingsURL.deletingLastPathComponent().path)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: url) }
}

private func makeHooksInstaller() -> RepoHooksInstaller {
    RepoHooksInstaller(ledger: .inMemory())
}

/// The command for one event, read back out of the file the installer wrote —
/// never the constant. Everything downstream must run what a session would.
private func installedCommand(
    in repo: HooksTempRepo, event: String
) throws -> String {
    let json = try repo.settingsJSON()
    let hooks = try #require(json["hooks"] as? [String: Any])
    let groups = try #require(hooks[event] as? [[String: Any]])
    let entries = groups.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
    let ours = try #require(entries.first { ($0["command"] as? String)?.contains("dispatch-bus-hook") == true })
    #expect(ours["type"] as? String == "command")
    return try #require(ours["command"] as? String)
}

// MARK: - Merge rules

@Suite("Session hooks: merging .claude/settings.json")
struct SessionHooksMergeTests {

    @Test("no settings.local.json → Dispatch creates one carrying exactly our three hooks")
    func createsWhenAbsent() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }

        let outcome = try await makeHooksInstaller().install(repoPath: repo.path)

        #expect(outcome.createdFile)
        #expect(outcome.changed)
        let json = try repo.settingsJSON()
        #expect(Array(json.keys) == ["hooks"], "a created file carries nothing else")
        #expect(RepoHooksConfig.events.sorted()
                == ["SessionStart", "Stop", "UserPromptSubmit"])
        for event in RepoHooksConfig.events {
            let command = try installedCommand(in: repo, event: event)
            #expect(command == RepoHooksConfig.hookCommand(for: event))
            #expect(command.contains(RepoHooksConfig.marker))
        }
        // The committed, team-shared file is never created or touched.
        #expect(!repo.legacySettingsExist)
        // Human-readable, deterministic bytes — the .mcp.json rules.
        let bytes = try #require(repo.settingsData())
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.hasSuffix("\n"))
        #expect(!text.contains("\\/"), "escaped slashes read as damage")
    }

    @Test("every event's command carries NO project name, path, token or port")
    func commandInterpolatesNothing() {
        for event in RepoHooksConfig.events {
            let command = RepoHooksConfig.hookCommand(for: event)
            // Everything it needs it reads at runtime; that is what makes token
            // rotation and port changes never touch this file, and it is also
            // the whole shell-injection story.
            #expect(command.contains("CLAUDE_PROJECT_DIR"))
            #expect(command.contains(".mcp.json"))
            #expect(command.contains("--max-time 2"))
            #expect(command.hasSuffix("exit 0"))
            #expect(command.hasPrefix(": \(RepoHooksConfig.marker);"))
            // A single line: a hook command that spans lines would be a
            // different (and much easier to get wrong) quoting problem.
            #expect(!command.contains("\n"))
        }
    }

    @Test("only the STOP command differs, and only in its envelope and its loop guard")
    func stopCommandDiffersOnlyInItsEnvelope() {
        let plain = RepoHooksConfig.hookCommand(for: "SessionStart")
        let perTurn = RepoHooksConfig.hookCommand(for: "UserPromptSubmit")
        let stop = RepoHooksConfig.hookCommand(for: RepoHooksConfig.stopEvent)
        #expect(plain == perTurn, "the two context events are byte-identical")
        #expect(stop != plain)

        // Stop speaks the decision form; the other two never do.
        #expect(stop.contains(#"{"decision":"block","reason":"%s"}"#))
        #expect(!plain.contains("decision"))
        // …and Stop, alone, reads the hook input for the loop guard.
        #expect(stop.contains("stop_hook_active"))
        #expect(!plain.contains("stop_hook_active"))
        #expect(!plain.contains("cat "), "only Stop may ever read stdin")

        // The SENTENCE is the same one in both; only the wrapper changes.
        for command in [plain, stop] {
            #expect(command.contains(RepoHooksConfig.singularMessage))
            #expect(command.contains(RepoHooksConfig.pluralMessageTemplate))
        }
        // Nothing needing a JSON escape can reach the `reason` string: the only
        // value interpolated into it is the digits-only count.
        #expect(!RepoHooksConfig.singularMessage.contains("\""))
        #expect(!RepoHooksConfig.singularMessage.contains("\\"))
        #expect(!RepoHooksConfig.pluralMessageTemplate.contains("\""))
        #expect(!RepoHooksConfig.pluralMessageTemplate.contains("\\"))
    }

    @Test("an existing settings.json keeps EVERY foreign hook and unknown top-level key")
    func mergePreservesForeignContent() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        try repo.writeSettings("""
        {
          "$schema": "https://example.invalid/settings.json",
          "permissions": { "allow": ["Bash(git status)"] },
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "echo hello from the user" } ] }
            ],
            "PreToolUse": [
              { "matcher": "Bash", "hooks": [ { "type": "command", "command": "./guard.sh" } ] }
            ]
          }
        }
        """)

        try await makeHooksInstaller().install(repoPath: repo.path)

        let json = try repo.settingsJSON()
        #expect(json["$schema"] as? String == "https://example.invalid/settings.json")
        #expect(((json["permissions"] as? [String: Any])?["allow"] as? [String]) == ["Bash(git status)"])
        let hooks = try #require(json["hooks"] as? [String: Any])
        // The user's PreToolUse group, matcher and all, is untouched.
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolUse.count == 1)
        #expect(preToolUse[0]["matcher"] as? String == "Bash")
        // The user's SessionStart hook still runs, and ours is ADDED next to it.
        let sessionStart = try #require(hooks["SessionStart"] as? [[String: Any]])
        let commands = sessionStart.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("echo hello from the user"))
        #expect(commands.contains(RepoHooksConfig.hookCommand))
    }

    @Test("re-installing is idempotent: identical bytes, never a second copy of our hook")
    func reinstallIsIdempotent() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let installer = makeHooksInstaller()

        try await installer.install(repoPath: repo.path)
        let first = try #require(repo.settingsData())
        let second = try await installer.install(repoPath: repo.path)

        #expect(!second.changed, "the same install must not rewrite the file")
        #expect(repo.settingsData() == first)
        let hooks = try #require(try repo.settingsJSON()["hooks"] as? [String: Any])
        for event in RepoHooksConfig.events {
            let entries = (hooks[event] as? [[String: Any]] ?? [])
                .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            #expect(entries.count(where: { RepoHooksConfig.isOurs(entry: $0) }) == 1,
                    "\(event) grew a duplicate of our hook")
        }
    }

    @Test("an OLDER Dispatch's hook is REPLACED, not duplicated (marker, not command, is identity)")
    func staleOurEntryIsReplaced() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        try repo.writeSettings("""
        {
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": ": dispatch-bus-hook; echo ancient" } ] }
            ]
          }
        }
        """)
        #expect(RepoHooksConfig.state(existing: repo.settingsData()) == .stale)

        try await makeHooksInstaller().install(repoPath: repo.path)

        let hooks = try #require(try repo.settingsJSON()["hooks"] as? [String: Any])
        let entries = (hooks["SessionStart"] as? [[String: Any]] ?? [])
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
        #expect(entries.count == 1)
        #expect(entries.first?["command"] as? String == RepoHooksConfig.hookCommand)
        #expect(RepoHooksConfig.state(existing: repo.settingsData()) == .installed)
    }

    @Test("removal takes ONLY our entries: foreign hooks, their matchers and the file survive")
    func removalLeavesForeignHooks() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        try repo.writeSettings("""
        {
          "permissions": { "allow": [] },
          "hooks": {
            "SessionStart": [
              { "hooks": [ { "type": "command", "command": "echo mine" } ] }
            ],
            "UserPromptSubmit": [
              { "matcher": "*", "hooks": [ { "type": "command", "command": "./audit.sh" } ] }
            ]
          }
        }
        """)
        let installer = makeHooksInstaller()
        try await installer.install(repoPath: repo.path)

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.settingsExist, "a file we did not create is never unlinked")
        let json = try repo.settingsJSON()
        #expect(json["permissions"] != nil)
        let hooks = try #require(json["hooks"] as? [String: Any])
        let all = RepoHooksConfig.events
            .flatMap { (hooks[$0] as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(all.sorted() == ["./audit.sh", "echo mine"])
        #expect(!all.contains { $0.contains(RepoHooksConfig.marker) })
        #expect(RepoHooksConfig.state(existing: repo.settingsData()) == .missing)
        // Uninstalling again is a no-op, not a second edit.
        let before = repo.settingsData()
        try await installer.uninstall(repoPath: repo.path)
        #expect(repo.settingsData() == before)
    }

    @Test("a file WE created and emptied is unlinked — with its .claude directory")
    func removalUnlinksWhatWeCreated() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let installer = makeHooksInstaller()
        try await installer.install(repoPath: repo.path)
        #expect(repo.settingsExist)

        try await installer.uninstall(repoPath: repo.path)

        #expect(!repo.settingsExist)
        #expect(!repo.claudeDirExists, "an empty .claude/ we created goes with it")
    }

    @Test("a .claude directory holding OTHER things survives our uninstall")
    func removalKeepsANonEmptyClaudeDirectory() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let installer = makeHooksInstaller()
        try await installer.install(repoPath: repo.path)
        let neighbour = repo.settingsURL.deletingLastPathComponent()
            .appendingPathComponent("agents.md")
        try Data("the user's own file".utf8).write(to: neighbour)

        try await installer.uninstall(repoPath: repo.path)

        #expect(!repo.settingsExist)
        #expect(repo.claudeDirExists)
        #expect(FileManager.default.fileExists(atPath: neighbour.path),
                "nothing else in .claude/ is ours to delete")
    }

    @Test("invalid JSON FAILS CLOSED: the file is neither parsed nor rewritten")
    func invalidJSONFailsClosed() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        // JSONC — comments and a trailing comma. Claude Code does not accept
        // this either; we must not "helpfully" rewrite it into plain JSON.
        let jsonc = """
        {
          // the user's own notes
          "hooks": { "SessionStart": [] },
        }
        """
        try repo.writeSettings(jsonc)
        let installer = makeHooksInstaller()

        await #expect(throws: RepoHooksConfig.ConfigError.self) {
            try await installer.install(repoPath: repo.path)
        }
        #expect(String(data: repo.settingsData() ?? Data(), encoding: .utf8) == jsonc,
                "not one byte may change")
        guard case .invalid = RepoHooksConfig.state(existing: repo.settingsData()) else {
            Issue.record("a file we cannot parse must read as .invalid")
            return
        }
        // Uninstall refuses it too — we do not edit what we cannot understand.
        await #expect(throws: RepoHooksConfig.ConfigError.self) {
            try await installer.uninstall(repoPath: repo.path)
        }
        #expect(String(data: repo.settingsData() ?? Data(), encoding: .utf8) == jsonc)
    }

    @Test("a hooks key that is not an object, and an event that is not an array, both fail closed")
    func wrongShapesFailClosed() async throws {
        for body in [#"{"hooks": "please no"}"#, #"{"hooks": {"SessionStart": "nope"}}"#] {
            let repo = try HooksTempRepo()
            defer { repo.cleanUp() }
            try repo.writeSettings(body)
            await #expect(throws: RepoHooksConfig.ConfigError.self) {
                try await makeHooksInstaller().install(repoPath: repo.path)
            }
            #expect(String(data: repo.settingsData() ?? Data(), encoding: .utf8) == body)
        }
    }
}

// MARK: - Migration off the committed settings.json

/// Alan's three repos shipped with our hooks in the CHECKED-IN
/// `.claude/settings.json`. Moving to `settings.local.json` is only half the
/// change: the entries already in git have to come back OUT, or every one of
/// those repos runs the nudge twice and a teammate inherits a hook they never
/// asked for. These tests are about the file we are taking something out of —
/// so every one of them also asserts what we LEFT.
@Suite("Session hooks: migrating out of the committed settings.json")
struct SessionHooksMigrationTests {

    /// The file a previous build wrote: our two events, the old command shape.
    private let oldBuildSettings = """
    {
      "$schema": "https://example.invalid/settings.json",
      "permissions": { "allow": ["Bash(git status)"] },
      "hooks": {
        "SessionStart": [
          { "hooks": [ { "type": "command", "command": ": dispatch-bus-hook; echo ancient" } ] },
          { "hooks": [ { "type": "command", "command": "echo the user's own" } ] }
        ],
        "UserPromptSubmit": [
          { "hooks": [ { "type": "command", "command": ": dispatch-bus-hook; echo ancient" } ] }
        ],
        "PreToolUse": [
          { "matcher": "Bash", "hooks": [ { "type": "command", "command": "./guard.sh" } ] }
        ]
      }
    }
    """

    @Test("install moves our entries to settings.local.json and leaves the user's alone")
    func installMigratesOffTheCommittedFile() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        try repo.writeLegacySettings(oldBuildSettings)

        try await makeHooksInstaller().install(repoPath: repo.path)

        // OURS, now, in the per-machine file — all three events.
        for event in RepoHooksConfig.events {
            #expect(try installedCommand(in: repo, event: event)
                    == RepoHooksConfig.hookCommand(for: event))
        }
        // GONE from the committed one, with the file itself intact.
        #expect(repo.legacySettingsExist, "a file we did not create is never unlinked")
        let legacy = try repo.legacyJSON()
        #expect(legacy["$schema"] as? String == "https://example.invalid/settings.json")
        #expect(((legacy["permissions"] as? [String: Any])?["allow"] as? [String])
                == ["Bash(git status)"])
        let hooks = try #require(legacy["hooks"] as? [String: Any])
        let commands = hooks.values
            .flatMap { ($0 as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.sorted() == ["./guard.sh", "echo the user's own"])
        #expect(!commands.contains { $0.contains(RepoHooksConfig.marker) })
        // The user's PreToolUse group keeps its matcher; the event we emptied is
        // gone rather than left as `"UserPromptSubmit": []`.
        let preToolUse = try #require(hooks["PreToolUse"] as? [[String: Any]])
        #expect(preToolUse[0]["matcher"] as? String == "Bash")
        #expect(hooks["UserPromptSubmit"] == nil)
        // And the repo now reads as healthy: no leftovers anywhere.
        #expect(await makeHooksInstaller().state(repoPath: repo.path) == .installed)
    }

    @Test("leftovers in the committed file read as STALE, however healthy the local one is")
    func leftoversReadAsStale() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let installer = makeHooksInstaller()
        try await installer.install(repoPath: repo.path)
        #expect(await installer.state(repoPath: repo.path) == .installed)

        // Somebody pulls a branch that still carries the old committed hooks.
        try repo.writeLegacySettings(oldBuildSettings)

        #expect(await installer.state(repoPath: repo.path) == .stale,
                "a repo running the nudge twice is not 'installed'")
        // And the repair — toggle off and on — cleans it.
        try await installer.install(repoPath: repo.path)
        #expect(await installer.state(repoPath: repo.path) == .installed)
    }

    @Test("uninstall cleans BOTH files, and unlinks only the one we created")
    func uninstallCleansBothFiles() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let installer = makeHooksInstaller()
        try repo.writeLegacySettings(oldBuildSettings)
        try await installer.install(repoPath: repo.path)
        // Put ours back into the committed file, the way a branch switch would.
        try repo.writeLegacySettings(oldBuildSettings)

        try await installer.uninstall(repoPath: repo.path)

        #expect(!repo.settingsExist, "the local file was ours — it goes")
        #expect(repo.legacySettingsExist, "the committed file is the user's — it stays")
        let commands = (try repo.legacyJSON()["hooks"] as? [String: Any] ?? [:]).values
            .flatMap { ($0 as? [[String: Any]]) ?? [] }
            .flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(!commands.contains { $0.contains(RepoHooksConfig.marker) })
        #expect(commands.sorted() == ["./guard.sh", "echo the user's own"])
        #expect(await installer.state(repoPath: repo.path) == .missing)
    }

    @Test("a settings.local.json the USER already owns is merged into, never replaced")
    func aUserOwnedLocalFileSurvives() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        try repo.writeSettings("""
        {
          "env": { "MY_KEY": "mine" },
          "hooks": {
            "Stop": [
              { "hooks": [ { "type": "command", "command": "./my-own-stop-hook.sh" } ] }
            ]
          }
        }
        """)
        let installer = makeHooksInstaller()

        try await installer.install(repoPath: repo.path)

        let json = try repo.settingsJSON()
        #expect(((json["env"] as? [String: Any])?["MY_KEY"] as? String) == "mine")
        let stop = try #require((json["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        let commands = stop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
            .compactMap { $0["command"] as? String }
        #expect(commands.contains("./my-own-stop-hook.sh"),
                "the user's own Stop hook still runs")
        #expect(commands.contains(RepoHooksConfig.hookCommand(for: RepoHooksConfig.stopEvent)))

        // And uninstall gives the file back exactly as it was, file and all.
        try await installer.uninstall(repoPath: repo.path)
        #expect(repo.settingsExist, "a local file we did not create is never unlinked")
        let after = try repo.settingsJSON()
        #expect(((after["env"] as? [String: Any])?["MY_KEY"] as? String) == "mine")
        let afterStop = try #require((after["hooks"] as? [String: Any])?["Stop"] as? [[String: Any]])
        #expect(afterStop.flatMap { ($0["hooks"] as? [[String: Any]]) ?? [] }
                .compactMap { $0["command"] as? String } == ["./my-own-stop-hook.sh"])
    }

    @Test("a committed settings.json we cannot parse never blocks the install")
    func unparseableLegacyFileIsLeftAlone() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let jsonc = """
        {
          // the user's own notes
          "hooks": { "SessionStart": [] },
        }
        """
        try repo.writeLegacySettings(jsonc)

        // The install SUCCEEDS — the file we write is a different one.
        try await makeHooksInstaller().install(repoPath: repo.path)

        #expect(try installedCommand(in: repo, event: "SessionStart")
                == RepoHooksConfig.hookCommand(for: "SessionStart"))
        #expect(String(data: repo.legacyData() ?? Data(), encoding: .utf8) == jsonc,
                "not one byte of a file we cannot understand may change")
    }
}

// MARK: - The /pending endpoint

@Suite("The /pending probe on the bus")
@MainActor
struct PendingEndpointTests {

    /// A live listener with two registered projects and a real database.
    private struct Harness {
        let global: GlobalDatabase
        let router: DispatchRouter
        let listener: MCPBusListener
        let asker: UUID
        let asked: UUID
        let askedURL: String
        let askerURL: String
    }

    private func makeHarness() async throws -> Harness {
        let global = try await GlobalDatabase.openInMemory()
        let asker = UUID(), asked = UUID()
        try await global.saveProject(
            Project(id: asker, name: "Asker", repoPath: "/repos/Asker", pinned: false))
        try await global.saveProject(
            Project(id: asked, name: "Asked", repoPath: "/repos/Asked", pinned: false))
        try await global.saveProjectLink(ProjectLink(asker, asked))
        let router = DispatchRouter(global: global)
        router.setProjectNames([asker: "Asker", asked: "Asked"])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        let token = try await global.busToken(projectID: asked)
        let url = try await listener.register(projectID: asked, token: token)
        let askerToken = try await global.busToken(projectID: asker)
        let askerURL = try await listener.register(projectID: asker, token: askerToken)
        return Harness(global: global, router: router, listener: listener,
                       asker: asker, asked: asked, askedURL: url, askerURL: askerURL)
    }

    private func probe(_ url: String, method: String = "GET") async throws -> (Int, String) {
        var request = URLRequest(url: try #require(URL(string: url)))
        request.httpMethod = method
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, String(data: data, encoding: .utf8) ?? "")
    }

    private func pendingCount(in body: String) throws -> Int {
        let json = try #require(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        #expect(json.count == 1, "the body must carry a count and NOTHING else: \(body)")
        return try #require(json["pending"] as? Int)
    }

    @Test("an unknown token 404s on /pending exactly as it does on the MCP route")
    func unknownTokenIs404() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }
        let port = try #require(await harness.listener.port)

        let (status, body) = try await probe("http://127.0.0.1:\(port)/bus/not-a-token/pending")

        #expect(status == 404)
        #expect(body.isEmpty, "a 404 body must leak nothing")
    }

    @Test("the count is the questions waiting for THIS project, and nothing about them")
    func countsOpenQuestionsForTheProject() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }

        let (empty, emptyBody) = try await probe("\(harness.askedURL)/pending")
        #expect(empty == 200)
        #expect(try pendingCount(in: emptyBody) == 0)

        _ = try await harness.router.ask(
            callerProjectID: harness.asker, targetProject: "Asked",
            question: "Who owns the nudge?", waitSeconds: nil)
        _ = try await harness.router.ask(
            callerProjectID: harness.asker, targetProject: "Asked",
            question: "And the probe?", waitSeconds: nil)

        let (status, body) = try await probe("\(harness.askedURL)/pending")
        #expect(status == 200)
        #expect(try pendingCount(in: body) == 2)
        // No question text, subject or id may appear in the body — a shell hook
        // must never handle message content.
        #expect(!body.contains("nudge"))
        #expect(!body.contains("q-"))
    }

    @Test("answered and expired questions drop out of the count")
    func countExcludesAnsweredAndExpired() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }

        let live = try await harness.router.ask(
            callerProjectID: harness.asker, targetProject: "Asked",
            question: "Still open?", waitSeconds: nil)
        let doomed = try await harness.router.ask(
            callerProjectID: harness.asker, targetProject: "Asked",
            question: "Answer me", waitSeconds: nil)
        // A question whose TTL has passed but which the sweep has NOT flipped
        // yet: the probe must not nudge about it (and must not sweep it either).
        let lapsed = BusMessage(
            id: BusMessage.mintID(), from: harness.asker, to: harness.asked,
            subject: "Old", body: "Old", askedAt: Date(timeIntervalSinceNow: -7200),
            expiresAt: Date(timeIntervalSinceNow: -3600))
        try await harness.global.saveBusMessage(lapsed)

        guard case .pending(let answerable) = doomed else {
            Issue.record("expected a pending question")
            return
        }
        _ = try await harness.router.answer(
            callerProjectID: harness.asked, questionID: answerable.id, answer: "Yes.")

        let (_, body) = try await probe("\(harness.askedURL)/pending")
        #expect(try pendingCount(in: body) == 1, "only the still-open question counts")
        // The lapsed row is still pending in the database — the probe filtered
        // it on expiry, it did not drive the sweep.
        #expect(try await harness.global.fetchBusMessage(id: lapsed.id)?.status == .pending)
        if case .pending(let stillOpen) = live {
            #expect(stillOpen.status == .pending)
        }
    }

    @Test("an unseen answer to the ASKER's own question counts — and probing does not claim it")
    func countsUnseenOutcomesWithoutClaiming() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }

        let outcome = try await harness.router.ask(
            callerProjectID: harness.asker, targetProject: "Asked",
            question: "Did my answer land?", waitSeconds: nil)
        guard case .pending(let question) = outcome else {
            Issue.record("expected a pending question")
            return
        }
        _ = try await harness.router.answer(
            callerProjectID: harness.asked, questionID: question.id, answer: "It did.")

        // The asker has an unseen answer: its hook must fire (dogfood
        // 2026-07-29 — the asking session otherwise never learns).
        let (status, body) = try await probe("\(harness.askerURL)/pending")
        #expect(status == 200)
        #expect(try pendingCount(in: body) == 1)

        // Probing must NOT claim: a second probe still counts it, and a real
        // check_messages still delivers it exactly once.
        let (_, again) = try await probe("\(harness.askerURL)/pending")
        #expect(try pendingCount(in: again) == 1)
        let inbox = try await harness.router.checkMessages(callerProjectID: harness.asker)
        #expect(inbox.outcomes.map(\.id) == [question.id])
        let (_, after) = try await probe("\(harness.askerURL)/pending")
        #expect(try pendingCount(in: after) == 0, "claimed by check_messages, probe drops to zero")
    }

    @Test("polling /pending does NOT make a project look connected")
    func pendingIsNotLiveness() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }
        #expect(!harness.router.isConnected(harness.asked))

        for _ in 0..<3 {
            let (status, _) = try await probe("\(harness.askedURL)/pending")
            #expect(status == 200)
        }

        #expect(!harness.router.isConnected(harness.asked),
                "a shell hook polling on a timer must never fake a live session")
        #expect(harness.router.lastSeen(harness.asked) == nil)
    }

    @Test("POST is accepted; anything else is a 405, never a silent 200")
    func methodHandling() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }

        let (post, body) = try await probe("\(harness.askedURL)/pending", method: "POST")
        #expect(post == 200)
        #expect(try pendingCount(in: body) == 0)

        let (delete, _) = try await probe("\(harness.askedURL)/pending", method: "DELETE")
        #expect(delete == 405)
    }

    @Test("a deeper or misspelled path under a valid token is still a 404")
    func onlyThePendingPathResolves() async throws {
        let harness = try await makeHarness()
        defer { Task { await harness.listener.stop() } }

        for suffix in ["/pendings", "/messages", "/pending/more"] {
            let (status, _) = try await probe("\(harness.askedURL)\(suffix)")
            #expect(status == 404, "\(suffix) must not resolve")
        }
    }
}

// MARK: - The hook script, run by a real shell

/// Runs a command the way Claude Code would: `/bin/sh -c`, with
/// `CLAUDE_PROJECT_DIR` pointing at the repo.
private struct ShellRun: Sendable {
    var status: Int32
    var stdout: String
    var stderr: String
}

/// ASYNC, and the process is waited for on a DETACHED task. A synchronous wait
/// here would block the main actor for the life of the hook — which starves the
/// rest of the (main-actor) suite and, before the probe was made main-actor
/// free, deadlocked the very endpoint the hook is calling.
private nonisolated func runHook(
    _ command: String, projectDir: String, exportProjectDir: Bool = true,
    stdin: String = ""
) async throws -> ShellRun {
    try await Task.detached {
        try runHookSynchronously(
            command, projectDir: projectDir, exportProjectDir: exportProjectDir, stdin: stdin)
    }.value
}

/// The hook input JSON Claude Code pipes to a Stop hook. Only the field the
/// loop guard reads has to be real.
private nonisolated func stopHookInput(active: Bool) -> String {
    """
    {"session_id":"abc123","cwd":"/tmp","hook_event_name":"Stop",\
    "last_assistant_message":"Done. It is all true, honestly.",\
    "stop_hook_active":\(active),"turn_index":5}
    """
}

private nonisolated func runHookSynchronously(
    _ command: String, projectDir: String, exportProjectDir: Bool, stdin: String
) throws -> ShellRun {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    // A DELIBERATELY MINIMAL environment, not this process's. A hosted XCTest
    // run carries DYLD_INSERT_LIBRARIES (the test-bundle injection) and every
    // child inherits it — python3 and curl would be launched with a dylib that
    // does not belong to them. Claude Code runs hooks from a plain login
    // environment, so the test does too.
    var environment = ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin"]
    if let home = ProcessInfo.processInfo.environment["HOME"] {
        environment["HOME"] = home
    }
    if exportProjectDir {
        environment["CLAUDE_PROJECT_DIR"] = projectDir
    }
    process.environment = environment
    process.currentDirectoryURL = URL(fileURLWithPath: projectDir, isDirectory: true)
    let out = Pipe(), err = Pipe()
    // A real PIPE that is written and CLOSED, exactly as Claude Code hands a
    // hook its input JSON — the read in the Stop guard has to terminate on EOF.
    let input = Pipe()
    process.standardOutput = out
    process.standardError = err
    process.standardInput = input
    try process.run()
    input.fileHandleForWriting.write(Data(stdin.utf8))
    try? input.fileHandleForWriting.close()
    let outData = out.fileHandleForReading.readDataToEndOfFile()
    let errData = err.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return ShellRun(
        status: process.terminationStatus,
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? ""
    )
}

@Suite("The hook command, in a real shell")
@MainActor
struct SessionHookShellTests {

    /// A temp repo with BOTH files installed against a live listener, plus the
    /// pieces needed to put a question in the inbox.
    private struct LiveRepo {
        let repo: HooksTempRepo
        let global: GlobalDatabase
        let router: DispatchRouter
        let listener: MCPBusListener
        let asker: UUID
        let asked: UUID
    }

    private func makeLiveRepo() async throws -> LiveRepo {
        let repo = try HooksTempRepo()
        let global = try await GlobalDatabase.openInMemory()
        let asker = UUID(), asked = UUID()
        try await global.saveProject(
            Project(id: asker, name: "Asker", repoPath: "/repos/Asker", pinned: false))
        try await global.saveProject(
            Project(id: asked, name: "Asked", repoPath: repo.path, pinned: false))
        try await global.saveProjectLink(ProjectLink(asker, asked))
        let router = DispatchRouter(global: global)
        router.setProjectNames([asker: "Asker", asked: "Asked"])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        let token = try await global.busToken(projectID: asked)
        let url = try await listener.register(projectID: asked, token: token)
        // BOTH installers, exactly as the app runs them.
        try await RepoMCPInstaller(ledger: .inMemory()).install(repoPath: repo.path, url: url)
        try await RepoHooksInstaller(ledger: .inMemory()).install(repoPath: repo.path)
        return LiveRepo(repo: repo, global: global, router: router,
                        listener: listener, asker: asker, asked: asked)
    }

    @Test("with a question waiting, the SessionStart hook prints exactly one nudge line")
    func nudgesWhenQuestionsWait() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Does the hook fire?", waitSeconds: nil)

        let command = try installedCommand(in: live.repo, event: "SessionStart")
        let run = try await runHook(command, projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(run.stderr.isEmpty, "a hook must never write noise to a session's stderr")
        let lines = run.stdout.split(separator: "\n")
        #expect(lines.count == 1, "exactly one line of context: \(run.stdout)")
        #expect(run.stdout.contains("Dispatch: 1 update"))
        #expect(run.stdout.contains("check_messages"))
        // And it says nothing ABOUT the question.
        #expect(!run.stdout.contains("Does the hook fire?"))

        // Plural reads as plural.
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "And twice?", waitSeconds: nil)
        let again = try await runHook(command, projectDir: live.repo.path)
        #expect(again.stdout.contains("Dispatch: 2 updates"))
    }

    @Test("UserPromptSubmit carries the SAME command — the mid-conversation nudge")
    func userPromptSubmitIsTheSameCommand() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Mid-conversation?", waitSeconds: nil)

        let sessionStart = try installedCommand(in: live.repo, event: "SessionStart")
        let perTurn = try installedCommand(in: live.repo, event: "UserPromptSubmit")
        #expect(sessionStart == perTurn)

        let run = try await runHook(perTurn, projectDir: live.repo.path)
        #expect(run.status == 0)
        #expect(run.stdout.contains("Dispatch: 1 update"))
    }

    @Test("with nothing waiting the hook is SILENT and exits 0")
    func silentWhenNothingWaits() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }

        let run = try await runHook(
            try installedCommand(in: live.repo, event: "SessionStart"),
            projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty, "an empty inbox must inject NOTHING: \(run.stdout)")
        #expect(run.stderr.isEmpty)
    }

    @Test("a bus that is DOWN is silence and exit 0 — never a broken session")
    func silentWhenTheBusIsDown() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp() }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Anyone home?", waitSeconds: nil)
        let command = try installedCommand(in: live.repo, event: "SessionStart")
        // The app quits; the repo's files are exactly as they were.
        await live.listener.stop()

        let run = try await runHook(command, projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty, "curl must not spill a connection error into the session")
    }

    @Test("no .mcp.json, no dispatch entry, and a foreign non-bus entry are all silent exit 0")
    func silentWithoutAReachableEntry() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        let command = try installedCommand(in: live.repo, event: "SessionStart")

        // 1. The entry points at somebody ELSE's server that happens to be
        //    called "dispatch" — not a loopback /bus/ URL, so we never call it.
        try Data(#"{"mcpServers":{"dispatch":{"type":"http","url":"https://example.invalid/rpc"}}}"#.utf8)
            .write(to: live.repo.mcpURL)
        let foreign = try await runHook(command, projectDir: live.repo.path)
        #expect(foreign.status == 0)
        #expect(foreign.stdout.isEmpty)

        // 2. A file with no dispatch entry at all.
        try Data(#"{"mcpServers":{"other":{"type":"stdio","command":"x"}}}"#.utf8)
            .write(to: live.repo.mcpURL)
        let noEntry = try await runHook(command, projectDir: live.repo.path)
        #expect(noEntry.status == 0)
        #expect(noEntry.stdout.isEmpty)

        // 3. No file at all.
        try FileManager.default.removeItem(at: live.repo.mcpURL)
        let noFile = try await runHook(command, projectDir: live.repo.path)
        #expect(noFile.status == 0)
        #expect(noFile.stdout.isEmpty)
        #expect(noFile.stderr.isEmpty)
    }

    @Test("a loopback /bus/ URL that is NOT ours answers nothing the hook will speak about")
    func silentOnAForeignBusShapedEntry() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Wrong token?", waitSeconds: nil)
        let command = try installedCommand(in: live.repo, event: "SessionStart")
        let port = try #require(await live.listener.port)
        // The right bus, the WRONG token — the shape passes the hook's filter,
        // so this is the case where only the 404 (and the empty body behind it)
        // keeps the hook quiet.
        let config: [String: Any] = ["mcpServers": ["dispatch": [
            "type": "http", "url": "http://127.0.0.1:\(port)/bus/somebody-elses-token",
        ]]]
        try JSONSerialization.data(withJSONObject: config).write(to: live.repo.mcpURL)

        let run = try await runHook(command, projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty,
                "a token that is not this repo's must never surface another project's count")
        #expect(run.stderr.isEmpty)
    }

    @Test("an unparseable .mcp.json is silence, not a shell error")
    func silentOnGarbageConfig() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        let command = try installedCommand(in: live.repo, event: "SessionStart")
        try Data("{ this is not json at all ".utf8).write(to: live.repo.mcpURL)

        let run = try await runHook(command, projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty)
    }

    @Test("a hostile url in .mcp.json is quoted and filtered — never executed")
    func hostileURLIsNeverExecuted() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        let command = try installedCommand(in: live.repo, event: "SessionStart")
        let canary = live.repo.url.appendingPathComponent("PWNED")
        let payload = "http://127.0.0.1:1/bus/x\"; touch \(canary.path); echo \""
        let config: [String: Any] = ["mcpServers": ["dispatch": ["type": "http", "url": payload]]]
        try JSONSerialization.data(withJSONObject: config).write(to: live.repo.mcpURL)

        let run = try await runHook(command, projectDir: live.repo.path)

        #expect(run.status == 0)
        #expect(!FileManager.default.fileExists(atPath: canary.path),
                "a value from the repo's config must never reach the shell as code")
        #expect(run.stdout.isEmpty)
    }

    /// The audit case the shape-filter was believed to cover and did not.
    /// `http://127.0.0.1:1@evil.example.com/bus/x` is not loopback at all — the
    /// "127.0.0.1:1" is URL USERINFO and the real host is the attacker's — but
    /// the accept-pattern's trailing glob swallowed the whole authority. A repo
    /// cloned with a crafted `.mcp.json` would then beacon out on EVERY hook
    /// run, silently, because the hook swallows its own output.
    @Test("a url whose loopback prefix is only userinfo is refused, not called")
    func userinfoDisguisedHostIsRefused() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        let command = try installedCommand(in: live.repo, event: "SessionStart")

        // A host that would resolve (and log) if we ever called it. Both forms
        // the audit proved the old pattern accepted.
        for disguised in [
            "http://127.0.0.1:1@localhost:1/bus/x",
            "http://127.0.0.1:9@127.0.0.2:1/bus/y",
        ] {
            let config: [String: Any] = [
                "mcpServers": ["dispatch": ["type": "http", "url": disguised]]
            ]
            try JSONSerialization.data(withJSONObject: config).write(to: live.repo.mcpURL)

            let run = try await runHook(command, projectDir: live.repo.path)

            #expect(run.status == 0)
            #expect(run.stdout.isEmpty, "\(disguised) must never be contacted")
            #expect(run.stderr.isEmpty)
        }
    }

    // MARK: The Stop hook

    /// The one line of a Stop run's stdout, parsed as the decision object Claude
    /// Code actually reads.
    private func decision(_ run: ShellRun) throws -> [String: Any] {
        try #require(
            try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any],
            "a Stop hook's stdout must be the JSON decision form, got: \(run.stdout)")
    }

    @Test("the Stop hook emits the DECISION form — plain stdout would be thrown away")
    func stopHookSpeaksTheDecisionForm() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Drain at end of turn?", waitSeconds: nil)

        let command = try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent)
        let run = try await runHook(
            command, projectDir: live.repo.path, stdin: stopHookInput(active: false))

        #expect(run.status == 0, "a Stop hook blocks by DECISION, never by exit code")
        #expect(run.stderr.isEmpty)
        let decision = try decision(run)
        // `decision: "block"` is what makes the session keep going instead of
        // handing control back to the human with a question unanswered.
        #expect(decision["decision"] as? String == "block")
        let reason = try #require(decision["reason"] as? String)
        #expect(reason == RepoHooksConfig.singularMessage)
        #expect(reason.contains("check_messages"))
        // Still no message content anywhere near the shell.
        #expect(!run.stdout.contains("Drain at end of turn?"))
        #expect(run.stdout.split(separator: "\n").count == 1)
    }

    @Test("the Stop hook's reason counts in the plural too, and stays valid JSON")
    func stopHookPluralIsValidJSON() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        for question in ["One?", "Two?", "Three?"] {
            _ = try await live.router.ask(
                callerProjectID: live.asker, targetProject: "Asked",
                question: question, waitSeconds: nil)
        }

        let run = try await runHook(
            try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent),
            projectDir: live.repo.path, stdin: stopHookInput(active: false))

        let reason = try #require(try decision(run)["reason"] as? String)
        #expect(reason.contains("3 updates"))
    }

    @Test("an empty inbox stops SILENTLY: no decision, no block, exit 0")
    func stopHookIsSilentWithNothingWaiting() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }

        let run = try await runHook(
            try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent),
            projectDir: live.repo.path, stdin: stopHookInput(active: false))

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty, "a silent stop must emit no JSON at all: \(run.stdout)")
        #expect(run.stderr.isEmpty)
    }

    @Test("stop_hook_active: true is SILENCE — we may extend a turn at most once")
    func stopHookHonoursTheLoopGuard() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        // A question is waiting AND the count will not drop by itself: exactly
        // the shape a runaway loop would need.
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Would you loop?", waitSeconds: nil)
        let command = try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent)

        // First stop: we block once.
        let first = try await runHook(
            command, projectDir: live.repo.path, stdin: stopHookInput(active: false))
        #expect(try decision(first)["decision"] as? String == "block")

        // The stop that FOLLOWS our own block carries stop_hook_active — and we
        // say nothing, however many questions are still waiting. This is the
        // guard that holds even when the model never drains the inbox.
        let second = try await runHook(
            command, projectDir: live.repo.path, stdin: stopHookInput(active: true))
        #expect(second.status == 0)
        #expect(second.stdout.isEmpty, "a second block in a row would be the loop: \(second.stdout)")

        // …and re-running it ten more times changes nothing.
        for _ in 0..<10 {
            let again = try await runHook(
                command, projectDir: live.repo.path, stdin: stopHookInput(active: true))
            #expect(again.stdout.isEmpty)
        }
    }

    @Test("a bus that is DOWN never blocks a stop — a broken bus is silence, not a hostage")
    func stopHookNeverBlocksOnABrokenBus() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp() }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Anyone home?", waitSeconds: nil)
        let command = try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent)
        await live.listener.stop()

        let run = try await runHook(
            command, projectDir: live.repo.path, stdin: stopHookInput(active: false))

        #expect(run.status == 0)
        #expect(run.stdout.isEmpty)
        #expect(run.stderr.isEmpty)
    }

    @Test("a Stop hook run with NO stdin at all is silent, not blocked on a read")
    func stopHookToleratesEmptyInput() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "No input?", waitSeconds: nil)

        // Empty stdin, closed immediately: a runner that pipes nothing must get
        // the same answer as one that pipes `stop_hook_active: false`.
        let run = try await runHook(
            try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent),
            projectDir: live.repo.path, stdin: "")

        #expect(run.status == 0)
        #expect(try decision(run)["decision"] as? String == "block")
    }

    @Test("DRAINING zeroes the count: the next stop is silent, with no guard involved")
    func stopHookGoesQuietOnceTheInboxIsDrained() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        let outcome = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Answer me and I go quiet?", waitSeconds: nil)
        guard case .pending(let question) = outcome else {
            Issue.record("expected a pending question")
            return
        }
        let command = try installedCommand(in: live.repo, event: RepoHooksConfig.stopEvent)
        #expect(try decision(try await runHook(
            command, projectDir: live.repo.path,
            stdin: stopHookInput(active: false)))["decision"] as? String == "block")

        // The session does what the block asked: it checks, and it answers.
        _ = try await live.router.checkMessages(callerProjectID: live.asked)
        _ = try await live.router.answer(
            callerProjectID: live.asked, questionID: question.id, answer: "Quiet now.")

        // A FRESH stop — stop_hook_active false, so nothing but the count keeps
        // this silent. That is the no-loop property, at the model level.
        let after = try await runHook(
            command, projectDir: live.repo.path, stdin: stopHookInput(active: false))
        #expect(after.stdout.isEmpty, "a drained inbox must not block the stop: \(after.stdout)")
        #expect(await live.router.pendingCount(for: live.asked) == 0)
    }

    @Test("with no CLAUDE_PROJECT_DIR the hook falls back to the working directory")
    func fallsBackToPWD() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Without the env var?", waitSeconds: nil)

        let run = try await runHook(
            try installedCommand(in: live.repo, event: "SessionStart"),
            projectDir: live.repo.path, exportProjectDir: false)

        #expect(run.status == 0)
        #expect(run.stdout.contains("Dispatch: 1 update"))
    }

    @Test("the hook does NOT count as liveness, however often a session starts")
    func hookRunsNeverFakePresence() async throws {
        let live = try await makeLiveRepo()
        defer { live.repo.cleanUp(); Task { await live.listener.stop() } }
        _ = try await live.router.ask(
            callerProjectID: live.asker, targetProject: "Asked",
            question: "Still not connected?", waitSeconds: nil)
        let command = try installedCommand(in: live.repo, event: "SessionStart")

        for _ in 0..<3 { _ = try await runHook(command, projectDir: live.repo.path) }

        #expect(!live.router.isConnected(live.asked),
                "hooks must not make an unattended repo look like a live session")
    }
}

// MARK: - End to end

@Suite("Session hooks end to end")
@MainActor
struct SessionHooksEndToEndTests {

    @Test("install both files into a real repo, ask a real question, run the hook the file carries")
    func fullNudgeRoundTrip() async throws {
        let repo = try HooksTempRepo()
        defer { repo.cleanUp() }
        let global = try await GlobalDatabase.openInMemory()
        let asker = UUID(), asked = UUID()
        try await global.saveProject(
            Project(id: asker, name: "Alpha", repoPath: "/repos/Alpha", pinned: false))
        try await global.saveProject(
            Project(id: asked, name: "Beta", repoPath: repo.path, pinned: false,
                    sessionHooksEnabled: true))
        try await global.saveProjectLink(ProjectLink(asker, asked))
        let router = DispatchRouter(global: global)
        router.setProjectNames([asker: "Alpha", asked: "Beta"])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        defer { Task { await listener.stop() } }

        let token = try await global.busToken(projectID: asked)
        let url = try await listener.register(projectID: asked, token: token)
        let mcpInstaller = RepoMCPInstaller(ledger: .inMemory())
        let hooksInstaller = RepoHooksInstaller(ledger: .inMemory())
        try await mcpInstaller.install(repoPath: repo.path, url: url)
        try await hooksInstaller.install(repoPath: repo.path)

        // From here we know NOTHING but what the two files on disk say.
        let command = try installedCommand(in: repo, event: "SessionStart")

        // Nothing waiting: a session starting in this repo sees no context.
        #expect(try await runHook(command, projectDir: repo.path).stdout.isEmpty)

        // Alpha asks Beta. Beta's session is not live, so it parks in the inbox
        // — the exact case that used to go unnoticed for a whole conversation.
        let outcome = try await router.ask(
            callerProjectID: asker, targetProject: "Beta",
            question: "Did the nudge reach you?", waitSeconds: nil)
        guard case .pending(let question) = outcome else {
            Issue.record("expected the question to park in the inbox")
            return
        }

        // The NEXT session start in that repo is told, by its own settings file.
        let nudged = try await runHook(command, projectDir: repo.path)
        #expect(nudged.status == 0)
        #expect(nudged.stdout ==
                "Dispatch: 1 update from a linked project is waiting (a question for you, or an answer to yours) — call check_messages.\n")

        // Beta answers; the nudge goes quiet in the same breath.
        _ = try await router.answer(
            callerProjectID: asked, questionID: question.id, answer: "It did.")
        #expect(try await runHook(command, projectDir: repo.path).stdout.isEmpty)

        // Turning the toggle off takes our lines back out, and the repo's own
        // session start is silent again even with a question waiting.
        _ = try await router.ask(
            callerProjectID: asker, targetProject: "Beta",
            question: "And after opting out?", waitSeconds: nil)
        #expect(try await runHook(command, projectDir: repo.path).stdout.contains("Dispatch: 1 update"))
        try await hooksInstaller.uninstall(repoPath: repo.path)
        #expect(!repo.settingsExist)
        #expect(RepoHooksConfig.state(existing: repo.settingsData()) == .missing)
        // The bus entry itself is untouched — the two installs are independent.
        #expect(FileManager.default.fileExists(atPath: repo.mcpURL.path))
    }

    @Test("the opt-in survives a round trip through the database, default OFF")
    func optInPersists() async throws {
        let global = try await GlobalDatabase.openInMemory()
        let id = UUID()
        try await global.saveProject(
            Project(id: id, name: "Fresh", repoPath: "/repos/Fresh", pinned: false))

        let fresh = try await global.fetchProjects().first { $0.id == id }
        #expect(fresh?.sessionHooksEnabled == false, "no repo gains hooks it was not given")

        try await global.setSessionHooksEnabled(projectID: id, enabled: true)
        #expect(try await global.fetchProjects().first { $0.id == id }?.sessionHooksEnabled == true)

        // A whole-record save must not silently clear it (the flag rides the DTO).
        let project = try #require(try await global.fetchProjects().first { $0.id == id })
        try await global.saveProject(project)
        #expect(try await global.fetchProjects().first { $0.id == id }?.sessionHooksEnabled == true)

        try await global.setSessionHooksEnabled(projectID: id, enabled: false)
        #expect(try await global.fetchProjects().first { $0.id == id }?.sessionHooksEnabled == false)
    }
}

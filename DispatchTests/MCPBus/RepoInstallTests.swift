// RepoInstallTests.swift
// P4: the install path — the `dispatch` entry Dispatch merges into each linked
// repo's OWN `.mcp.json`.
//
// Everything here runs against REAL files in real temp directories, because the
// contract is entirely about not damaging a file we do not own: a mock file
// system would assert our own beliefs back at us. The end-to-end suite goes
// further and drives two real git repos through ProjectStore, a real
// GlobalDatabase, a real listener, and two hand-rolled JSON-RPC clients that
// know NOTHING except what the installed `.mcp.json` files say.

import Foundation
import Testing
@testable import DispatchApp

// MARK: - Temp repo fixture

/// A throwaway directory that stands in for a linked repo.
private struct TempRepo {
    let url: URL

    init(gitInit: Bool = false) throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if gitInit {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git", "init", "--quiet", url.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
        }
    }

    var path: String { url.path }
    var configURL: URL { url.appendingPathComponent(".mcp.json") }

    func writeConfig(_ text: String) throws {
        try Data(text.utf8).write(to: configURL)
    }

    func writeConfig(_ data: Data) throws {
        try data.write(to: configURL)
    }

    func configData() throws -> Data? {
        try? Data(contentsOf: configURL)
    }

    func configJSON() throws -> [String: Any] {
        let data = try #require(try configData(), "no .mcp.json at \(configURL.path)")
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    var configExists: Bool {
        FileManager.default.fileExists(atPath: configURL.path)
    }

    // MARK: .gitignore

    var gitignoreURL: URL { url.appendingPathComponent(".gitignore") }

    func writeGitignore(_ text: String) throws {
        try Data(text.utf8).write(to: gitignoreURL)
    }

    func gitignoreText() -> String? {
        guard let data = try? Data(contentsOf: gitignoreURL) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    var gitignoreExists: Bool {
        FileManager.default.fileExists(atPath: gitignoreURL.path)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: url)
    }
}

private func makeInstaller() -> RepoMCPInstaller {
    RepoMCPInstaller(ledger: .inMemory())
}

private func dispatchURL(in json: [String: Any]) throws -> String {
    let servers = try #require(json["mcpServers"] as? [String: Any])
    let entry = try #require(servers["dispatch"] as? [String: Any])
    #expect(entry["type"] as? String == "http")
    return try #require(entry["url"] as? String)
}

// MARK: - Install

@Suite("Repo install: writing the dispatch entry")
struct RepoMCPInstallTests {

    @Test("no .mcp.json → Dispatch creates one carrying exactly the bus entry")
    func createsWhenAbsent() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()

        let outcome = try await installer.install(
            repoPath: repo.path, url: "http://127.0.0.1:5100/bus/aaaa"
        )

        #expect(outcome.createdFile)
        #expect(outcome.changed)
        let json = try repo.configJSON()
        #expect(Array(json.keys) == ["mcpServers"], "a created file carries nothing else")
        #expect(try dispatchURL(in: json) == "http://127.0.0.1:5100/bus/aaaa")
        // The URL is a credential: a file we create is not world-readable.
        let mode = try FileManager.default
            .attributesOfItem(atPath: repo.configURL.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        // And it is a file a human can read/edit — real slashes, not \/.
        let bytes = try #require(try repo.configData())
        let text = try #require(String(data: bytes, encoding: .utf8))
        #expect(text.contains("http://127.0.0.1:5100/bus/aaaa"))
        #expect(text.hasSuffix("\n"))
    }

    @Test("an existing file keeps EVERY foreign server and unknown top-level key")
    func mergePreservesForeignContent() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig("""
        {
          "$schema": "https://example.invalid/mcp.json",
          "somethingElseEntirely": { "nested": [1, 2, {"deep": true}] },
          "mcpServers": {
            "memophant": {
              "type": "stdio",
              "command": "./.memophant/mcp/memophant-mcp",
              "args": ["--project-root", "."],
              "env": { "API_KEY": "leave-me-exactly-as-i-am" }
            },
            "tracker": { "type": "sse", "url": "https://tracker.invalid/sse" }
          }
        }
        """)
        let installer = makeInstaller()

        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/bbbb")

        let json = try repo.configJSON()
        #expect(json["$schema"] as? String == "https://example.invalid/mcp.json")
        let unknown = try #require(json["somethingElseEntirely"] as? [String: Any])
        let nested = try #require(unknown["nested"] as? [Any])
        #expect(nested.count == 3)
        #expect((nested[2] as? [String: Any])?["deep"] as? Bool == true)

        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["memophant", "tracker", "dispatch"])
        let memophant = try #require(servers["memophant"] as? [String: Any])
        #expect(memophant["command"] as? String == "./.memophant/mcp/memophant-mcp",
                "a foreign server's values are NEVER rewritten — not even a relative command")
        #expect(memophant["args"] as? [String] == ["--project-root", "."])
        #expect((memophant["env"] as? [String: String])?["API_KEY"] == "leave-me-exactly-as-i-am")
        let tracker = try #require(servers["tracker"] as? [String: Any])
        #expect(tracker["url"] as? String == "https://tracker.invalid/sse")
    }

    @Test("reinstalling the SAME url is a no-op — repeated launches leave the file byte-identical")
    func reinstallIsIdempotent() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/cccc")
        let first = try repo.configData()

        let second = try await installer.install(
            repoPath: repo.path, url: "http://127.0.0.1:5100/bus/cccc"
        )

        #expect(!second.changed, "an unchanged entry must not rewrite the user's file")
        #expect(try repo.configData() == first)
    }

    @Test("a UTF-8 BOM is tolerated; the merge still preserves foreign servers")
    func bomIsTolerated() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        var bytes = Data([0xEF, 0xBB, 0xBF])
        bytes.append(Data(#"{"mcpServers":{"tracker":{"type":"http","url":"https://t.invalid"}}}"#.utf8))
        try repo.writeConfig(bytes)

        try await makeInstaller().install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/dddd")

        let servers = try #require(try repo.configJSON()["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["tracker", "dispatch"])
    }

    @Test("an empty file is adopted rather than treated as damage")
    func emptyFileIsAdopted() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig("   \n\t ")

        let outcome = try await makeInstaller()
            .install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/eeee")

        #expect(!outcome.createdFile, "the file was already there — we did not create it")
        #expect(try dispatchURL(in: try repo.configJSON()) == "http://127.0.0.1:5100/bus/eeee")
    }

    @Test("a symlinked repo path installs into the REAL directory, once")
    func symlinkedRepoPath() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let link = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)
        defer { try? FileManager.default.removeItem(at: link) }
        let installer = makeInstaller()

        // Install through the SYMLINK, then again through the real path.
        let viaLink = try await installer.install(
            repoPath: link.path, url: "http://127.0.0.1:5100/bus/ffff"
        )
        let viaReal = try await installer.install(
            repoPath: repo.path, url: "http://127.0.0.1:5100/bus/ffff"
        )

        #expect(viaLink.createdFile)
        #expect(!viaReal.createdFile, "the symlink and the real path are ONE repo")
        #expect(!viaReal.changed)
        #expect(try dispatchURL(in: try repo.configJSON()) == "http://127.0.0.1:5100/bus/ffff")
        // Exactly one file exists — no second .mcp.json beside the symlink.
        #expect(repo.configExists)
    }
}

// MARK: - Fail closed

@Suite("Repo install: fail closed on a file we don't understand")
struct RepoMCPFailClosedTests {

    @Test("invalid JSON is NEVER clobbered — the bytes survive and the error names the file, not the token")
    func invalidJSONFailsClosed() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let original = "{ this is not json at all "
        try repo.writeConfig(original)
        let secret = "http://127.0.0.1:5100/bus/deadbeefdeadbeefdeadbeefdeadbeef"

        await #expect(throws: RepoMCPConfig.ConfigError.invalidJSON(path: repo.configURL.path)) {
            try await makeInstaller().install(repoPath: repo.path, url: secret)
        }

        let survivingBytes = try #require(try repo.configData())
        let onDisk = try #require(String(data: survivingBytes, encoding: .utf8))
        #expect(onDisk == original, "the user's file is byte-for-byte untouched")
        // The reported state is human copy about the FILE and leaks no token.
        let state = await makeInstaller().state(repoPath: repo.path, expectedURL: secret)
        guard case .invalid(let reason) = state else {
            Issue.record("an unparseable file must report .invalid, got \(state)")
            return
        }
        #expect(!reason.contains("deadbeef"), "a health/state string must never carry the bus token")
        #expect(!reason.contains("127.0.0.1"))
    }

    @Test("trailing garbage after a valid object is damage, not JSON — fail closed")
    func trailingGarbageFailsClosed() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let original = #"{"mcpServers":{}} <<< merge conflict leftovers"#
        try repo.writeConfig(original)

        await #expect(throws: RepoMCPConfig.ConfigError.self) {
            try await makeInstaller().install(repoPath: repo.path, url: "http://127.0.0.1:1/bus/x")
        }
        let survivingBytes = try #require(try repo.configData())
        #expect(String(data: survivingBytes, encoding: .utf8) == original)
    }

    @Test("an mcpServers that is not an object is refused rather than replaced")
    func nonObjectServersFailsClosed() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let original = #"{"mcpServers": ["not", "a", "dictionary"]}"#
        try repo.writeConfig(original)

        await #expect(throws: RepoMCPConfig.ConfigError.self) {
            try await makeInstaller().install(repoPath: repo.path, url: "http://127.0.0.1:1/bus/x")
        }
        let survivingBytes = try #require(try repo.configData())
        #expect(String(data: survivingBytes, encoding: .utf8) == original)
    }

    @Test("a repo deleted from disk while linked reports repoUnavailable, and never crashes")
    func deletedRepoFailsGracefully() async throws {
        let repo = try TempRepo()
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/gone")
        repo.cleanUp()  // the human deletes the checkout

        await #expect(throws: RepoMCPConfig.ConfigError.repoUnavailable(path: repo.url.path)) {
            try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/gone")
        }
        // Uninstall on a vanished repo is a no-op, not a throw — deletion must
        // never be blocked by a repo that is not there.
        try await installer.uninstall(repoPath: repo.path)
        #expect(await installer.state(repoPath: repo.path, expectedURL: nil) == .missing)
    }

    /// P7 sharpened this from `.invalid` to `.conflict`: an entry Dispatch could
    /// not have written is somebody ELSE'S, and the difference matters — a
    /// conflict is the one state that blocks the install outright and demands an
    /// explicit human "Replace entry".
    @Test("a foreign 'dispatch' entry Dispatch didn't write reads as a conflict, not installed")
    func foreignDispatchEntryConflicts() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig(#"{"mcpServers":{"dispatch":"just a string"}}"#)

        let state = await makeInstaller().state(
            repoPath: repo.path, expectedURL: "http://127.0.0.1:5100/bus/x"
        )
        guard case .conflict = state else {
            Issue.record("a foreign dispatch entry must not read as installed, got \(state)")
            return
        }
    }
}

// MARK: - Uninstall

@Suite("Repo uninstall: remove ours, keep theirs")
struct RepoMCPUninstallTests {

    @Test("uninstall drops ONLY the dispatch key; every foreign server and key stays")
    func removesOnlyOurEntry() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig("""
        { "notes": "hand written", "mcpServers": {
            "tracker": { "type": "http", "url": "https://tracker.invalid" } } }
        """)
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/hhhh")

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.configExists, "a file we did not create is never deleted")
        let json = try repo.configJSON()
        #expect(json["notes"] as? String == "hand written")
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["tracker"])
    }

    @Test("a file the USER created keeps its empty shell even when we were the only server")
    func leavesForeignEmptyShell() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig(#"{"mcpServers":{}}"#)   // the user's own empty config
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/iiii")

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.configExists, "we did not create this file, so we do not delete it")
        let servers = try #require(try repo.configJSON()["mcpServers"] as? [String: Any])
        #expect(servers.isEmpty)
    }

    @Test("a file DISPATCH created is unlinked when our entry was all it held")
    func deletesOurOwnEmptyFile() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/jjjj")
        #expect(repo.configExists)

        try await installer.uninstall(repoPath: repo.path)

        #expect(!repo.configExists, "we created it, it is now empty — take it with us")
    }

    @Test("a file Dispatch created but the USER then added a server to keeps its shell")
    func keepsFileTheUserAdopted() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/kkkk")
        // The user adds their own server to the file we created.
        var json = try repo.configJSON()
        var servers = try #require(json["mcpServers"] as? [String: Any])
        servers["tracker"] = ["type": "http", "url": "https://tracker.invalid"]
        json["mcpServers"] = servers
        try repo.writeConfig(try JSONSerialization.data(withJSONObject: json))

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.configExists)
        let remaining = try #require(try repo.configJSON()["mcpServers"] as? [String: Any])
        #expect(Set(remaining.keys) == ["tracker"])
    }

    @Test("uninstall is idempotent and never invents a file")
    func uninstallIsIdempotent() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()

        try await installer.uninstall(repoPath: repo.path)      // nothing there
        #expect(!repo.configExists)
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/llll")
        try await installer.uninstall(repoPath: repo.path)
        try await installer.uninstall(repoPath: repo.path)      // twice
        #expect(!repo.configExists)
    }

    @Test("uninstall refuses to touch an unparseable file")
    func uninstallFailsClosedOnInvalidJSON() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let original = "{{{ not json"
        try repo.writeConfig(original)

        await #expect(throws: RepoMCPConfig.ConfigError.self) {
            try await makeInstaller().uninstall(repoPath: repo.path)
        }
        let survivingBytes = try #require(try repo.configData())
        #expect(String(data: survivingBytes, encoding: .utf8) == original)
    }

    @Test("deleting a project removes the repo entry FIRST, before any Dispatch-owned state")
    func deletionRunsRepoEntryFirst() async throws {
        actor Recorder {
            var steps: [String] = []
            func log(_ step: String) { steps.append(step) }
        }
        let recorder = Recorder()
        let deletion = ProjectDeletion(steps: ProjectDeletionSteps(
            removeRepoEntry: { await recorder.log("repo") },
            deleteProjectDatabase: { _ in await recorder.log("db") },
            releaseBookmark: { _ in await recorder.log("bookmark") },
            deleteRegistryRow: { _ in await recorder.log("registry") }
        ))

        try await deletion.run(projectID: UUID())

        #expect(await recorder.steps == ["repo", "db", "bookmark", "registry"])
    }
}

// MARK: - State reporting

@Suite("Repo install state")
struct RepoMCPStateTests {

    @Test("installed / missing / stale are distinguished against the expected URL")
    func statesAreDistinct() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        let installer = makeInstaller()
        let current = "http://127.0.0.1:5100/bus/mmmm"

        #expect(await installer.state(repoPath: repo.path, expectedURL: current) == .missing)
        try await installer.install(repoPath: repo.path, url: current)
        #expect(await installer.state(repoPath: repo.path, expectedURL: current) == .installed)
        // The port moved (or the token rotated) → the file on disk is stale.
        #expect(await installer.state(
            repoPath: repo.path, expectedURL: "http://127.0.0.1:5999/bus/mmmm"
        ) == .stale)
    }

    @Test("a file with other servers but no dispatch entry is MISSING, not invalid")
    func foreignOnlyFileIsMissing() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig(#"{"mcpServers":{"tracker":{"type":"http","url":"https://t.invalid"}}}"#)

        #expect(await makeInstaller().state(repoPath: repo.path, expectedURL: nil) == .missing)
    }
}

// MARK: - Port stability & concurrency

@Suite("Bus port stability")
struct BusPortStabilityTests {

    @Test("the listener re-binds the SAME port on a restart, so installed entries keep working")
    func rebindsPersistedPort() async throws {
        let first = MCPBusListener()
        await first.configure(router: try await BusRouterFixture().router)
        try await first.startIfNeeded()
        let port = try #require(await first.port)
        await first.stop()

        let second = MCPBusListener()
        await second.configure(router: try await BusRouterFixture().router)
        await second.setPreferredPort(port)
        try await second.startIfNeeded()
        defer { Task { await second.stop() } }

        #expect(await second.port == port, "a relaunch must reclaim the port the repos point at")
    }

    @Test("a taken port falls back to a fresh one instead of leaving the bus down")
    func fallsBackWhenPortIsTaken() async throws {
        let holder = MCPBusListener()
        await holder.configure(router: try await BusRouterFixture().router)
        try await holder.startIfNeeded()
        defer { Task { await holder.stop() } }
        let taken = try #require(await holder.port)

        let second = MCPBusListener()
        await second.configure(router: try await BusRouterFixture().router)
        await second.setPreferredPort(taken)
        try await second.startIfNeeded()
        defer { Task { await second.stop() } }

        let fresh = try #require(await second.port)
        #expect(fresh != taken, "the bus comes up on another port rather than not at all")
        #expect(fresh != 0)
    }

    @Test("a port change rewrites the entry and still preserves every foreign server")
    func portChangeRewritesEntries() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig(#"{"mcpServers":{"tracker":{"type":"http","url":"https://t.invalid"}}}"#)
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:5100/bus/token1")

        // The listener came up on a different port; every entry is rewritten.
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:6200/bus/token1")

        let servers = try #require(try repo.configJSON()["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["tracker", "dispatch"])
        #expect(try dispatchURL(in: try repo.configJSON()) == "http://127.0.0.1:6200/bus/token1")
    }

    @Test("a rotation racing a port-change rewrite leaves ONE coherent file, never a lost server")
    func concurrentWritesAreSerialized() async throws {
        let repo = try TempRepo()
        defer { repo.cleanUp() }
        try repo.writeConfig("""
        { "keepMe": true, "mcpServers": {
            "tracker": { "type": "http", "url": "https://tracker.invalid" } } }
        """)
        let installer = makeInstaller()

        // 24 interleaved writers: half look like token rotations, half like
        // port-change rewrites, all against the same repo at the same instant.
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    let port = index.isMultiple(of: 2) ? 5100 : 6200
                    try? await installer.install(
                        repoPath: repo.path,
                        url: "http://127.0.0.1:\(port)/bus/token\(index)"
                    )
                }
            }
        }

        // Whoever wrote last, the file is valid, the foreign content survived,
        // and there is exactly one dispatch entry.
        let json = try repo.configJSON()
        #expect(json["keepMe"] as? Bool == true)
        let servers = try #require(json["mcpServers"] as? [String: Any])
        #expect(Set(servers.keys) == ["tracker", "dispatch"])
        let url = try dispatchURL(in: json)
        #expect(url.hasPrefix("http://127.0.0.1:"))
    }
}

/// A minimal router fixture for listener-only tests.
@MainActor
private struct BusRouterFixture {
    let global: GlobalDatabase
    let router: DispatchRouter

    init() async throws {
        global = try await GlobalDatabase.openInMemory()
        router = DispatchRouter(global: global)
    }
}

// MARK: - End to end: two real repos, installed files only

/// A JSON-RPC client that knows ONE thing: the URL it was handed. Every URL in
/// this suite is parsed out of an installed `.mcp.json` — if the install path
/// were wrong in any way, these clients could not talk at all.
private struct InstalledClient {
    let url: URL
    private static let session = URLSession(configuration: .ephemeral)

    @discardableResult
    func post(_ body: [String: Any]) async throws -> (status: Int, json: [String: Any]?) {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.timeoutInterval = 60
        let (data, response) = try await Self.session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        return (status, try? JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    @discardableResult
    func initialize() async throws -> Int {
        try await post([
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": [
                "protocolVersion": "2025-03-26",
                "capabilities": [:],
                "clientInfo": ["name": "install-e2e", "version": "1.0"],
            ],
        ]).status
    }

    func callTool(_ name: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
        let response = try await post([
            "jsonrpc": "2.0", "id": Int.random(in: 2...9_999), "method": "tools/call",
            "params": ["name": name, "arguments": arguments],
        ])
        guard let result = response.json?["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            return ["_status": response.status]
        }
        var payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        payload["_isError"] = (result["isError"] as? Bool) ?? false
        payload["_text"] = text
        return payload
    }
}

@Suite("Repo install end to end")
@MainActor
struct RepoInstallEndToEndTests {

    /// Reads the URL a repo's INSTALLED `.mcp.json` advertises — the only thing
    /// an external Claude Code session would ever have.
    private func installedURL(in repo: TempRepo) throws -> URL {
        let json = try repo.configJSON()
        return try #require(URL(string: try dispatchURL(in: json)))
    }

    @Test("two real repos, added through ProjectStore, talk across the bus using ONLY their installed .mcp.json")
    func twoReposRoundTripThroughInstalledFiles() async throws {
        let alphaRepo = try TempRepo(gitInit: true)
        let betaRepo = try TempRepo(gitInit: true)
        defer { alphaRepo.cleanUp(); betaRepo.cleanUp() }

        // Real persistence (in-memory global DB), real ProjectStore writers —
        // the same closure bundle AppStores.live() builds.
        let global = try await GlobalDatabase.openInMemory()
        let store = ProjectStore(
            reader: global,
            writers: ProjectWriters(
                saveProject: { try await global.saveProject($0) },
                deleteProject: { try await global.deleteProject(id: $0) },
                deleteProjectFully: nil,
                setPinned: { try? await global.setPinned(projectID: $0, pinned: $1) },
                saveBookmark: { try await global.saveRepoBookmark(projectID: $0, bookmark: $1) },
                loadBookmark: { try await global.repoBookmark(projectID: $0) },
                updateGitCache: { try await global.updateGitStatusCache(projectID: $0, git: $1) },
                updateLastOpened: { try? await global.updateLastOpenedAt(projectID: $0, date: $1) }
            ),
            git: MockGitStatus(),
            gitRefreshInterval: nil
        )
        await store.activate()

        // ADD both projects through the real add path (bookmark + registry row).
        let alphaID = try await store.addProject(name: "AlphaRepo", folderURL: alphaRepo.url)
        let betaID = try await store.addProject(name: "BetaRepo", folderURL: betaRepo.url)
        // LINK them — consent is the human's, and it is what opens the door.
        try await global.saveProjectLink(ProjectLink(alphaID, betaID))

        // Bring up the bus and INSTALL into both repos, exactly as activateBus does.
        let router = DispatchRouter(global: global)
        router.setProjectNames([alphaID: "AlphaRepo", betaID: "BetaRepo"])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        defer { Task { await listener.stop() } }
        let installer = RepoMCPInstaller(ledger: .inMemory())
        for (id, repo) in [(alphaID, alphaRepo), (betaID, betaRepo)] {
            let token = try await global.busToken(projectID: id)
            let url = try await listener.register(projectID: id, token: token)
            try await installer.install(repoPath: repo.path, url: url)
        }

        // From here on we know NOTHING but what the files say.
        let alpha = InstalledClient(url: try installedURL(in: alphaRepo))
        let beta = InstalledClient(url: try installedURL(in: betaRepo))
        #expect(alpha.url != beta.url, "each repo gets its OWN identity")
        #expect(try await alpha.initialize() == 200)
        #expect(try await beta.initialize() == 200)

        // Each side sees exactly its linked peer.
        let peers = try await alpha.callTool("list_projects")
        #expect((peers["projects"] as? [[String: Any]])?.compactMap { $0["name"] as? String } == ["BetaRepo"])

        // Beta checks in (that is what makes it live), then Alpha asks and blocks.
        _ = try await beta.callTool("check_messages")
        // The payload crosses back as a JSON STRING (a [String: Any] is not
        // Sendable) and is decoded on this side.
        let askTask = Task<String, Error> { @Sendable in
            let result = try await alpha.callTool("ask_agent", [
                "project": "BetaRepo",
                "question": "Which module owns the install path?",
                "wait_seconds": 30,
            ])
            return (result["_text"] as? String) ?? ""
        }
        var questionID: String?
        for _ in 0..<200 where questionID == nil {
            let inbox = try await beta.callTool("check_messages")
            questionID = (inbox["open_questions"] as? [[String: Any]])?.first?["question_id"] as? String
            if questionID == nil { try await Task.sleep(for: .milliseconds(25)) }
        }
        let asked = try #require(questionID, "the question never crossed to the other repo")
        let recorded = try await beta.callTool(
            "answer_agent", ["question_id": asked, "answer": "RepoMCPInstaller does."]
        )
        #expect(recorded["status"] as? String == "recorded")

        let answeredText = try await askTask.value
        let answered = (try? JSONSerialization.jsonObject(with: Data(answeredText.utf8))
                        as? [String: Any]) ?? [:]
        #expect(answered["status"] as? String == "answered",
                "the long poll must return the answer inline, got \(answeredText)")
        #expect((answered["answer"] as? String)?.contains("RepoMCPInstaller does.") == true)

        // UNINSTALL: deleting Beta takes its entry (and its file — we made it)
        // and revokes the token, so the file that is left cannot reach the bus.
        try await installer.uninstall(repoPath: betaRepo.path)
        await listener.unregister(projectID: betaID)
        #expect(!betaRepo.configExists)
        let dead = try await beta.post(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        #expect(dead.status == 404)
        // Alpha is untouched by its peer's removal.
        #expect(try await alpha.initialize() == 200)
    }

    @Test("ASYNC path: ask with no wait lands in the inbox; the answer reaches the asker on its next check")
    func asyncInboxRoundTripThroughInstalledFiles() async throws {
        let alphaRepo = try TempRepo(gitInit: true)
        let betaRepo = try TempRepo(gitInit: true)
        defer { alphaRepo.cleanUp(); betaRepo.cleanUp() }

        let global = try await GlobalDatabase.openInMemory()
        let alphaID = UUID(), betaID = UUID()
        try await global.saveProject(
            Project(id: alphaID, name: "AlphaRepo", repoPath: alphaRepo.path, pinned: false))
        try await global.saveProject(
            Project(id: betaID, name: "BetaRepo", repoPath: betaRepo.path, pinned: false))
        try await global.saveProjectLink(ProjectLink(alphaID, betaID))

        let router = DispatchRouter(global: global)
        router.setProjectNames([alphaID: "AlphaRepo", betaID: "BetaRepo"])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        defer { Task { await listener.stop() } }
        let installer = RepoMCPInstaller(ledger: .inMemory())
        for (id, repo) in [(alphaID, alphaRepo), (betaID, betaRepo)] {
            let token = try await global.busToken(projectID: id)
            let url = try await listener.register(projectID: id, token: token)
            try await installer.install(repoPath: repo.path, url: url)
        }

        // Again: from here on we know NOTHING but what the two files say.
        let alpha = InstalledClient(url: try installedURL(in: alphaRepo))
        let beta = InstalledClient(url: try installedURL(in: betaRepo))
        #expect(try await alpha.initialize() == 200)
        #expect(try await beta.initialize() == 200)

        // Beta has NEVER checked in — nothing is live on the other end. The ask
        // returns immediately with a correlation id instead of blocking.
        let asked = try await alpha.callTool("ask_agent", [
            "project": "BetaRepo",
            "question": "Who owns the async path?",
        ])
        #expect(asked["status"] as? String == "pending",
                "an offline target must not block the asker, got \(asked)")
        let questionID = try #require(asked["question_id"] as? String)

        // Beta pulls it out of its inbox — the durable half of the bus.
        let inbox = try await beta.callTool("check_messages")
        let open = try #require(inbox["open_questions"] as? [[String: Any]])
        #expect(open.count == 1)
        #expect(open.first?["question_id"] as? String == questionID)
        #expect((open.first?["from_project"] as? String) == "AlphaRepo")

        let recorded = try await beta.callTool(
            "answer_agent", ["question_id": questionID, "answer": "The inbox does."])
        #expect(recorded["status"] as? String == "recorded")

        // The ASKER learns about it on its OWN next check — nobody was waiting.
        let alphaInbox = try await alpha.callTool("check_messages")
        let answers = try #require(alphaInbox["answers"] as? [[String: Any]])
        #expect(answers.count == 1)
        #expect(answers.first?["question_id"] as? String == questionID)
        #expect((answers.first?["answer"] as? String)?.contains("The inbox does.") == true)

        // Delivered ONCE: a second check does not re-deliver an outcome the
        // asker has already read (the answerSeenAt mark is durable).
        let again = try await alpha.callTool("check_messages")
        #expect((again["answers"] as? [[String: Any]])?.isEmpty ?? true,
                "an outcome the asker already saw must not be replayed")
        // And Beta's inbox is empty now that it answered.
        let betaAgain = try await beta.callTool("check_messages")
        #expect((betaAgain["open_questions"] as? [[String: Any]])?.isEmpty ?? true)
    }

    @Test("rotation rewrites the repo's file, and the URL the OLD file carried 404s")
    func rotationRewritesAndRevokes() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        let global = try await GlobalDatabase.openInMemory()
        let project = Project(id: UUID(), name: "Rotator", repoPath: repo.path, pinned: false)
        try await global.saveProject(project)
        let router = DispatchRouter(global: global)
        router.setProjectNames([project.id: project.name])
        let listener = MCPBusListener()
        await listener.configure(router: router)
        defer { Task { await listener.stop() } }
        let installer = RepoMCPInstaller(ledger: .inMemory())

        let firstToken = try await global.busToken(projectID: project.id)
        let firstURL = try await listener.register(projectID: project.id, token: firstToken)
        try await installer.install(repoPath: repo.path, url: firstURL)
        let leaked = InstalledClient(url: try installedURL(in: repo))
        #expect(try await leaked.initialize() == 200)

        // ROTATE: new token in the DB, re-registered on the listener, file rewritten.
        let secondToken = try await global.rotateBusToken(projectID: project.id)
        let secondURL = try await listener.register(projectID: project.id, token: secondToken)
        try await installer.install(repoPath: repo.path, url: secondURL)

        #expect(secondToken != firstToken)
        let rewritten = try installedURL(in: repo)
        #expect(rewritten.absoluteString == secondURL)
        #expect(rewritten.absoluteString != firstURL)
        // The URL a copy of the OLD file still carries is dead.
        let old = try await leaked.post(["jsonrpc": "2.0", "id": 1, "method": "initialize"])
        #expect(old.status == 404, "a stale .mcp.json copy must not reach the bus")
        #expect(try await InstalledClient(url: rewritten).initialize() == 200)
    }
}

// MARK: - P6 fresh-eyes seam: port collision on restart

@Suite("Bus port collision (P6 adversarial)")
@MainActor
struct BusPortCollisionSeamTests {

    /// SEAM 3 — the listener's port is TAKEN when the app restarts.
    ///
    /// The persisted port is what every installed `.mcp.json` already points
    /// at. If something else holds it, the bus must still come up on a fresh
    /// port, the stale URL must be DEAD (not quietly answered by whatever took
    /// the port), and re-installing must repoint the repo's file.
    @Test("a taken port never leaves the bus down: it rebinds elsewhere and the stale URL is dead")
    func portCollisionOnRestartRebindsAndRewrites() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        let global = try await GlobalDatabase.openInMemory()
        let project = Project(id: UUID(), name: "Rebinder", repoPath: repo.path, pinned: false)
        try await global.saveProject(project)
        let token = try await global.busToken(projectID: project.id)
        let installer = RepoMCPInstaller(ledger: .inMemory())

        // RUN 1 — the bus binds a port and the repo's file records it.
        let first = MCPBusListener()
        await first.configure(router: DispatchRouter(global: global))
        let firstURL = try await first.register(projectID: project.id, token: token)
        let firstPort = try #require(await first.port)
        try await installer.install(repoPath: repo.path, url: firstURL)
        let staleClient = InstalledClient(url: try #require(URL(string: firstURL)))
        #expect(try await staleClient.initialize() == 200)

        // The port stays HELD across the "restart" — this listener stands in for
        // any other process (a second Dispatch, an unrelated server) that
        // grabbed it while the app was closed.

        // RUN 2 — a fresh listener asks for the same port and cannot have it.
        let second = MCPBusListener()
        await second.configure(router: DispatchRouter(global: global))
        await second.setPreferredPort(firstPort)
        let secondURL = try await second.register(projectID: project.id, token: token)
        defer { Task { await second.stop(); await first.stop() } }
        let secondPort = try #require(await second.port)

        #expect(secondPort != firstPort, "the held port cannot be taken twice")
        #expect(secondURL != firstURL)
        // The bus is UP — a collision must never leave the app without one.
        #expect(try await InstalledClient(url: try #require(URL(string: secondURL))).initialize() == 200)

        // Until the file is rewritten it points at the OLD port. That endpoint
        // is not ours any more, so a session using it must not silently keep
        // working against a stale identity — the installed URL has to be
        // refreshed, which is exactly what activateBus() does on a port change.
        try await installer.install(repoPath: repo.path, url: secondURL)
        let onDisk = try dispatchURL(in: try repo.configJSON())
        #expect(onDisk == secondURL, "the repo's entry must follow the bus to its new port")
        #expect(!onDisk.contains(":\(firstPort)/"))

        // Belt and braces: the OLD listener really is a different bus. Shutting
        // the impostor down leaves the stale URL unreachable rather than
        // answering with someone else's identity.
        await first.stop()
        await #expect(throws: (any Error).self) { _ = try await staleClient.initialize() }
    }
}

// MARK: - .gitignore hygiene

/// The `.mcp.json` we write carries a bus TOKEN. These tests are about the two
/// halves of the only defensible policy: a file that exists because of Dispatch
/// is Dispatch's to keep out of git, and a file that was already there is not
/// ours to make decisions about at all.
@Suite("Repo install: keeping the bus token out of git")
struct RepoGitignoreTests {

    private let url = "http://127.0.0.1:51234/bus/token-abc"

    // MARK: The pure parse

    @Test("every spelling git accepts for ignoring .mcp.json is recognised")
    func recognisesTheRulesThatAlreadyCoverIt() {
        for text in [
            ".mcp.json\n",
            "/.mcp.json\n",
            "**/.mcp.json\n",
            "*.json\n",
            "# a comment\n\n.mcp.json\n",
            ".mcp.json   \n",                 // trailing whitespace
            "build/\r\n.mcp.json\r\n",        // CRLF
            ".mcp.json",                      // no trailing newline
            ".mcp.json\n!.mcp.json\n.mcp.json\n",  // last match wins
        ] {
            #expect(RepoGitignore.ignoresEntry(text), "should already cover it: \(text.debugDescription)")
        }
        for text in [
            "",
            "node_modules\n",
            "#.mcp.json\n",                   // a comment, not a rule
            ".mcp.json/\n",                   // a DIRECTORY rule cannot match a file
            "sub/.mcp.json\n",                // not the root file
            ".mcp.json\n!.mcp.json\n",        // negated last
            "mcp.json\n",                     // a different file
        ] {
            #expect(!RepoGitignore.ignoresEntry(text), "should NOT count: \(text.debugDescription)")
        }
    }

    @Test("adding is idempotent, keeps the file's line endings, and survives a missing newline")
    func addingIsWellBehaved() throws {
        // From nothing.
        let fresh = try #require(RepoGitignore.adding(to: nil))
        #expect(fresh == "\(RepoGitignore.marker)\n.mcp.json\n")
        #expect(RepoGitignore.adding(to: fresh) == nil, "a second pass has nothing to do")

        // A file whose last line has NO terminator does not get our comment
        // glued onto the end of the user's rule.
        let unterminated = try #require(RepoGitignore.adding(to: "node_modules"))
        #expect(unterminated.hasPrefix("node_modules\n"))
        #expect(unterminated.hasSuffix(".mcp.json\n"))
        #expect(RepoGitignore.ignoresEntry(unterminated))
        #expect(!unterminated.contains("node_modules\(RepoGitignore.marker)"))

        // CRLF in, CRLF out — a repo full of CRLF must not grow one LF line.
        let crlf = try #require(RepoGitignore.adding(to: "build\r\n*.log\r\n"))
        #expect(crlf.hasPrefix("build\r\n*.log\r\n"))
        #expect(crlf.hasSuffix("\(RepoGitignore.marker)\r\n.mcp.json\r\n"))
        #expect(!crlf.replacingOccurrences(of: "\r\n", with: "").contains("\n"),
                "not one bare LF may be introduced: \(crlf.debugDescription)")
        #expect(RepoGitignore.ignoresEntry(crlf))
        #expect(RepoGitignore.adding(to: crlf) == nil)

        // A repo that ignores it some OTHER way never grows a redundant line.
        #expect(RepoGitignore.adding(to: "*.json\n") == nil)
    }

    @Test("removing takes our block and nothing else — CRLF and neighbours intact")
    func removingTakesOnlyOurs() throws {
        #expect(RepoGitignore.removing(from: "node_modules\n.mcp.json\n") == nil,
                "an UNMARKED .mcp.json line is the user's, and stays")

        let added = try #require(RepoGitignore.adding(to: "node_modules\n.env\n"))
        let removed = try #require(RepoGitignore.removing(from: added))
        #expect(removed == "node_modules\n.env\n", "byte-for-byte what was there before")

        let crlf = try #require(RepoGitignore.adding(to: "build\r\n"))
        #expect(RepoGitignore.removing(from: crlf) == "build\r\n")

        // Our block sitting between the user's rules leaves them adjacent again.
        let sandwiched = "a\n\n\(RepoGitignore.marker)\n.mcp.json\n\nb\n"
        #expect(RepoGitignore.removing(from: sandwiched) == "a\n\nb\n")
    }

    // MARK: Through the installer

    @Test("a .mcp.json we CREATED is gitignored, idempotently, and the line goes on uninstall")
    func createdFileIsIgnoredAndCleanedUp() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        let installer = makeInstaller()

        try await installer.install(repoPath: repo.path, url: url)

        let text = try #require(repo.gitignoreText())
        #expect(text.contains(RepoGitignore.marker))
        #expect(RepoGitignore.ignoresEntry(text))
        // No notice: the token is not going anywhere.
        #expect(await installer.tokenExposure(repoPath: repo.path) == .none)

        // Installing again (a port change, a token rotation) writes no second copy.
        try await installer.install(repoPath: repo.path, url: "http://127.0.0.1:51235/bus/token-abc")
        #expect(repo.gitignoreText() == text)

        // And the line is OURS to take back.
        try await installer.uninstall(repoPath: repo.path)
        #expect(!repo.gitignoreExists, "a .gitignore that held nothing but our line goes with it")
    }

    @Test("a .gitignore that was ONLY a blank line is the user's, and survives")
    func anAlmostEmptyGitignoreIsStillTheUsersFile() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        try repo.writeGitignore("\n")
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: url)
        #expect(RepoGitignore.ignoresEntry(try #require(repo.gitignoreText())))

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.gitignoreExists, "one stray newline is not a reason to delete a file")
        #expect(repo.gitignoreText() == "\n")
    }

    @Test("uninstall removes our line and leaves every other line exactly as it was")
    func uninstallKeepsTheUsersRules() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        try repo.writeGitignore("node_modules\n.DS_Store\n")
        let installer = makeInstaller()
        try await installer.install(repoPath: repo.path, url: url)
        #expect(RepoGitignore.ignoresEntry(try #require(repo.gitignoreText())))

        try await installer.uninstall(repoPath: repo.path)

        #expect(repo.gitignoreText() == "node_modules\n.DS_Store\n")
    }

    @Test("a repo that ALREADY ignores .mcp.json never grows a line of ours")
    func anAlreadyIgnoringRepoIsLeftAlone() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        try repo.writeGitignore("*.json\n")

        try await makeInstaller().install(repoPath: repo.path, url: url)

        #expect(repo.gitignoreText() == "*.json\n")
    }

    @Test("a PRE-EXISTING .mcp.json: .gitignore untouched, and the exposure is surfaced")
    func preExistingFileIsNeverGitignoredForYou() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        // The team-shared case: the repo brought its own file.
        try repo.writeConfig(#"{"mcpServers":{"other":{"type":"stdio","command":"x"}}}"#)
        try repo.writeGitignore("node_modules\n")
        let installer = makeInstaller()

        try await installer.install(repoPath: repo.path, url: url)

        #expect(repo.gitignoreText() == "node_modules\n",
                "a file that was already there is not ours to make decisions about")
        #expect(await installer.tokenExposure(repoPath: repo.path) == .committedFile)
        // Uninstall does not go near it either.
        try await installer.uninstall(repoPath: repo.path)
        #expect(repo.gitignoreText() == "node_modules\n")
    }

    @Test("pre-existing BUT already ignored → no notice, because there is nothing to say")
    func preExistingAndAlreadyIgnoredIsQuiet() async throws {
        let repo = try TempRepo(gitInit: true)
        defer { repo.cleanUp() }
        try repo.writeConfig(#"{"mcpServers":{}}"#)
        try repo.writeGitignore("# local config\n.mcp.json\n")
        let installer = makeInstaller()

        try await installer.install(repoPath: repo.path, url: url)

        #expect(await installer.tokenExposure(repoPath: repo.path) == .none)
        #expect(repo.gitignoreText() == "# local config\n.mcp.json\n")
    }

    @Test("no git, no .mcp.json, and no entry are all quiet — and none of them writes a .gitignore")
    func nothingToSayIsSaidNowhere() async throws {
        // A folder that is not a git checkout at all.
        let plain = try TempRepo()
        defer { plain.cleanUp() }
        let installer = makeInstaller()
        try await installer.install(repoPath: plain.path, url: url)
        #expect(!plain.gitignoreExists, "a folder with no .git has nothing to ignore into")
        #expect(await installer.tokenExposure(repoPath: plain.path) == .none)

        // A git repo with a pre-existing config, before any install: no file
        // state to be exposed about until the entry is actually in there.
        let empty = try TempRepo(gitInit: true)
        defer { empty.cleanUp() }
        #expect(await makeInstaller().tokenExposure(repoPath: empty.path) == .none)
    }
}

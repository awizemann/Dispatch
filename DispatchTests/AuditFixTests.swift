// AuditFixTests.swift
// The P7 fresh-eyes audit findings, each pinned by a test that FAILS on the old
// behaviour:
//   S1 the router's project-name map is driven by the registry observation, so a
//      project added after launch is reachable and a renamed one stops answering
//      to its old name;
//   S2 install state is RE-VERIFIED from the file rather than remembered, a
//      foreign `dispatch` entry is never clobbered, and a question lapses on a
//      bus with no traffic at all;
//   S3 the repo ROOT (not the picked subdirectory) is what gets stored and
//      installed, and a failed rotation is said out loud.
//
// Everything here runs against real in-memory databases and real temp files —
// the findings were all "the app believes something the world does not", and a
// fake world cannot catch that.

import Foundation
import Testing
@testable import DispatchApp

// MARK: - Fixture

/// A live-shaped AppStores: real GlobalDatabase, real router, real registry
/// observation — but no listener bind and no repo installs, so the wiring under
/// test is the wiring the app runs and nothing else is dragged in.
@MainActor
private struct StoresFixture {
    let global: GlobalDatabase
    let router: DispatchRouter
    let stores: AppStores

    init() async throws {
        global = try await GlobalDatabase.openInMemory()
        router = DispatchRouter(global: global)
        let writers = ProjectWriters(
            saveProject: { [global] in try await global.saveProject($0) },
            deleteProject: { [global] in try await global.deleteProject(id: $0) },
            setPinned: { _, _ in },
            saveBookmark: { _, _ in },
            loadBookmark: { _ in nil },
            updateGitCache: { _, _ in },
            updateLastOpened: { _, _ in }
        )
        stores = AppStores(
            projects: ProjectStore(
                reader: global, writers: writers,
                git: MockGitStatus(), gitRefreshInterval: nil
            ),
            messages: MessageStore(global: global),
            activity: ActivityStore(),
            crossProject: CrossProjectStore(global: global)
        )
        stores.global = global
        stores.router = router
        stores.arbitration = router
        router.onEvent = { [stores] event in stores.handle(busEvent: event) }
        stores.wireRegistryHooks()
        await stores.projects.activate()
    }

    func addProject(_ name: String, path: String = "/tmp/audit-\(UUID().uuidString)") async throws -> UUID {
        let project = Project(id: UUID(), name: name, repoPath: path, pinned: false)
        try await global.saveProject(project)
        return project.id
    }
}

// MARK: - S1: the router's name map follows the registry

@Suite("S1 — the router's project names follow the registry", .serialized)
@MainActor
struct RouterNameMapTests {

    @Test("a project added AFTER activation is addressable — list_projects sees it and ask_agent resolves it")
    func projectAddedAfterActivationIsReachable() async throws {
        let fixture = try await StoresFixture()
        let caller = try await fixture.addProject("Caller")
        #expect(try await pollUntil { fixture.router.projectName(caller) == "Caller" })

        // The late arrival — exactly the case the frozen map could not see.
        let late = try await fixture.addProject("LateComer")
        try await fixture.global.saveProjectLink(ProjectLink(caller, late))
        #expect(try await pollUntil { fixture.router.projectName(late) == "LateComer" })

        let peers = try await fixture.router.listProjects(callerProjectID: caller)
        #expect(peers.map(\.name) == ["LateComer"],
                "list_projects drops a peer whose name the router cannot resolve")

        let outcome = try await fixture.router.ask(
            callerProjectID: caller, targetProject: "LateComer",
            question: "are you reachable?", waitSeconds: nil
        )
        guard case .pending(let message) = outcome else {
            Issue.record("expected a durable pending question, got \(outcome)")
            return
        }
        #expect(message.to == late)
    }

    @Test("a rename retires the old name in the same breath the new one starts working")
    func renameRetiresTheOldName() async throws {
        let fixture = try await StoresFixture()
        let caller = try await fixture.addProject("Caller")
        let peer = try await fixture.addProject("Before")
        try await fixture.global.saveProjectLink(ProjectLink(caller, peer))
        #expect(try await pollUntil { fixture.router.projectName(peer) == "Before" })

        try await fixture.stores.projects.renameProject(id: peer, name: "After")
        #expect(try await pollUntil { fixture.router.projectName(peer) == "After" })

        #expect(try await fixture.router.resolvePeer(of: caller, named: "After") == peer)
        await #expect(throws: BusToolFailure.unknownProject("Before")) {
            _ = try await fixture.router.resolvePeer(of: caller, named: "Before")
        }
    }

    @Test("a deleted project stops resolving and its per-project bus state is dropped")
    func deletedProjectStopsResolving() async throws {
        let fixture = try await StoresFixture()
        let doomed = try await fixture.addProject("Doomed")
        #expect(try await pollUntil { fixture.router.projectName(doomed) == "Doomed" })
        fixture.stores.repoInstallStates[doomed] = .installed

        try await fixture.global.deleteProject(id: doomed)
        #expect(try await pollUntil { fixture.router.projectName(doomed) == nil })
        #expect(fixture.stores.repoInstallStates[doomed] == nil,
                "install state for a row that no longer exists is not state, it is a lie")
    }
}

// MARK: - S2: install state is re-verified, not remembered

@Suite("S2 — install state is re-read from the repo", .serialized)
@MainActor
struct InstallVerificationTests {

    /// A throwaway repo directory.
    private func makeRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    @Test("a hand-removed entry stops reporting installed — the footer count follows the FILE")
    func handRemovedEntryBecomesMissing() async throws {
        let fixture = try await StoresFixture()
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let projectID = try await fixture.addProject("Repo", path: repo.path)
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })

        let entry = repo.appendingPathComponent(".mcp.json")
        try Data(#"{"mcpServers":{"dispatch":{"type":"http","url":"http://127.0.0.1:51872/bus/\#(String(repeating: "a", count: 32))"}}}"#.utf8)
            .write(to: entry)
        await fixture.stores.verifyRepoInstall(for: projectID)
        #expect(fixture.stores.repoInstallStates[projectID] == .installed)

        // The hand edit the old code could never see.
        try FileManager.default.removeItem(at: entry)
        await fixture.stores.verifyRepoInstall(for: projectID)
        #expect(fixture.stores.repoInstallStates[projectID] == .missing,
                ".missing must be REACHABLE in production, not just in unit tests")
    }

    @Test("a foreign dispatch entry reads as a conflict, never as ours")
    func foreignEntryReadsAsConflict() async throws {
        let fixture = try await StoresFixture()
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let projectID = try await fixture.addProject("Repo", path: repo.path)
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })

        try Data(#"{"mcpServers":{"dispatch":{"command":"some-other-dispatch"}}}"#.utf8)
            .write(to: repo.appendingPathComponent(".mcp.json"))
        await fixture.stores.verifyRepoInstall(for: projectID)
        guard case .conflict = fixture.stores.repoInstallStates[projectID] else {
            Issue.record("expected .conflict, got \(String(describing: fixture.stores.repoInstallStates[projectID]))")
            return
        }
    }
}

// MARK: - S2: the name-collision clobber

@Suite("S2 — a foreign “dispatch” entry is never silently overwritten")
struct ForeignEntryTests {

    private func makeRepo() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-foreign-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private let ourURL = "http://127.0.0.1:51872/bus/" + String(repeating: "f", count: 32)

    @Test("install REFUSES a foreign entry and leaves the file byte-identical")
    func installRefusesForeignEntry() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let entry = repo.appendingPathComponent(".mcp.json")
        let original = Data(#"""
        {
          "mcpServers" : {
            "dispatch" : {
              "command" : "npx",
              "args" : ["some-other-dispatch"]
            },
            "keep-me" : { "type" : "http", "url" : "http://example.test/x" }
          }
        }
        """#.utf8)
        try original.write(to: entry)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        await #expect(throws: RepoMCPConfig.ConfigError.foreignEntry(path: entry.path)) {
            try await installer.install(repoPath: repo.path, url: ourURL)
        }
        #expect(try Data(contentsOf: entry) == original,
                "a refusal must not touch a single byte of someone else's config")
    }

    @Test("an explicit Replace entry overwrites it — and only then")
    func explicitReplaceOverwrites() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let entry = repo.appendingPathComponent(".mcp.json")
        try Data(#"{"mcpServers":{"dispatch":{"command":"other"},"keep-me":{"type":"http","url":"http://example.test/x"}}}"#.utf8)
            .write(to: entry)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        let outcome = try await installer.install(
            repoPath: repo.path, url: ourURL, replacingForeignEntry: true
        )
        #expect(outcome.changed)
        let root = try RepoMCPConfig.parse(try Data(contentsOf: entry), path: entry.path)
        let servers = try RepoMCPConfig.servers(in: root, path: entry.path)
        #expect((servers["dispatch"] as? [String: Any])?["url"] as? String == ourURL)
        #expect(servers["keep-me"] != nil, "the value-faithful merge still holds on the replace path")
        // And it is OURS now.
        let state = await installer.state(repoPath: repo.path, expectedURL: ourURL)
        #expect(state == .installed)
    }

    @Test("uninstall leaves a foreign entry alone — we only delete what we created")
    func uninstallLeavesForeignEntry() async throws {
        let repo = try makeRepo()
        defer { try? FileManager.default.removeItem(at: repo) }
        let entry = repo.appendingPathComponent(".mcp.json")
        let original = Data(#"{"mcpServers":{"dispatch":{"command":"other"}}}"#.utf8)
        try original.write(to: entry)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        try await installer.uninstall(repoPath: repo.path)
        #expect(try Data(contentsOf: entry) == original)
    }

    @Test("authorship, not just presence: only Dispatch's own URL shape counts as ours")
    func urlShapeDecidesAuthorship() {
        let token = String(repeating: "0", count: 32)
        #expect(RepoMCPConfig.isDispatchWrittenURL("http://127.0.0.1:51872/bus/\(token)"))
        #expect(!RepoMCPConfig.isDispatchWrittenURL("http://127.0.0.1:51872/bus/"))
        #expect(!RepoMCPConfig.isDispatchWrittenURL("http://127.0.0.1:51872/other/\(token)"))
        #expect(!RepoMCPConfig.isDispatchWrittenURL("http://10.0.0.4:51872/bus/\(token)"))
        #expect(!RepoMCPConfig.isDispatchWrittenURL("https://127.0.0.1:51872/bus/\(token)"))
        #expect(!RepoMCPConfig.isDispatchWrittenURL("nonsense"))
    }
}

// MARK: - S2: expiry without traffic

@Suite("S2 — a question lapses on a silent bus")
@MainActor
struct TimedExpiryTests {

    @Test("the periodic sweep expires a lapsed question with NO bus traffic at all")
    func timerSweepsWithoutTraffic() async throws {
        let global = try await GlobalDatabase.openInMemory()
        let asker = Project(id: UUID(), name: "Asker", repoPath: "/tmp/a", pinned: false)
        let target = Project(id: UUID(), name: "Target", repoPath: "/tmp/b", pinned: false)
        try await global.saveProject(asker)
        try await global.saveProject(target)
        let router = DispatchRouter(global: global)
        router.setProjectNames([asker.id: asker.name, target.id: target.name])

        // A question that lapsed a second ago. Nothing will ever call a tool on
        // this bus again — the old lazy sweep left it rendering "expiring now".
        let message = BusMessage(
            id: BusMessage.mintID(), from: asker.id, to: target.id,
            subject: "s", body: "b",
            askedAt: Date().addingTimeInterval(-120),
            expiresAt: Date().addingTimeInterval(-1)
        )
        try await global.saveBusMessage(message)

        var closed: [String] = []
        router.onEvent = { event in
            if case .closed(let m) = event { closed.append(m.id) }
        }
        router.startExpirySweep(interval: .milliseconds(40))
        defer { router.stopExpirySweep() }

        var settled: BusMessage?
        for _ in 0..<40 {
            try await Task.sleep(for: .milliseconds(50))
            settled = try await global.fetchBusMessage(id: message.id)
            if settled?.status == .expired { break }
        }
        #expect(settled?.status == .expired)
        #expect(closed == [message.id], "the ticker/inbox learn about it through the usual event")
    }
}

// MARK: - S3: the repo root

@Suite("S3 — a project is created at the git ROOT", .serialized)
@MainActor
struct RepoRootTests {

    @Test("picking a subdirectory of a real repo submits the repo root, not the subfolder")
    func subdirectoryResolvesToRoot() async throws {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory
            .appendingPathComponent("dispatch-root-\(UUID().uuidString)", isDirectory: true)
        let sub = root.appendingPathComponent("Sources/Deep", isDirectory: true)
        try fileManager.createDirectory(at: sub, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: root) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "init", "--quiet", "-b", "main", root.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()

        let form = ProjectFormModel(mode: .add, existingProjects: [], git: GitClient())
        form.folderPicked(sub)
        #expect(try await pollUntil { form.canSubmit })

        // The picked path is what the human chose; the SUBMISSION path is where
        // a Claude Code session started in this repo will look for .mcp.json.
        #expect(form.pickedPath == sub.standardizedFileURL.path)
        // git reports the root through /private, the panel hands back /var — so
        // the assertion is on the RELATIONSHIP, which is the actual contract:
        // the submission path is the picked folder's repo ancestor, not itself.
        let submitted = try #require(form.submissionPath)
        #expect(submitted != form.pickedPath, "the subfolder must not be what gets stored")
        #expect(URL(fileURLWithPath: submitted).lastPathComponent == root.lastPathComponent)
        #expect(sub.path.hasSuffix("Sources/Deep"))
        #expect(!submitted.hasSuffix("Sources") && !submitted.hasSuffix("Deep"))
        #expect(form.trimmedName == root.lastPathComponent,
                "the suggested name follows the repo, not the subfolder")
    }
}

// MARK: - S3: failures are said out loud

@Suite("S3 — a failed action is not silent", .serialized)
@MainActor
struct SilentFailureTests {

    @Test("a rotation that cannot run raises an alert and leaves a ticker line")
    func rotationFailureSurfaces() async throws {
        let fixture = try await StoresFixture()
        let projectID = try await fixture.addProject("Ledgerline")
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })
        // No global database behind the store = the rotation cannot happen. The
        // old code returned nil and said nothing at all.
        fixture.stores.global = nil

        let url = await fixture.stores.rotateBusToken(for: projectID)
        #expect(url == nil)
        #expect(fixture.stores.problemAlert?.contains("Ledgerline") == true)
        #expect(fixture.stores.activity.latest(for: projectID)?.category == .other)
    }

    @Test("a reported problem lands on every project it names, and clears when dismissed")
    func reportedProblemReachesTheTicker() async throws {
        let fixture = try await StoresFixture()
        let first = try await fixture.addProject("First")
        let second = try await fixture.addProject("Second")
        #expect(try await pollUntil { fixture.stores.projects.projects.count == 2 })

        fixture.stores.report(problem: "couldn't save that link", blocking: true,
                              projectIDs: [first, second])
        #expect(fixture.stores.activity.latest(for: first)?.text == "couldn't save that link")
        #expect(fixture.stores.activity.latest(for: second)?.text == "couldn't save that link")
        #expect(fixture.stores.problemAlert != nil)
        fixture.stores.problemAlert = nil
        #expect(fixture.stores.problemAlert == nil)
    }
}

// MARK: - S1: the restart cue

@Suite("S1 — the restart cue is evidence-based", .serialized)
@MainActor
struct RestartCueTests {

    @Test("traffic from a repo's session clears its restart cue")
    func trafficClearsTheCue() async throws {
        let fixture = try await StoresFixture()
        let projectID = try await fixture.addProject("Ledgerline")
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })

        fixture.stores.sessionsNeedingRestart = [projectID]
        #expect(fixture.stores.needsSessionRestart(projectID))
        // The router's own connected event is the ONLY evidence Dispatch can
        // honestly have that the session restarted — it cannot see a terminal.
        fixture.stores.handle(busEvent: .connected(projectID: projectID))
        #expect(!fixture.stores.needsSessionRestart(projectID))
    }

    @Test("a cue for a repo whose entry is no longer ours is dropped, not left nagging")
    func brokenEntryDropsTheCue() async throws {
        let fixture = try await StoresFixture()
        let repo = FileManager.default.temporaryDirectory
            .appendingPathComponent("dispatch-cue-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let projectID = try await fixture.addProject("Ledgerline", path: repo.path)
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })

        fixture.stores.sessionsNeedingRestart = [projectID]
        // No .mcp.json at all → .missing, so "restart to pick up the entry we
        // wrote" is about an entry that is not there.
        await fixture.stores.verifyRepoInstall(for: projectID)
        #expect(fixture.stores.repoInstallStates[projectID] == .missing)
        #expect(!fixture.stores.needsSessionRestart(projectID))
    }

    @Test("a project removed from the registry takes its cue with it")
    func deletionDropsTheCue() async throws {
        let fixture = try await StoresFixture()
        let projectID = try await fixture.addProject("Gone")
        #expect(try await pollUntil { fixture.stores.projects.project(id: projectID) != nil })
        fixture.stores.sessionsNeedingRestart = [projectID]

        try await fixture.global.deleteProject(id: projectID)
        #expect(try await pollUntil { !fixture.stores.needsSessionRestart(projectID) })
    }
}

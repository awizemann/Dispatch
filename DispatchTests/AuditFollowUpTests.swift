// AuditFollowUpTests.swift
// The second wave of fresh-eyes audit findings, each pinned by a
// test that FAILS on the old behaviour. M1 (cross-row map routing) lives in
// BusMapTests.swift, next to the layout property it now asserts; everything
// else is here:
//   M2 the icon decode is not main-actor-bound, and refreshAll covers every
//      project rather than stalling on the first slow repo;
//   L1 a symlinked intermediate directory cannot walk a lookup out of the repo;
//   L2 pruning sweeps EVERY per-project map, so a reused id is not born with a
//      stale "seeded" flag that suppresses discovery forever;
//   L3 the entry cap binds before a huge directory is materialised;
//   L4 the map header counts the LINES the map draws, not the link rows;
//   L5 a `.gitignore` the user already had survives uninstall.
//
// Real temp files and real symlinks throughout: every one of these findings was
// about what the filesystem (or the geometry) actually does, and a stubbed world
// cannot catch that.

import AppKit
import Darwin
import Foundation
import Testing

@testable import DispatchApp

// MARK: - Fixtures

private enum Fixture {

    static func root(_ label: String) throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dispatch-followup-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) { try? FileManager.default.removeItem(at: url) }

    /// A real, decodable PNG.
    @discardableResult
    static func png(at url: URL, side: Int) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemTeal.setFill()
        NSRect(x: 0, y: 0, width: side, height: side).fill()
        NSGraphicsContext.restoreGraphicsState()
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
}

// MARK: - M2: the decode is off the main actor

@Suite("Icon decode is not main-actor work")
struct IconDecodeIsolationTests {

    /// The finding, made mechanical. `safelyDecoded` and `firstDecodable` are
    /// `nonisolated`, so this compiles and runs INSIDE a detached task — which
    /// it could not have done while the loader was `@MainActor`. If either ever
    /// goes back to the main actor this file stops building, which is the
    /// strongest form this assertion can take.
    @Test("the bounded decoder runs from a detached, non-main context")
    func decodeRunsOffMain() async throws {
        let root = try Fixture.root("offmain")
        defer { Fixture.remove(root) }
        let file = try Fixture.png(at: root.appendingPathComponent("favicon.png"), side: 64)

        let measured = await Task.detached(priority: .utility) { () -> (onMain: Bool, width: Int)? in
            // `Thread.isMainThread` is unavailable from an async context; the
            // pthread question underneath it is not.
            let onMain = pthread_main_np() != 0
            guard case .decoded(let pixels) = ProjectIconLoader.safelyDecoded(file)
            else { return nil }
            return (onMain, pixels.width)
        }.value
        let result = try #require(measured)
        #expect(!result.onMain, "the decode must not have hopped back to the main thread")
        #expect(result.width == 64)
    }

    @Test("candidate scanning also runs detached, and hands back Sendable pixels")
    func scanRunsOffMain() async throws {
        let root = try Fixture.root("scan")
        defer { Fixture.remove(root) }
        try Fixture.png(at: root.appendingPathComponent("favicon.png"), side: 96)
        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)

        let loaded = await Task.detached(priority: .utility) {
            ProjectIconLoader.firstDecodable(candidates)
        }.value
        let pixels = try #require(loaded?.pixels)
        #expect(pixels.width == 96)
    }
}

@MainActor
@Suite("Icon cache refreshAll")
struct IconRefreshAllTests {

    /// refreshAll used to walk projects strictly one after another on the main
    /// actor. It now goes out in bounded batches — the observable contract is
    /// simply that EVERY project ends up with its icon, whatever the batching.
    @Test("refreshAll populates every project, past one batch's worth")
    func refreshAllCoversEveryProject() async throws {
        // More than `refreshWindow`, so at least two batches are exercised.
        let count = ProjectIconStore.refreshWindow * 2 + 1
        var roots: [URL] = []
        defer { roots.forEach(Fixture.remove) }
        var repoByID: [UUID: URL] = [:]
        var ids: [UUID] = []
        for index in 0..<count {
            let root = try Fixture.root("all-\(index)")
            roots.append(root)
            // Distinct sizes, so a mixed-up mapping would show as a wrong icon
            // rather than merely a present one.
            try Fixture.png(at: root.appendingPathComponent("favicon.png"),
                            side: 16 + index * 8)
            let id = UUID()
            ids.append(id)
            repoByID[id] = root
        }

        let store = ProjectIconStore()
        let lookup = repoByID
        store.repoURLProvider = { lookup[$0] }
        await store.refreshAll(projectIDs: ids)

        for (index, id) in ids.enumerated() {
            #expect(store.icon(for: id)?.size.width == CGFloat(16 + index * 8),
                    "project \(index) did not get its own icon")
        }
    }

    /// L2. The doc comment on `prune` promised this and the code did not do it:
    /// `seededIDs` survived, and `refresh` returns EARLY for a seeded id — so a
    /// recycled UUID could never discover its real repo's icon.
    @Test("pruning clears the seeded flag, so a reused id can still discover")
    func pruneClearsSeededFlag() async throws {
        let root = try Fixture.root("seed")
        defer { Fixture.remove(root) }
        try Fixture.png(at: root.appendingPathComponent("favicon.png"), side: 48)

        let store = ProjectIconStore()
        store.repoURLProvider = { _ in root }
        let id = UUID()
        store.seed(NSImage(size: NSSize(width: 8, height: 8)), for: id)
        #expect(store.icon(for: id)?.size.width == 8)

        // The project is deleted…
        store.prune(knownProjectIDs: [])
        #expect(store.icon(for: id) == nil)
        // …and its id comes back around on a real repo.
        await store.refresh(projectID: id)
        #expect(store.icon(for: id)?.size.width == 48,
                "a stale seeded flag suppressed discovery for the reused id")
    }

    /// The other half of L2: the walk-timestamp map is swept too, so a long
    /// session of add-and-remove does not accumulate a row per id forever.
    @Test("pruning clears the last-walk timestamp with the rest")
    func pruneClearsWalkTimestamps() async throws {
        let root = try Fixture.root("walk")
        defer { Fixture.remove(root) }
        let store = ProjectIconStore()
        store.repoURLProvider = { _ in root }
        store.emptyRecheckInterval = 3_600
        let id = UUID()
        let now = Date(timeIntervalSince1970: 1_000)

        // An empty repo: walked, remembered as empty, and a re-check inside the
        // interval is suppressed.
        await store.refresh(projectID: id, now: now)
        #expect(store.icon(for: id) == nil)
        // Now the project goes away and its id is reused on a repo WITH an icon.
        store.prune(knownProjectIDs: [])
        try Fixture.png(at: root.appendingPathComponent("favicon.png"), side: 32)
        await store.recheck(projectID: id, now: now.addingTimeInterval(1))
        #expect(store.icon(for: id)?.size.width == 32,
                "a stale walk timestamp kept the reused id from looking again")
    }
}

// MARK: - L1 / L3: the walk's boundaries

@Suite("Icon discovery boundaries")
struct IconDiscoveryBoundaryTests {

    /// L1. The recursive walk refused symlinks and the final file was checked,
    /// but the FIXED-path lookups (`public`, `Resources`, `assets`, …) went
    /// straight from the root to the leaf — so `public -> /elsewhere` read an
    /// icon from outside the folder the human linked.
    @Test("a symlinked intermediate directory yields no candidate")
    func symlinkedIntermediateDirectoryIsRefused() throws {
        let repo = try Fixture.root("repo")
        let outside = try Fixture.root("outside")
        defer { Fixture.remove(repo); Fixture.remove(outside) }
        // A perfectly good icon — but it lives OUTSIDE the repo.
        try Fixture.png(at: outside.appendingPathComponent("favicon.png"), side: 128)
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("public"), withDestinationURL: outside
        )

        let candidates = ProjectIconDiscovery.webCandidates(inRepoRoot: repo)
        #expect(candidates.isEmpty,
                "the walk read an icon through a symlink out of the repo")
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: repo).isEmpty)
    }

    /// The same boundary for the `.icns` lookup, whose fixed paths are the
    /// `Resources`/`Assets` pair.
    @Test("a symlinked Resources yields no icns candidate")
    func symlinkedResourcesIsRefused() throws {
        let repo = try Fixture.root("icns-repo")
        let outside = try Fixture.root("icns-outside")
        defer { Fixture.remove(repo); Fixture.remove(outside) }
        try Data(repeating: 0x41, count: 2_048)
            .write(to: outside.appendingPathComponent("App.icns"))
        try FileManager.default.createSymbolicLink(
            at: repo.appendingPathComponent("Resources"), withDestinationURL: outside
        )
        #expect(ProjectIconDiscovery.icnsCandidates(inRepoRoot: repo).isEmpty)
    }

    /// …and the same directory, NOT symlinked, still resolves — otherwise the
    /// test above would pass on a lookup that had simply stopped working.
    @Test("a real subdirectory of the repo still resolves")
    func realDirectoryStillResolves() throws {
        let repo = try Fixture.root("real")
        defer { Fixture.remove(repo) }
        try Fixture.png(at: repo.appendingPathComponent("public/favicon.png"), side: 64)
        let candidates = ProjectIconDiscovery.webCandidates(inRepoRoot: repo)
        #expect(candidates.count == 1)
        #expect(candidates.first?.url.lastPathComponent == "favicon.png")
    }

    @Test("unlinkedDirectory answers for the root itself and for a missing path")
    func unlinkedDirectoryEdges() throws {
        let repo = try Fixture.root("edges")
        defer { Fixture.remove(repo) }
        #expect(ProjectIconDiscovery.unlinkedDirectory("", inRepoRoot: repo) == repo)
        #expect(ProjectIconDiscovery.unlinkedDirectory("nope", inRepoRoot: repo) == nil)
        // A FILE where a directory was expected is not a directory.
        try Data("x".utf8).write(to: repo.appendingPathComponent("public"))
        #expect(ProjectIconDiscovery.unlinkedDirectory("public", inRepoRoot: repo) == nil)
    }

    /// L3. `contentsOfDirectory` built an array of every entry and only then let
    /// the cap apply, so the documented bound on work was not one. The bounded
    /// reader stops at the cap instead.
    @Test("the entry cap binds before the whole directory is read")
    func entryCapBindsEarly() throws {
        let repo = try Fixture.root("wide")
        defer { Fixture.remove(repo) }
        let wide = repo.appendingPathComponent("wide")
        try FileManager.default.createDirectory(at: wide, withIntermediateDirectories: true)
        let total = 3_000
        for index in 0..<total {
            try Data().write(to: wide.appendingPathComponent("f\(index).txt"))
        }

        let capped = ProjectIconDiscovery.boundedEntries(
            of: wide, keys: [.isDirectoryKey], limit: 25
        )
        #expect(capped.count == 25, "the reader must stop AT the cap, not after the directory")
        // Zero and negative budgets read nothing at all rather than everything.
        #expect(ProjectIconDiscovery.boundedEntries(of: wide, keys: [], limit: 0).isEmpty)
        #expect(ProjectIconDiscovery.boundedEntries(of: wide, keys: [], limit: -5).isEmpty)
        // A budget past the directory's size still returns the whole directory.
        #expect(ProjectIconDiscovery.boundedEntries(
            of: wide, keys: [], limit: total + 100).count == total)
        // And an unreadable path is an empty directory, never a throw.
        #expect(ProjectIconDiscovery.boundedEntries(
            of: repo.appendingPathComponent("gone"), keys: [], limit: 10).isEmpty)
    }

    /// The cap has to bind for the RECURSIVE walk too — that is where a
    /// half-million-entry directory would actually be met.
    @Test("the recursive walk honours a small entry budget on a wide directory")
    func recursiveWalkHonoursTheBudget() throws {
        let repo = try Fixture.root("wide-walk")
        defer { Fixture.remove(repo) }
        for index in 0..<2_000 {
            try Data().write(to: repo.appendingPathComponent("f\(index).txt"))
        }
        var limits = ProjectIconDiscovery.Limits.default
        limits.maxEntries = 10
        // The assertion that matters is that it RETURNS, bounded, with nothing
        // invented — the budget is spent on the flat files and no appiconset is
        // reachable within it.
        #expect(ProjectIconDiscovery.appIconSetDirectories(
            inRepoRoot: repo, limits: limits).isEmpty)
    }
}

// MARK: - L4: the header agrees with the picture

@Suite("Bus map header count")
struct BusMapHeaderCountTests {

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
    }

    private func link(_ a: UUID, _ b: UUID) -> ProjectLink {
        ProjectLink(a, b, createdAt: Date(timeIntervalSince1970: 0))
    }

    /// The finding: `A→B` and `B→A` are two ordinary rows (either end can be the
    /// one that linked), the map collapses them into ONE line, and the header
    /// counted two — the caption calling its own picture a liar.
    @Test("a reciprocal pair of link rows is ONE line and ONE link in the header")
    func reciprocalRowsCollapse() {
        let ids = ids(2)
        let rows = [link(ids[0], ids[1]), link(ids[1], ids[0])]
        let layout = BusMapLayout(projectIDs: ids, links: rows)
        let counted = BusMapSection.drawnLinkCount(projectIDs: ids, links: rows)
        #expect(layout.edges.count == 1)
        #expect(counted == layout.edges.count)
        #expect(counted != rows.count, "the old header counted the ROWS")
        #expect(BusMapSection.caption(projectCount: 2, linkCount: counted)
                == "2 projects \u{00B7} 1 link")
    }

    @Test("the collapsed count matches the drawn lines across messier inputs")
    func countMatchesDrawnLines() {
        let ids = ids(4)
        let rows = [
            link(ids[0], ids[1]), link(ids[1], ids[0]),      // reciprocal
            link(ids[1], ids[2]), link(ids[1], ids[2]),      // exact duplicate
            link(ids[2], ids[2]),                            // self-link
            link(ids[3], UUID()),                            // dangling end
        ]
        let layout = BusMapLayout(projectIDs: ids, links: rows)
        let counted = BusMapSection.drawnLinkCount(projectIDs: ids, links: rows)
        #expect(layout.edges.count == 2)
        #expect(counted == layout.edges.count)
        #expect(counted != rows.count)
    }
}

// MARK: - L5: somebody else's .gitignore

@Suite("Uninstall and the user's .gitignore")
struct GitignoreOwnershipTests {

    private static let ourURL = "http://127.0.0.1:51872/bus/\(String(repeating: "a", count: 32))"

    /// A repo that LOOKS like git (a `.git` directory), which is what gates the
    /// gitignore hygiene at all.
    private func repo(_ label: String) throws -> URL {
        let url = try Fixture.root("git-\(label)")
        try FileManager.default.createDirectory(
            at: url.appendingPathComponent(".git"), withIntermediateDirectories: true
        )
        return url
    }

    private var gitignoreName: String { RepoGitignore.fileName }

    @Test("a .gitignore Dispatch created is removed again on uninstall")
    func ourGitignoreGoes() async throws {
        let root = try repo("ours")
        defer { Fixture.remove(root) }
        let ignore = root.appendingPathComponent(gitignoreName)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        try await installer.install(repoPath: root.path, url: Self.ourURL)
        #expect(FileManager.default.fileExists(atPath: ignore.path),
                "install should have created the .gitignore in the first place")

        try await installer.uninstall(repoPath: root.path)
        #expect(!FileManager.default.fileExists(atPath: ignore.path))
    }

    /// THE finding. `adding(to: "")` produces byte-for-byte what it produces for
    /// `adding(to: nil)`, so uninstall could not tell our file from the empty one
    /// the user already had — and it unlinked the user's.
    @Test("a pre-existing ZERO-BYTE .gitignore survives uninstall")
    func preExistingEmptyGitignoreSurvives() async throws {
        let root = try repo("empty")
        defer { Fixture.remove(root) }
        let ignore = root.appendingPathComponent(gitignoreName)
        try Data().write(to: ignore)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        try await installer.install(repoPath: root.path, url: Self.ourURL)
        // We appended to it, so it is no longer empty…
        #expect(try Data(contentsOf: ignore).count > 0)

        try await installer.uninstall(repoPath: root.path)
        #expect(FileManager.default.fileExists(atPath: ignore.path),
                "Dispatch deleted a .gitignore it did not create")
        // …and what is left is empty again: OUR lines went, and there was
        // nothing else in there to keep.
        #expect(try Data(contentsOf: ignore).isEmpty)
    }

    @Test("a pre-existing .gitignore with the user's own rules keeps them")
    func preExistingRulesSurvive() async throws {
        let root = try repo("rules")
        defer { Fixture.remove(root) }
        let ignore = root.appendingPathComponent(gitignoreName)
        try Data("build/\n*.log\n".utf8).write(to: ignore)

        let installer = RepoMCPInstaller(ledger: .inMemory())
        try await installer.install(repoPath: root.path, url: Self.ourURL)
        try await installer.uninstall(repoPath: root.path)

        let text = try String(decoding: Data(contentsOf: ignore), as: UTF8.self)
        #expect(text.contains("build/"))
        #expect(text.contains("*.log"))
        #expect(!text.contains(RepoGitignore.marker))
    }

    /// Uninstall twice is uninstall once — the ledger record for the
    /// `.gitignore` is cleared with everything else.
    @Test("uninstalling twice is idempotent")
    func uninstallIsIdempotent() async throws {
        let root = try repo("twice")
        defer { Fixture.remove(root) }
        let installer = RepoMCPInstaller(ledger: .inMemory())
        try await installer.install(repoPath: root.path, url: Self.ourURL)
        try await installer.uninstall(repoPath: root.path)
        try await installer.uninstall(repoPath: root.path)
        #expect(!FileManager.default.fileExists(
            atPath: root.appendingPathComponent(gitignoreName).path))
    }
}

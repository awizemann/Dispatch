// GitPorcelainParserTests.swift
// Pure fixture tests for the porcelain-v2 parser and the rev-list stderr
// classifier — no subprocess, no git (the one real-git test lives in
// GitClientIntegrationTests).

import Foundation
import Testing
@testable import DispatchApp

@Suite("Git porcelain v2 parser (fixtures)")
struct GitPorcelainParserTests {

    @Test("Clean repo with upstream: headers only, ahead/behind parsed")
    func cleanWithUpstream() {
        let fixture = """
        # branch.oid 3cbfcbc19b1bbc4dfb2f4d2a9daeafc0e45d0f21
        # branch.head main
        # branch.upstream origin/main
        # branch.ab +3 -1
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.branchHead == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 3)
        #expect(status.behind == 1)
        #expect(status.isClean)
        #expect(status.dirtyCount == 0)
        #expect(!status.isDetached)
        #expect(!status.isUnborn)
    }

    @Test("Dirty repo: staged, unstaged (path with spaces), unmerged, untracked all count")
    func dirtyEntries() {
        let fixture = """
        # branch.oid 3cbfcbc19b1bbc4dfb2f4d2a9daeafc0e45d0f21
        # branch.head feature/list
        1 .M N... 100644 100644 100644 5266d1c85266d1c85266d1c85266d1c85266d1c8 5266d1c85266d1c85266d1c85266d1c85266d1c8 Sources/App/Main.swift
        1 M. N... 100644 100644 100644 aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb Sources/File With Spaces.swift
        u UU N... 100644 100644 100644 100644 a1a1a1a1 b2b2b2b2 c3c3c3c3 Sources/Conflicted.swift
        ? Untracked.swift
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.branchHead == "feature/list")
        #expect(status.upstream == nil)
        #expect(status.ahead == nil)
        #expect(!status.isClean)
        #expect(status.dirtyCount == 4)
        #expect(status.entries[0] == .init(kind: .changed, xy: ".M", path: "Sources/App/Main.swift"))
        #expect(status.entries[1].path == "Sources/File With Spaces.swift")
        #expect(status.entries[2].kind == .unmerged)
        #expect(status.entries[3] == .init(kind: .untracked, xy: nil, path: "Untracked.swift"))
    }

    @Test("Rename line carries both paths (tab-separated)")
    func renameEntry() {
        let fixture = """
        # branch.head main
        2 R. N... 100644 100644 100644 abc123abc123abc123abc123abc123abc123abc1 def456def456def456def456def456def456def4 R100 Sources/New Name.swift\tSources/Old.swift
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.dirtyCount == 1)
        let entry = status.entries[0]
        #expect(entry.kind == .renamedOrCopied)
        #expect(entry.xy == "R.")
        #expect(entry.path == "Sources/New Name.swift")
        #expect(entry.originalPath == "Sources/Old.swift")
    }

    @Test("Ignored entries are parsed but do not count as dirty")
    func ignoredIsNotDirty() {
        let fixture = """
        # branch.head main
        ! build/
        ! .DS_Store
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.entries.count == 2)
        #expect(status.entries.allSatisfy { $0.kind == .ignored })
        #expect(status.isClean)
        #expect(status.dirtyCount == 0)
    }

    @Test("Detached HEAD header")
    func detachedHead() {
        let fixture = """
        # branch.oid 3cbfcbc19b1bbc4dfb2f4d2a9daeafc0e45d0f21
        # branch.head (detached)
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.isDetached)
        #expect(status.upstream == nil)
    }

    @Test("Unborn branch (fresh init, no commits)")
    func unbornBranch() {
        let fixture = """
        # branch.oid (initial)
        # branch.head main
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.isUnborn)
        #expect(status.branchHead == "main")
        #expect(!status.isDetached)
    }

    @Test("Unknown line kinds and malformed known lines are skipped, not crashed on")
    func unknownAndMalformedLines() {
        let fixture = """
        # stash 2
        # branch.head main
        z something-from-the-future
        1 .M N...
        """
        let status = GitPorcelainParser.parse(fixture)

        #expect(status.branchHead == "main")
        #expect(status.entries.isEmpty)
    }

    @Test("Empty output parses to a clean, header-less status")
    func emptyOutput() {
        let status = GitPorcelainParser.parse("")
        #expect(status.isClean)
        #expect(status.branchHead == nil)
    }
}

@Suite("rev-list failure classification (unpushed edge cases)")
struct RevListClassificationTests {

    @Test("No upstream configured → .noUpstream")
    func noUpstreamConfigured() {
        let stderr = "fatal: no upstream configured for branch 'main'"
        #expect(GitClient.classifyRevListFailure(stderr: stderr) == .noUpstream)
    }

    @Test("Deleted upstream ref (unknown revision) → .noUpstream")
    func unknownRevision() {
        let stderr = """
        fatal: ambiguous argument '@{upstream}..HEAD': unknown revision or path not in the working tree.
        Use '--' to separate paths from revisions, like this:
        'git <command> [<revision>...] -- [<file>...]'
        """
        #expect(GitClient.classifyRevListFailure(stderr: stderr) == .noUpstream)
    }

    @Test("Detached HEAD → .detached")
    func detachedHead() {
        let stderr = "fatal: HEAD does not point to a branch"
        #expect(GitClient.classifyRevListFailure(stderr: stderr) == .detached)
    }

    @Test("Anything else is not classified (escalates as execFailed)")
    func unclassified() {
        #expect(GitClient.classifyRevListFailure(stderr: "fatal: bad object HEAD") == nil)
        #expect(GitClient.classifyRevListFailure(stderr: "") == nil)
    }
}

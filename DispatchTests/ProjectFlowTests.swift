// ProjectFlowTests.swift
// ProjectStore's add/rename/remove + git-refresh paths over the mock actors —
// the same writers/seams AppStores.live() wires over GlobalDatabase.

import Foundation
import Testing
@testable import DispatchApp

@Suite("Project flow (add / edit / remove / refresh)")
struct ProjectFlowTests {

    private func makeStore(
        global: MockGlobalPersistence,
        git: MockGitStatus = MockGitStatus()
    ) -> ProjectStore {
        ProjectStore(
            reader: global,
            writers: global.projectWriters(),
            git: git,
            gitRefreshInterval: nil
        )
    }

    private func makeProject(
        name: String,
        path: String,
        git: GitStatus? = nil,
        lastOpenedAt: Date? = nil
    ) -> Project {
        Project(id: UUID(), name: name, repoPath: path,
                pinned: false, git: git, lastOpenedAt: lastOpenedAt)
    }

    // MARK: - Add

    @Test("Add persists the project + bookmark, selects it, and runs the first git scan")
    func addProjectFullFlow() async throws {
        let global = MockGlobalPersistence(projects: [])
        let git = MockGitStatus(defaultSnapshot: GitSnapshot(
            branch: .branch("main"), isClean: true, dirtyCount: 0, unpushed: .noUpstream
        ))
        let store = makeStore(global: global, git: git)
        await store.activate()

        // Bookmark creation requires a real, existing folder.
        let folder = FileManager.default.temporaryDirectory
        try await store.addProject(name: "Scratch", folderURL: folder)

        #expect(try await pollUntil { store.projects.count == 1 },
                "added project never arrived through observation")
        let added = try #require(store.projects.first)
        #expect(added.name == "Scratch")
        #expect(added.repoPath == folder.standardizedFileURL.path)
        #expect(store.selectedProjectID == added.id)
        // A successful add dismisses the modal.
        #expect(store.modalRoute == nil)
        let bookmark = await global.repoBookmark(projectID: added.id)
        #expect(bookmark != nil)
        // First scan lands asynchronously and fills the cache columns
        // (PR/tickets 0-placeholders until Phase 4).
        #expect(try await pollUntil {
            store.project(id: added.id)?.git == GitStatus(
                openPRs: 0, openTickets: 0, unpushedCommits: 0, branch: "main"
            )
        }, "first git scan never updated the cache")
    }

    @Test("A failed bookmark write rolls the project row back")
    func addRollsBackWithoutBookmark() async throws {
        let global = MockGlobalPersistence(projects: [])
        var writers = global.projectWriters()
        writers.saveBookmark = { _, _ in
            throw CocoaError(.fileWriteUnknown)
        }
        let store = ProjectStore(
            reader: global, writers: writers,
            git: MockGitStatus(), gitRefreshInterval: nil
        )
        await store.activate()

        await #expect(throws: (any Error).self) {
            try await store.addProject(
                name: "Scratch",
                folderURL: FileManager.default.temporaryDirectory
            )
        }
        let persisted = try await global.fetchProjects()
        #expect(persisted.isEmpty, "rollback left an orphaned project row")
    }

    // MARK: - Rename / remove

    @Test("Rename keeps the path and round-trips through observation")
    func renameProject() async throws {
        let project = makeProject(name: "Old", path: "/repos/Old")
        let global = MockGlobalPersistence(projects: [project])
        let store = makeStore(global: global)
        await store.activate()

        try await store.renameProject(id: project.id, name: "New")

        #expect(try await pollUntil { store.project(id: project.id)?.name == "New" },
                "rename never came back through observation")
        #expect(store.project(id: project.id)?.repoPath == "/repos/Old")
    }

    @Test("Delete drops the project and moves the selection")
    func deleteProjectMovesSelection() async throws {
        let doomed = makeProject(name: "Doomed", path: "/repos/Doomed")
        let survivor = makeProject(name: "Survivor", path: "/repos/Survivor")
        let global = MockGlobalPersistence(projects: [doomed, survivor])
        let store = makeStore(global: global)
        await store.activate()
        store.select(doomed.id)

        try await store.deleteProject(id: doomed.id)

        #expect(store.selectedProjectID == survivor.id)
        #expect(try await pollUntil { store.projects.count == 1 },
                "deletion never came back through observation")
    }

    @Test("Deleting the last project falls back to the empty state")
    func deleteLastProjectClearsSelection() async throws {
        let only = makeProject(name: "Solo", path: "/repos/Solo")
        let global = MockGlobalPersistence(projects: [only])
        let store = makeStore(global: global)
        await store.activate()
        store.select(only.id)

        try await store.deleteProject(id: only.id)

        #expect(store.selectedProjectID == nil, "empty-state selection wasn't cleared")
        #expect(try await pollUntil { store.projects.isEmpty },
                "last project never left the list")
    }

    @Test("Deleting an unselected project leaves the selection put")
    func deleteUnselectedKeepsSelection() async throws {
        let selected = makeProject(name: "Keep", path: "/repos/Keep")
        let doomed = makeProject(name: "Drop", path: "/repos/Drop")
        let global = MockGlobalPersistence(projects: [selected, doomed])
        let store = makeStore(global: global)
        await store.activate()
        store.select(selected.id)

        try await store.deleteProject(id: doomed.id)

        #expect(store.selectedProjectID == selected.id, "selection moved off an unrelated delete")
    }

    @Test("Delete clears the stale-folder flag and any open modal route")
    func deleteClearsStaleFlagAndModal() async throws {
        let doomed = makeProject(name: "Ghosted", path: "/repos/Ghosted")
        let git = MockGitStatus()
        let global = MockGlobalPersistence(projects: [doomed])
        let store = makeStore(global: global, git: git)
        await store.activate()
        // Flag it stale (as a vanished-folder refresh would) and open a modal.
        await git.setError(.notARepository(path: "/repos/Ghosted"))
        await store.refreshGitStatus(projectID: doomed.id)
        #expect(store.staleFolderIDs.contains(doomed.id))
        store.modalRoute = .edit(doomed)

        try await store.deleteProject(id: doomed.id)

        #expect(!store.staleFolderIDs.contains(doomed.id))
        #expect(store.modalRoute == nil, "delete left a stale modal route up")
    }

    // MARK: - Selection persistence

    @Test("Activation restores the most recently opened project")
    func selectionRestoresByLastOpened() async throws {
        let older = makeProject(name: "Older", path: "/repos/Older",
                                lastOpenedAt: Fixtures.date())
        let newer = makeProject(name: "Newer", path: "/repos/Newer",
                                lastOpenedAt: Fixtures.date(offset: 60))
        let global = MockGlobalPersistence(projects: [older, newer])
        let store = makeStore(global: global)

        await store.activate()

        #expect(store.selectedProjectID == newer.id)
    }

    @Test("Selecting a project persists lastOpenedAt")
    func selectPersistsLastOpened() async throws {
        let a = makeProject(name: "A", path: "/repos/A", lastOpenedAt: Fixtures.date())
        let b = makeProject(name: "B", path: "/repos/B")
        let global = MockGlobalPersistence(projects: [a, b])
        let store = makeStore(global: global)
        await store.activate()
        #expect(store.selectedProjectID == a.id)

        store.select(b.id)

        #expect(store.selectedProjectID == b.id)
        #expect(try await pollUntil { store.project(id: b.id)?.lastOpenedAt != nil },
                "lastOpenedAt write never landed")
    }

    // MARK: - Git refresh

    @Test("Refresh merges: branch/unpushed from git, PR/tickets preserved (Phase-4 seam)")
    func refreshMergesGitSnapshot() async throws {
        let project = makeProject(
            name: "Ledgerline", path: "/repos/Ledgerline",
            git: GitStatus(openPRs: 2, openTickets: 5, unpushedCommits: 3, branch: "main")
        )
        let git = MockGitStatus(snapshots: [
            "/repos/Ledgerline": GitSnapshot(
                branch: .branch("feature/x"), isClean: false, dirtyCount: 2, unpushed: .count(1)
            )
        ])
        let global = MockGlobalPersistence(projects: [project])
        let store = makeStore(global: global, git: git)
        await store.activate()

        await store.refreshGitStatus(projectID: project.id)

        #expect(try await pollUntil {
            store.project(id: project.id)?.git == GitStatus(
                openPRs: 2, openTickets: 5, unpushedCommits: 1, branch: "feature/x"
            )
        }, "refresh never overwrote the cache")
        #expect(!store.staleFolderIDs.contains(project.id))
    }

    @Test("A vanished repo folder flags the amber note; a later success clears it")
    func staleFolderFlagging() async throws {
        let project = makeProject(name: "Ghost", path: "/repos/Ghost")
        let git = MockGitStatus()
        let global = MockGlobalPersistence(projects: [project])
        let store = makeStore(global: global, git: git)
        await store.activate()

        await git.setError(.notARepository(path: "/repos/Ghost"))
        await store.refreshGitStatus(projectID: project.id)
        #expect(store.staleFolderIDs.contains(project.id))

        await git.setError(nil)
        await store.refreshGitStatus(projectID: project.id)
        #expect(!store.staleFolderIDs.contains(project.id))
    }
}

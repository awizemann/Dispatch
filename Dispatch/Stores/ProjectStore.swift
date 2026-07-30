// ProjectStore.swift
// The store for the projects rail: registry, selection (persisted via
// lastOpenedAt), pin/unpin, add/rename/remove, and the git refresh path.
//
// Reads go through GlobalPersistenceReading (mock actor or GlobalDatabase);
// writes are injected as the ProjectWriters closure bundle because the write
// surface has no protocol seam yet (persistence scope decision 2026-07-05).
// Git status arrives through the GitStatusProviding seam (GitClient live,
// MockGitStatus in the mock composition / tests).
//
// Skeleton-row principle: the DB's cached git columns paint instantly via
// observeProjects; every refresh overwrites the cache, and the same
// observation delivers the fresh row.

import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "stores")

// MARK: - Injected write surface

/// Write closures over the concrete persistence actors (no protocol seam for
/// writes yet). Non-throwing entries log internally; throwing entries surface
/// to UI (add/rename/remove ride user gestures).
nonisolated struct ProjectWriters: Sendable {
    var saveProject: @Sendable (Project) async throws -> Void
    /// Deletes ONLY the registry row (+ its bookmark column). Used by the
    /// add-project rollback path — a bookmark write that fails there has left
    /// nothing else behind, so unwinding the row is the whole job.
    var deleteProject: @Sendable (UUID) async throws -> Void
    /// FULL destructive deletion: removes the repo's `dispatch`
    /// entry, sweeps any legacy per-project DB file, releases the bookmark,
    /// and drops the registry row — in that order, registry LAST
    /// (ProjectDeletion). NEVER touches the user's code. The store passes the
    /// repo path so the `.mcp.json` entry can be found. nil in the mock
    /// composition → the store falls back to `deleteProject`
    /// (registry row only).
    var deleteProjectFully: (@Sendable (_ projectID: UUID, _ repoPath: String) async throws -> Void)?
    var setPinned: @Sendable (UUID, Bool) async -> Void
    /// The session-hooks opt-in. Defaulted to a no-op so the mock
    /// composition and the store tests keep their existing construction — a
    /// composition that does not persist it simply keeps the in-memory flip.
    var setSessionHooks: @Sendable (UUID, Bool) async -> Void = { _, _ in }
    var saveBookmark: @Sendable (UUID, Data) async throws -> Void
    var loadBookmark: @Sendable (UUID) async throws -> Data?
    var updateGitCache: @Sendable (UUID, GitStatus) async throws -> Void
    var updateLastOpened: @Sendable (UUID, Date) async -> Void
}

// MARK: - Modal routing

/// Which project modal is up (design §9). Owned here because the modal is the
/// projects domain's UI; WorkbenchView hosts the scrim.
nonisolated enum ProjectModalRoute: Equatable {
    case add
    case edit(Project)
}

// MARK: - Store

@MainActor
@Observable
final class ProjectStore {

    private let reader: any GlobalPersistenceReading
    private let writers: ProjectWriters
    /// Exposed so the project modal's form model can validate folders through
    /// the same seam (real GitClient in the live composition).
    let git: any GitStatusProviding
    /// nil = no periodic refresh (mock composition, tests).
    private let gitRefreshInterval: Duration?

    private var observation: Task<Void, Never>?
    @ObservationIgnored private var refreshLoop: Task<Void, Never>?
    @ObservationIgnored private var refreshesInFlight: Set<UUID> = []

    private(set) var projects: [Project] = []

    /// Selection by id; views resolve rows from the UNFILTERED `projects`
    /// (view-discipline convention). Every real change (select, launch
    /// restore, add, remove) notifies onSelectionChange — the live composition
    /// drives the agent-session lifecycle off it.
    var selectedProjectID: UUID? {
        didSet {
            guard oldValue != selectedProjectID else { return }
            onSelectionChange?(selectedProjectID)
        }
    }

    /// Live-composition hook, wired by AppStores; nil in mocks/tests.
    @ObservationIgnored var onSelectionChange: (@MainActor (UUID?) -> Void)?

    /// Fires on EVERY change to the registry — the initial load and every
    /// observation delivery after it (add, rename, delete, pin). The composition
    /// root keeps the bus router's id → name map on this, because a router whose
    /// name map was set once at launch cannot resolve a project added later and
    /// still resolves one that was renamed away (audit S1).
    @ObservationIgnored var onProjectsChanged: (@MainActor ([Project]) -> Void)?

    /// The add/edit modal route (WorkbenchView presents it).
    var modalRoute: ProjectModalRoute?

    /// The project pending DELETE confirmation, set by the card's
    /// "Delete project…" context-menu action. Non-nil raises the name-typing
    /// confirmation dialog (DeleteProjectPresenter). This is the FIRST of the
    /// double confirmation — the context menu is step one, this dialog (which
    /// demands the exact project name) is step two.
    var deletionRoute: Project?

    /// Projects whose repo folder failed to resolve on the last refresh —
    /// the card shows the amber "folder missing" note.
    private(set) var staleFolderIDs: Set<UUID> = []

    init(
        reader: any GlobalPersistenceReading,
        writers: ProjectWriters,
        git: any GitStatusProviding,
        gitRefreshInterval: Duration? = .seconds(60)
    ) {
        self.reader = reader
        self.writers = writers
        self.git = git
        self.gitRefreshInterval = gitRefreshInterval
    }

    var pinnedProjects: [Project] { projects.filter(\.pinned) }
    var unpinnedProjects: [Project] { projects.filter { !$0.pinned } }

    func project(id: UUID) -> Project? {
        projects.first { $0.id == id }
    }

    // MARK: - Activation

    /// Initial fetch (so first paint has data), then long-lived observation.
    /// Selection restores to the most recently opened project (persisted
    /// lastOpenedAt), falling back to first-pinned / first.
    func activate() async {
        projects = await safeRead("fetchProjects", fallback: []) { try await reader.fetchProjects() }
        onProjectsChanged?(projects)
        if selectedProjectID == nil {
            let lastOpened = projects
                .filter { $0.lastOpenedAt != nil }
                .max { ($0.lastOpenedAt ?? .distantPast) < ($1.lastOpenedAt ?? .distantPast) }
            selectedProjectID = lastOpened?.id ?? pinnedProjects.first?.id ?? projects.first?.id
        }
        observation?.cancel()
        observation = Task { [reader] in
            let stream = await reader.observeProjects()
            do {
                for try await updated in stream {
                    self.projects = updated
                    self.onProjectsChanged?(updated)
                }
            } catch {
                logger.error("project observation stream failed: \(String(describing: error), privacy: .public)")
            }
        }
        startGitRefreshLoop()
    }

    // MARK: - Selection

    /// Select + persist (lastOpenedAt drives selection restore across launches).
    func select(_ id: UUID) {
        guard selectedProjectID != id else { return }
        selectedProjectID = id
        let writers = writers
        Task { await writers.updateLastOpened(id, .now) }
    }

    // MARK: - Pin

    func togglePin(id: UUID) {
        guard let project = project(id: id) else { return }
        let writers = writers
        Task { await writers.setPinned(id, !project.pinned) }
    }

    // MARK: - Session hooks opt-in

    /// Records the human's opt-in for the repo's session hooks. The row is
    /// flipped in memory FIRST so the toggle answers the click even in a
    /// composition with no live observation (mock/tests); the durable write
    /// follows and the observation re-delivers the same value.
    func setSessionHooks(_ enabled: Bool, for projectID: UUID) async {
        if let index = projects.firstIndex(where: { $0.id == projectID }) {
            projects[index].sessionHooksEnabled = enabled
        }
        await writers.setSessionHooks(projectID, enabled)
    }

    // MARK: - Add / rename / remove

    /// Persists a new project for an already-validated folder (the modal's
    /// form model owns validation). Creates the bookmark at pick time, rolls
    /// the registry row back if the bookmark write fails, selects the new
    /// project, and kicks the first git scan. Returns the new project's id so
    /// the caller can flush any drafted MCP approvals into its now-existing DB
    /// (Part 1) — an id comes back ONLY on success, so approvals can
    /// never land for a project whose creation threw.
    @discardableResult
    func addProject(name: String, folderURL: URL) async throws -> UUID {
        let bookmark = try RepoBookmark.create(for: folderURL)
        let project = Project(
            id: UUID(),
            name: name,
            repoPath: folderURL.standardizedFileURL.path,
            pinned: false,
            git: nil,               // skeleton row until the first scan lands
            lastOpenedAt: .now
        )
        try await writers.saveProject(project)
        do {
            try await writers.saveBookmark(project.id, bookmark)
        } catch {
            logger.error("bookmark write failed; rolling back project add: \(String(describing: error), privacy: .public)")
            do {
                try await writers.deleteProject(project.id)
            } catch {
                logger.warning("project-add rollback delete failed; orphan row may remain: \(error)")
            }
            throw error
        }
        selectedProjectID = project.id
        modalRoute = nil
        Task { await self.refresh(project) }
        return project.id
    }

    /// Edit = rename only; the repo path is immutable by design.
    func renameProject(id: UUID, name: String) async throws {
        guard var project = project(id: id) else { return }
        project.name = name
        try await writers.saveProject(project)  // bookmark preserved downstream
        modalRoute = nil
    }

    /// DESTRUCTIVE delete, reached from the project card's context
    /// menu behind a name-typing confirmation. Removes ONLY Dispatch's own
    /// state — the repo's `dispatch` .mcp.json entry, this project's bus
    /// identity, links and messages, and the registry row — NEVER the user's
    /// code. The full orchestration (ProjectDeletion) runs registry-LAST in the
    /// live composition; the mock composition falls back to the
    /// registry-row-only writer.
    ///
    /// Selection moves off the deleted project FIRST — to another project or
    /// the empty state. If the delete throws, the row is still listed; the user
    /// can retry (deletion is idempotent).
    func deleteProject(id: UUID) async throws {
        guard let project = project(id: id) else { return }
        if selectedProjectID == id {
            selectedProjectID = projects.first { $0.id != id }?.id
        }
        staleFolderIDs.remove(id)
        modalRoute = nil
        if let deleteFully = writers.deleteProjectFully {
            try await deleteFully(id, project.repoPath)
        } else {
            try await writers.deleteProject(id)
        }
    }

    // MARK: - Git refresh

    /// On-demand refresh of every project (launch, app-became-active).
    func refreshAllGitStatus() async {
        for project in projects {
            await refresh(project)
        }
    }

    func refreshGitStatus(projectID: UUID) async {
        guard let project = project(id: projectID) else { return }
        await refresh(project)
    }

    private func startGitRefreshLoop() {
        guard let interval = gitRefreshInterval else { return }
        refreshLoop?.cancel()
        refreshLoop = Task {
            await self.refreshAllGitStatus()
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: interval)
                } catch { return }
                await self.refreshAllGitStatus()
            }
        }
    }

    /// One project's refresh: resolve the bookmark (re-creating it when the
    /// system reports it stale), run the git snapshot, merge into the cached
    /// GitStatus (openPRs/openTickets are preserved as-is), and overwrite the
    /// DB cache. The projects
    /// observation repaints the row.
    private func refresh(_ project: Project) async {
        guard refreshesInFlight.insert(project.id).inserted else { return }
        defer { refreshesInFlight.remove(project.id) }

        let url = await resolveRepoURL(for: project)
        let access = RepoBookmark.beginAccess(url)
        defer { access.end() }

        do {
            let snapshot = try await git.snapshot(at: url.path)
            let merged = GitStatus(
                openPRs: project.git?.openPRs ?? 0,
                openTickets: project.git?.openTickets ?? 0,
                unpushedCommits: snapshot.unpushed.displayCount,
                branch: snapshot.branch.displayName
            )
            staleFolderIDs.remove(project.id)
            try await writers.updateGitCache(project.id, merged)
        } catch let error as GitError {
            switch error {
            case .notARepository, .execFailed:
                // Folder gone/moved or not a work tree anymore → amber note.
                staleFolderIDs.insert(project.id)
            case .timeout, .gitBinaryNotFound:
                break // transient/environmental — keep the cached row as-is
            case .pathNotWhitelisted:
                break // commit-gate taxonomy; unreachable from a status read
            }
            logger.warning("git refresh failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
        } catch {
            logger.warning("git refresh failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    /// The repo folder for a project, resolved the SAME way the git refresh
    /// resolves it (bookmark first, stored path as the fallback) — nil when the
    /// project is gone from the registry or its folder no longer resolves to a
    /// directory. Icon discovery reads it; every other caller here already had
    /// a Project in hand.
    ///
    /// This is a read-only probe for a cosmetic decision, not a check-then-act
    /// gate on a write, so asking whether the directory is there is the right
    /// shape: the alternative is walking a path that isn't.
    func existingRepoURL(projectID: UUID) async -> URL? {
        guard let project = project(id: projectID) else { return nil }
        let url = await resolveRepoURL(for: project)
        let access = RepoBookmark.beginAccess(url)
        defer { access.end() }
        guard let values = try? url.resourceValues(forKeys: [.isDirectoryKey]),
              values.isDirectory == true
        else { return nil }
        return url
    }

    /// Bookmark-first path resolution with stale re-creation; falls back to
    /// the stored repoPath string when there is no (usable) bookmark.
    private func resolveRepoURL(for project: Project) async -> URL {
        do {
            guard let data = try await writers.loadBookmark(project.id) else {
                return URL(fileURLWithPath: project.repoPath)
            }
            let resolved = try RepoBookmark.resolve(data)
            if resolved.isStale {
                do {
                    let fresh = try RepoBookmark.create(for: resolved.url)
                    try await writers.saveBookmark(project.id, fresh)
                    logger.info("refreshed stale bookmark for \(project.name, privacy: .public)")
                } catch {
                    logger.warning("stale bookmark re-create failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
                }
            }
            return resolved.url
        } catch {
            logger.warning("bookmark resolve failed for \(project.name, privacy: .public); using stored path: \(String(describing: error), privacy: .public)")
            return URL(fileURLWithPath: project.repoPath)
        }
    }
}

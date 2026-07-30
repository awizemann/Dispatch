// MockGlobalPersistence.swift
// Actor fake for GlobalPersistenceReading — feeds the store shells with scripted
// data so the shell UI is real while the data is not. Swapped for GlobalDatabase
// in AppStores with zero UI change (the protocol seam is the contract).
//
// Also carries the few MOCK-ONLY writes the shell needs (pin/unpin); real writes
// go through the concrete persistence actors in later phases.

import Foundation

actor MockGlobalPersistence: GlobalPersistenceReading {

    private var projects: [Project]
    private var projectLinks: [ProjectLink]
    private var busMessages: [BusMessage]
    private var bookmarks: [UUID: Data] = [:]

    private var projectsBroadcast = MockBroadcast<[Project]>()
    private var linksBroadcast = MockBroadcast<[ProjectLink]>()
    private var busBroadcast = MockBroadcast<[BusMessage]>()

    init(
        projects: [Project],
        projectLinks: [ProjectLink] = [],
        busMessages: [BusMessage] = []
    ) {
        // Newest first, mirroring GlobalDatabase's ordered fetch/observe.
        self.busMessages = busMessages.sorted { $0.askedAt > $1.askedAt }
        self.projectLinks = projectLinks.sorted { $0.createdAt < $1.createdAt }
        self.projects = projects
    }

    // MARK: - GlobalPersistenceReading

    func fetchProjects() async throws -> [Project] { projects }
    func fetchProjectLinks() async throws -> [ProjectLink] { projectLinks }
    func fetchBusMessages() async throws -> [BusMessage] { busMessages }

    func observeBusMessages() -> AsyncThrowingStream<[BusMessage], Error> {
        busBroadcast.subscribe(initial: busMessages)
    }

    /// Mock-only: the human-arbitration write, mirroring
    /// GlobalDatabase.recordBusAnswer's pending-only guard so the mock scenario
    /// exercises the same flip (and the same refusal) as the live path.
    @discardableResult
    func answerBusMessage(id: String, text: String, byHuman: Bool) -> Bool {
        guard let index = busMessages.firstIndex(where: { $0.id == id }),
              busMessages[index].status == .pending else { return false }
        busMessages[index].status = .answered
        busMessages[index].answer = text
        busMessages[index].answeredByHuman = byHuman
        busMessages[index].answeredAt = .now
        busBroadcast.yield(busMessages)
        return true
    }

    /// Mock-only: one message by id (the scripted long poll reads back the row
    /// it just answered, the way the router re-reads rather than trusting a
    /// wake-up).
    func busMessage(id: String) -> BusMessage? {
        busMessages.first { $0.id == id }
    }

    /// Mock-only: the human's "close the thread" write, mirroring
    /// GlobalDatabase.closeBusMessage's pending-only guard — a question that
    /// already settled refuses here too.
    @discardableResult
    func closeBusMessage(id: String, reason: String) -> BusMessage? {
        guard let index = busMessages.firstIndex(where: { $0.id == id }),
              busMessages[index].status == .pending else { return nil }
        busMessages[index].status = .closed
        busMessages[index].closedReason = reason
        busBroadcast.yield(busMessages)
        return busMessages[index]
    }

    func observeProjectLinks() -> AsyncThrowingStream<[ProjectLink], Error> {
        linksBroadcast.subscribe(initial: projectLinks)
    }

    func observeProjects() -> AsyncThrowingStream<[Project], Error> {
        projectsBroadcast.subscribe(initial: projects)
    }

    // MARK: - Mock-only writes

    /// Pin/Unpin from the project card's context menu (functional on mock data).
    func setPinned(projectID: UUID, pinned: Bool) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].pinned = pinned
        projectsBroadcast.yield(projects)
    }

    /// Upsert mirroring GlobalDatabase.saveProject (bookmarks live separately).
    func saveProject(_ project: Project) {
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        } else {
            projects.append(project)
        }
        projectsBroadcast.yield(projects)
    }

    func deleteProject(id: UUID) {
        projects.removeAll { $0.id == id }
        bookmarks[id] = nil
        // P1-residual prune: a deleted project takes its links with
        // it, mirroring the live deletion path — no orphan pairs survive.
        deleteProjectLinks(involving: id)
        projectsBroadcast.yield(projects)
    }

    // MARK: - Cross-project links (mock writes)

    /// Upsert mirroring GlobalDatabase.saveProjectLink: a self-pair is rejected;
    /// an already-linked UNORDERED pair is idempotent (the canonicalized ends
    /// compare equal), so the settings picker excluding linked peers is belt-and-
    /// suspenders over this.
    func saveProjectLink(_ link: ProjectLink) {
        guard link.projectA != link.projectB else { return }
        guard !projectLinks.contains(where: { $0.connects(link.projectA, link.projectB) }) else { return }
        projectLinks.append(link)
        projectLinks.sort { $0.createdAt < $1.createdAt }
        linksBroadcast.yield(projectLinks)
    }

    /// Removes the link between two projects in EITHER order (mirrors
    /// GlobalDatabase.deleteProjectLink(between:and:)).
    func deleteProjectLink(between first: UUID, and second: UUID) {
        projectLinks.removeAll { $0.connects(first, second) }
        linksBroadcast.yield(projectLinks)
    }

    /// Prunes every link touching `projectID` (mirrors deleteProjectLinks(involving:)).
    func deleteProjectLinks(involving projectID: UUID) {
        projectLinks.removeAll { $0.peer(of: projectID) != nil }
        linksBroadcast.yield(projectLinks)
    }

    /// The CrossProjectLinkWriters bundle over this mock — the same wiring shape
    /// AppStores.live() builds over GlobalDatabase (tests + mock composition).
    nonisolated func linkWriters() -> CrossProjectLinkWriters {
        CrossProjectLinkWriters(
            addLink: { await self.saveProjectLink(ProjectLink($0, $1)) },
            removeLink: { await self.deleteProjectLink(between: $0, and: $1) }
        )
    }

    func updateGitStatusCache(projectID: UUID, git: GitStatus) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].git = git
        projectsBroadcast.yield(projects)
    }

    func updateLastOpenedAt(projectID: UUID, date: Date) {
        guard let index = projects.firstIndex(where: { $0.id == projectID }) else { return }
        projects[index].lastOpenedAt = date
        projectsBroadcast.yield(projects)
    }

    func saveRepoBookmark(projectID: UUID, bookmark: Data) {
        bookmarks[projectID] = bookmark
    }

    func repoBookmark(projectID: UUID) -> Data? {
        bookmarks[projectID]
    }

    /// The full ProjectWriters bundle over this mock — the same wiring shape
    /// AppStores.live() builds over GlobalDatabase (tests + mock composition).
    nonisolated func projectWriters() -> ProjectWriters {
        ProjectWriters(
            saveProject: { await self.saveProject($0) },
            deleteProject: { await self.deleteProject(id: $0) },
            // No destructive-deletion orchestration in the mock composition —
            // nil makes ProjectStore.deleteProject fall back to the
            // registry-row-only `deleteProject` above.
            deleteProjectFully: nil,
            setPinned: { await self.setPinned(projectID: $0, pinned: $1) },
            saveBookmark: { await self.saveRepoBookmark(projectID: $0, bookmark: $1) },
            loadBookmark: { await self.repoBookmark(projectID: $0) },
            updateGitCache: { await self.updateGitStatusCache(projectID: $0, git: $1) },
            updateLastOpened: { await self.updateLastOpenedAt(projectID: $0, date: $1) }
        )
    }
}

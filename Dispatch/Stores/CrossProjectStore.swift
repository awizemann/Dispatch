// CrossProjectStore.swift
// The read/observe surface for cross-project LINKS — the `projectLink` table
// (one global reader + observe). Feeds the project-settings links section; link
// add/remove routes through CrossProjectLinkWriters (the store never touches
// persistence directly).
//
// P3 removed the per-project request mirror this store also carried: the
// pre-Dispatch cross-project WORK REQUEST is gone, and the questions that
// replaced it live in the one global bus table behind MessageStore. What is
// left is exactly the consent model — who may talk to whom.

import Foundation
import os

private let logger = Logger(subsystem: "com.wizemann.dispatch", category: "cross-project")

/// Link mutation seam. `addLink` canonicalizes + persists the pair;
/// `removeLink` deletes it in either order. Live composition binds these to
/// GlobalDatabase.saveProjectLink / deleteProjectLink(between:and:); mocks bind
/// them to MockGlobalPersistence. Defaults no-op so a composition without link
/// editing (previews that only read) still constructs.
nonisolated struct CrossProjectLinkWriters: Sendable {
    var addLink: @Sendable (_ a: UUID, _ b: UUID) async -> Void
    var removeLink: @Sendable (_ a: UUID, _ b: UUID) async -> Void

    init(
        addLink: @escaping @Sendable (UUID, UUID) async -> Void = { _, _ in },
        removeLink: @escaping @Sendable (UUID, UUID) async -> Void = { _, _ in }
    ) {
        self.addLink = addLink
        self.removeLink = removeLink
    }
}

@MainActor
@Observable
final class CrossProjectStore {

    /// The global read seam behind the links mirror. nil in a fixture-only
    /// composition (no link observation runs).
    @ObservationIgnored private let global: (any GlobalPersistenceReading)?
    @ObservationIgnored private let writers: CrossProjectLinkWriters
    private var linkObservation: Task<Void, Never>?
    private var activated = false

    /// Every global link, createdAt order — the settings section's list source.
    private(set) var links: [ProjectLink] = []

    init(
        global: (any GlobalPersistenceReading)? = nil,
        writers: CrossProjectLinkWriters = CrossProjectLinkWriters(),
        links: [ProjectLink] = []
    ) {
        self.global = global
        self.writers = writers
        self.links = links
    }

    // MARK: - Reads (links / settings)

    /// Links that include `projectID` on either end.
    func links(involving projectID: UUID) -> [ProjectLink] {
        links.filter { $0.peer(of: projectID) != nil }
    }

    /// The peer project ids `projectID` is linked to.
    func linkedPeerIDs(of projectID: UUID) -> Set<UUID> {
        Set(links.compactMap { $0.peer(of: projectID) })
    }

    /// Removal-warn signal: are there questions still IN FLIGHT between
    /// `projectID` and `peerID` (either direction)? Unlinking is allowed
    /// regardless — this drives the WARN copy, never a block. Pure over a
    /// message set so it is unit-testable without a store.
    nonisolated static func hasInFlightQuestions(
        with peerID: UUID, in projectID: UUID, messages: [BusMessage]
    ) -> Bool {
        messages.contains { message in
            message.status == .pending
                && ((message.from == projectID && message.to == peerID)
                    || (message.from == peerID && message.to == projectID))
        }
    }

    // MARK: - Link mutations (settings section)

    /// Link `projectID` to `peerID` (canonicalized + persisted through the writer).
    /// The picker already excludes self + already-linked peers; the writer's own
    /// pair-uniqueness backstop covers a race.
    func addLink(_ projectID: UUID, to peerID: UUID) async {
        guard projectID != peerID else { return }
        await writers.addLink(projectID, peerID)
    }

    /// Remove the link between `projectID` and `peerID` (either order). Warn-then-
    /// allow: the caller shows the in-flight warning; this always removes.
    func removeLink(_ projectID: UUID, from peerID: UUID) async {
        await writers.removeLink(projectID, peerID)
    }

    // MARK: - Activation & observation

    func activate() async {
        guard !activated else { return }
        activated = true
        observeLinks()
    }

    private func observeLinks() {
        guard let global else { return }
        linkObservation?.cancel()
        linkObservation = Task {
            let stream = await global.observeProjectLinks()
            do {
                for try await updated in stream {
                    self.links = updated
                }
            } catch {
                if !(error is CancellationError) {
                    logger.warning("project-link observation stream ended: \(error)")
                }
            }
        }
    }
}

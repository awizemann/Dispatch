// CrossProjectStoreTests.swift
// The link (consent) surface: CrossProjectStore's global observation + mutation,
// the pure unlink-warn predicate, and the deletion prune. Driven through the
// SAME mock persistence actor the app composes, so these pin the observation
// contract too.
//
// P3 removed this suite's other half (the per-project cross-project REQUEST
// mirror) along with the subsystem: cross-project traffic is bus questions now,
// covered by DispatchBusTests and MessagesInboxTests.

import Foundation
import Testing
@testable import DispatchApp

@Suite("Cross-project links")
@MainActor
struct CrossProjectStoreTests {

    private let projectA = UUID()
    private let projectB = UUID()
    private let projectC = UUID()

    private func question(
        from: UUID, to: UUID, status: BusStatus
    ) -> BusMessage {
        BusMessage(id: BusMessage.mintID(), from: from, to: to,
                   subject: "s", body: "b", status: status,
                   expiresAt: Fixtures.date(offset: 3_600))
    }

    // MARK: - Pure helpers (no store)

    @Test("hasInFlightQuestions is true iff a PENDING question (either direction) involves the peer")
    func inFlightPredicate() {
        let pendingOutbound = question(from: projectA, to: projectB, status: .pending)
        let pendingInbound = question(from: projectB, to: projectA, status: .pending)
        let answered = question(from: projectA, to: projectB, status: .answered)
        let otherPeer = question(from: projectA, to: projectC, status: .pending)

        #expect(CrossProjectStore.hasInFlightQuestions(
            with: projectB, in: projectA, messages: [pendingOutbound]))
        #expect(CrossProjectStore.hasInFlightQuestions(
            with: projectB, in: projectA, messages: [pendingInbound]))
        #expect(!CrossProjectStore.hasInFlightQuestions(
            with: projectB, in: projectA, messages: [answered]),
            "an answered question is not in flight")
        #expect(!CrossProjectStore.hasInFlightQuestions(
            with: projectB, in: projectA, messages: [otherPeer]),
            "a pending question with a DIFFERENT peer never warns about this one")
        #expect(!CrossProjectStore.hasInFlightQuestions(
            with: projectB, in: projectA, messages: []))
    }

    // MARK: - Links (global observation + mutation)

    @Test("links observe off the global actor; add/remove routes through the writers and repaints")
    func linksObserveAndMutate() async throws {
        let link = ProjectLink(projectA, projectB)
        let global = MockGlobalPersistence(projects: [], projectLinks: [link])
        let store = CrossProjectStore(global: global, writers: global.linkWriters())
        await store.activate()

        #expect(try await pollUntil { store.links.count == 1 })
        #expect(store.linkedPeerIDs(of: projectA) == [projectB])
        #expect(store.links(involving: projectA).count == 1)
        #expect(store.links(involving: projectC).isEmpty)

        // Add A↔C through the store → the writer persists → the observation repaints.
        await store.addLink(projectA, to: projectC)
        #expect(try await pollUntil { store.linkedPeerIDs(of: projectA) == [projectB, projectC] })

        // Remove A↔B → only A↔C remains.
        await store.removeLink(projectA, from: projectB)
        #expect(try await pollUntil { store.linkedPeerIDs(of: projectA) == [projectC] })
    }

    @Test("a self-link is refused, and a duplicate pair is idempotent")
    func linkGuards() async throws {
        let global = MockGlobalPersistence(projects: [], projectLinks: [])
        let store = CrossProjectStore(global: global, writers: global.linkWriters())
        await store.activate()

        await store.addLink(projectA, to: projectA)   // self — refused
        await store.addLink(projectA, to: projectB)
        await store.addLink(projectB, to: projectA)   // same unordered pair — idempotent
        #expect(try await pollUntil { store.links.count == 1 })
        #expect(store.linkedPeerIDs(of: projectA) == [projectB])
    }

    // MARK: - Deletion prune

    @Test("deleting a project prunes its links")
    func deletionPrunesLinks() async throws {
        let global = MockGlobalPersistence(
            projects: [Project(id: projectA, name: "A", repoPath: "a", pinned: false, git: nil, lastOpenedAt: nil),
                       Project(id: projectB, name: "B", repoPath: "b", pinned: false, git: nil, lastOpenedAt: nil)],
            projectLinks: [ProjectLink(projectA, projectB)])
        let store = CrossProjectStore(global: global, writers: global.linkWriters())
        await store.activate()
        #expect(try await pollUntil { store.links.count == 1 })

        await global.deleteProject(id: projectA)
        #expect(try await pollUntil { store.links.isEmpty }, "the deleted project's link was pruned")
    }

    // MARK: - Mock scenario

    @Test("the mock scenario builds two networks plus one unlinked project, and carries traffic both ways")
    func mockScenarioSurfacesLinkedTraffic() async throws {
        let stores = MockData.makeStores()
        await stores.activate()

        // TWO links: Ledgerline–Driftwood and the SECOND network Beacon–Kestrel,
        // so the rail's cluster sections and the map's cluster dimming have
        // something to show.
        #expect(try await pollUntil { stores.crossProject.links.count == 2 })
        #expect(stores.crossProject.linkedPeerIDs(of: MockData.ID.beacon)
                == [MockData.ID.kestrel])
        #expect(stores.crossProject.linkedPeerIDs(of: MockData.ID.ledgerline)
                == [MockData.ID.driftwood])
        // Halyard is the deliberately UNLINKED third project — the rail must
        // have an inert card to draw, and ask_agent must have one to refuse.
        #expect(stores.crossProject.linkedPeerIDs(of: MockData.ID.halyard).isEmpty)
        #expect(stores.linkedPeerNames(of: MockData.ID.ledgerline) == ["Driftwood"])
        #expect(stores.linkedPeerNames(of: MockData.ID.halyard).isEmpty)

        let ledgerline = stores.messages.messages(in: MockData.ID.ledgerline)
        #expect(ledgerline.contains { $0.from == MockData.ID.driftwood }, "inbound questions render")
        #expect(ledgerline.contains { $0.to == MockData.ID.driftwood }, "outbound questions render")
        // EVERY state the card renders is exercised by the fixtures — that is
        // the whole point of the scenario the verify skill screenshots.
        #expect(Set(ledgerline.map(\.status))
                == [.pending, .answered, .expired, .closed])
        #expect(ledgerline.contains { $0.answeredByHuman }, "the arbitration variant renders")
        // The peer's pending-inbound attention badge (the live-poll question
        // plus the near-expiry one Ledgerline asked it).
        #expect(stores.attentionCount(for: MockData.ID.driftwood) == 2)
        #expect(stores.attentionCount(for: MockData.ID.halyard) == 0)
    }

    @Test("the mock scenario scripts liveness and install state for every card state")
    func mockScenarioScriptsRailState() async {
        let stores = MockData.makeStores()
        await stores.activate()

        #expect(stores.connection(for: MockData.ID.ledgerline).isConnected)
        let halyard = stores.connection(for: MockData.ID.halyard)
        #expect(!halyard.isConnected && halyard.lastSeenAt == nil)

        #expect(stores.repoInstallStates[MockData.ID.halyard] == .missing,
                "the unfinished project shows the amber install chip")
        #expect(stores.busStatus.isRunning)
        #expect(stores.busStatus.installedCount == 4)
        #expect(stores.busStatus.projectCount == 5)
    }

    @Test("the scripted ticker speaks the live bus vocabulary")
    func mockScenarioSeedsTicker() async {
        let stores = MockData.makeStores()
        await stores.activate()
        let latest = stores.activity.latest(for: MockData.ID.ledgerline)
        #expect(latest?.category == .bus)
        #expect(latest?.text.contains("asks") == true)
    }
}

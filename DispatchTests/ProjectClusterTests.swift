// ProjectClusterTests.swift
// Derived cluster grouping + selection scoping.
//
// Three things could be silently wrong and are all covered here:
//   1. the derivation (components, ordering, unlinked set) — shared by the rail
//      and the map, so a bug here makes the two surfaces disagree,
//   2. the rail's section list (pinned exclusion, section ordering, identity),
//   3. the inbox's selection scoping and the chip-vs-selection precedence.

import Foundation
import Testing

@testable import DispatchApp

private enum Fix {
    /// Ids that sort by uuid in the SAME order as their index, so a test can
    /// tell "input order" from "uuid order" only where it deliberately doesn't.
    static func ids(_ count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
    }

    static func link(_ a: UUID, _ b: UUID) -> ProjectLink {
        ProjectLink(a, b, createdAt: Date(timeIntervalSince1970: 0))
    }
}

// MARK: - Derivation

@Suite("Project clusters")
struct ProjectClustersTests {

    @Test("no projects derives nothing")
    func empty() {
        let clusters = ProjectClusters(projectIDs: [], links: [])
        #expect(clusters.ids.isEmpty)
        #expect(clusters.networks.isEmpty)
        #expect(clusters.unlinked.isEmpty)
        #expect(clusters.groups.isEmpty)
        #expect(clusters.unlinkedGroupIndex == nil)
    }

    @Test("a linked pair is one network, the rest are unlinked")
    func onePair() {
        let ids = Fix.ids(3)
        let clusters = ProjectClusters(projectIDs: ids, links: [Fix.link(ids[0], ids[1])])
        #expect(clusters.networks == [[ids[0], ids[1]]])
        #expect(clusters.unlinked == [ids[2]])
        #expect(clusters.groups == [[ids[0], ids[1]], [ids[2]]])
        #expect(clusters.unlinkedGroupIndex == 1)
    }

    @Test("an A–B–C chain is ONE cluster but only two edges — a component is not a clique")
    func chainIsOneClusterNotAClique() {
        let ids = Fix.ids(3)
        let clusters = ProjectClusters(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        )
        #expect(clusters.networks == [[ids[0], ids[1], ids[2]]])
        #expect(clusters.unlinked.isEmpty)
        // A and C share a cluster (the rail groups them, the map highlights
        // them together) but there is NO A–C edge: A cannot ask C.
        #expect(clusters.edges.count == 2)
        #expect(!clusters.edges.contains(ProjectClusters.Edge(a: ids[0], b: ids[2])))
    }

    @Test("two networks come back ordered by their earliest project, members in registry order")
    func networkOrdering() {
        let ids = Fix.ids(5)
        // Deliberately declare the LATER network's link first: ordering must
        // come from project order, never from link order.
        let clusters = ProjectClusters(
            projectIDs: ids,
            links: [Fix.link(ids[3], ids[4]), Fix.link(ids[2], ids[0])]
        )
        #expect(clusters.networks == [[ids[0], ids[2]], [ids[3], ids[4]]])
        #expect(clusters.unlinked == [ids[1]])
    }

    @Test("ordering is deterministic across repeated derivations and link-order shuffles")
    func deterministic() {
        let ids = Fix.ids(6)
        let links = [
            Fix.link(ids[4], ids[5]), Fix.link(ids[0], ids[2]), Fix.link(ids[2], ids[3]),
        ]
        let first = ProjectClusters(projectIDs: ids, links: links)
        let second = ProjectClusters(projectIDs: ids, links: links.reversed())
        let third = ProjectClusters(projectIDs: ids, links: links)
        #expect(first == third)
        #expect(first.networks == second.networks)
        #expect(first.unlinked == second.unlinked)
        #expect(first.edges == second.edges)
    }

    @Test("linking two clusters MERGES them on the next derive — no membership to migrate")
    func linkingMerges() {
        let ids = Fix.ids(4)
        let before = ProjectClusters(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3])]
        )
        #expect(before.networks.count == 2)
        let after = ProjectClusters(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3]),
                    Fix.link(ids[1], ids[2])]
        )
        #expect(after.networks == [ids])
        #expect(after.unlinked.isEmpty)
    }

    @Test("unlinking splits a cluster back apart")
    func unlinkingSplits() {
        let ids = Fix.ids(4)
        let after = ProjectClusters(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1])]
        )
        #expect(after.networks == [[ids[0], ids[1]]])
        #expect(after.unlinked == [ids[2], ids[3]])
    }

    @Test("a link naming an unregistered project contributes no edge and no membership")
    func deletedProjectContributesNothing() {
        let ids = Fix.ids(3)
        let ghost = UUID()
        let clusters = ProjectClusters(
            projectIDs: [ids[0], ids[1]], links: [Fix.link(ids[0], ghost)]
        )
        #expect(clusters.networks.isEmpty)
        #expect(clusters.unlinked == [ids[0], ids[1]])
        #expect(clusters.edges.isEmpty)
    }

    @Test("self-links and duplicate rows collapse")
    func degenerateLinks() {
        let ids = Fix.ids(2)
        let clusters = ProjectClusters(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[0]), Fix.link(ids[0], ids[1]),
                    Fix.link(ids[1], ids[0])]
        )
        #expect(clusters.edges.count == 1)
        #expect(clusters.networks == [[ids[0], ids[1]]])
    }

    @Test("duplicate project ids are registered once")
    func duplicateIDs() {
        let ids = Fix.ids(2)
        let clusters = ProjectClusters(projectIDs: [ids[0], ids[0], ids[1]], links: [])
        #expect(clusters.ids == [ids[0], ids[1]])
        #expect(clusters.unlinked == [ids[0], ids[1]])
    }

    // MARK: Lookup

    @Test("a project's cluster is its whole component, including itself")
    func clusterLookup() {
        let ids = Fix.ids(4)
        let clusters = ProjectClusters(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        )
        #expect(clusters.cluster(containing: ids[2]) == [ids[0], ids[1], ids[2]])
        #expect(clusters.networkIndex(of: ids[2]) == 0)
        // A lone project's cluster is just itself.
        #expect(clusters.cluster(containing: ids[3]) == [ids[3]])
        #expect(clusters.networkIndex(of: ids[3]) == nil)
        #expect(clusters.isUnlinked(ids[3]))
        #expect(!clusters.isUnlinked(ids[0]))
        // An unregistered id has no cluster at all.
        #expect(clusters.cluster(containing: UUID()).isEmpty)
        #expect(!clusters.isUnlinked(UUID()))
    }

    @Test("no selection means no scope — clusterSet is nil, so nothing dims")
    func noScope() {
        let ids = Fix.ids(2)
        let clusters = ProjectClusters(projectIDs: ids, links: [])
        #expect(clusters.clusterSet(containing: nil) == nil)
        // A DELETED selection likewise scopes nothing, rather than dimming the
        // entire map against an id that is no longer there.
        #expect(clusters.clusterSet(containing: UUID()) == nil)
        #expect(clusters.clusterSet(containing: ids[0]) == [ids[0]])
    }
}

// MARK: - Map scoping

@Suite("Bus map selection scope")
struct BusMapScopeTests {

    @Test("everything is in scope when nothing is selected")
    func unscopedShowsAll() {
        let ids = Fix.ids(3)
        #expect(BusMapView.isInScope(ids[0], nil))
        #expect(BusMapView.isInScope(ids[2], nil))
    }

    @Test("selecting a project keeps its cluster lit and dims every other one")
    func selectionDimsOtherClusters() {
        let ids = Fix.ids(5)
        let clusters = ProjectClusters(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3])]
        )
        let focus = clusters.clusterSet(containing: ids[0])
        #expect(BusMapView.isInScope(ids[0], focus))
        #expect(BusMapView.isInScope(ids[1], focus), "cluster mate stays lit")
        #expect(!BusMapView.isInScope(ids[2], focus), "the other network dims")
        #expect(!BusMapView.isInScope(ids[3], focus))
        #expect(!BusMapView.isInScope(ids[4], focus), "the unlinked project dims")
    }

    @Test("selecting an UNLINKED project scopes to it alone")
    func selectingUnlinked() {
        let ids = Fix.ids(3)
        let clusters = ProjectClusters(projectIDs: ids, links: [Fix.link(ids[0], ids[1])])
        let focus = clusters.clusterSet(containing: ids[2])
        #expect(focus == [ids[2]])
        #expect(!BusMapView.isInScope(ids[0], focus))
    }

    @Test("the layout carries the SAME clusters the rail groups by")
    func layoutSharesTheDerivation() {
        let ids = Fix.ids(4)
        let links = [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3])]
        let layout = BusMapLayout(projectIDs: ids, links: links)
        let rail = RailSectionLayout.sections(
            allProjectIDs: ids, links: links, excluding: []
        )
        #expect(layout.clusters.networks == rail.map(\.projectIDs))
    }
}

// MARK: - Rail sections

@Suite("Rail cluster sections")
struct RailSectionLayoutTests {

    @Test("no projects renders no sections")
    func empty() {
        #expect(RailSectionLayout.sections(allProjectIDs: [], links: [], excluding: []).isEmpty)
    }

    @Test("one cluster only — a single section, so the view draws no separators")
    func singleCluster() {
        let ids = Fix.ids(3)
        let sections = RailSectionLayout.sections(
            allProjectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])],
            excluding: []
        )
        #expect(sections.count == 1)
        #expect(sections[0].projectIDs == ids)
        #expect(!sections[0].isUnlinked)
    }

    @Test("all unlinked — one trailing section, nothing else")
    func allUnlinked() {
        let ids = Fix.ids(3)
        let sections = RailSectionLayout.sections(
            allProjectIDs: ids, links: [], excluding: []
        )
        #expect(sections.count == 1)
        #expect(sections[0].isUnlinked)
        #expect(sections[0].projectIDs == ids)
    }

    @Test("networks come first in registry order, unlinked always LAST")
    func sectionOrdering() {
        let ids = Fix.ids(5)
        let sections = RailSectionLayout.sections(
            allProjectIDs: ids,
            links: [Fix.link(ids[3], ids[4]), Fix.link(ids[0], ids[2])],
            excluding: []
        )
        #expect(sections.map(\.projectIDs)
                == [[ids[0], ids[2]], [ids[3], ids[4]], [ids[1]]])
        #expect(sections.map(\.isUnlinked) == [false, false, true])
    }

    @Test("section ordering is stable across repeated derivations")
    func orderingIsStable() {
        let ids = Fix.ids(6)
        let links = [Fix.link(ids[4], ids[5]), Fix.link(ids[1], ids[3])]
        let first = RailSectionLayout.sections(allProjectIDs: ids, links: links, excluding: [])
        let second = RailSectionLayout.sections(
            allProjectIDs: ids, links: links.reversed(), excluding: []
        )
        #expect(first == second)
        #expect(first.map(\.id) == second.map(\.id))
    }

    @Test("a pinned project appears in its pinned slot ONLY, never duplicated into its cluster")
    func pinnedIsNotDuplicated() {
        let ids = Fix.ids(3)
        let sections = RailSectionLayout.sections(
            allProjectIDs: ids, links: [Fix.link(ids[0], ids[1])], excluding: [ids[0]]
        )
        #expect(sections.map(\.projectIDs) == [[ids[1]], [ids[2]]])
        #expect(sections.allSatisfy { !$0.projectIDs.contains(ids[0]) })
    }

    @Test("a cluster whose members are ALL pinned contributes no section")
    func fullyPinnedClusterDisappears() {
        let ids = Fix.ids(3)
        let sections = RailSectionLayout.sections(
            allProjectIDs: ids, links: [Fix.link(ids[0], ids[1])],
            excluding: [ids[0], ids[1]]
        )
        #expect(sections.count == 1)
        #expect(sections[0].isUnlinked)
        #expect(sections[0].projectIDs == [ids[2]])
    }

    @Test("pinning does not change WHO is in whose cluster")
    func pinningDoesNotRegroup() {
        let ids = Fix.ids(4)
        let links = [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        let pinned = RailSectionLayout.sections(
            allProjectIDs: ids, links: links, excluding: [ids[1]]
        )
        // ids[0] and ids[2] are only in one cluster BECAUSE of the pinned
        // ids[1] in the middle. Removing it from the rendered run must not
        // split them into two sections.
        #expect(pinned.map(\.projectIDs) == [[ids[0], ids[2]], [ids[3]]])
    }

    @Test("a section's identity follows its first member, not its ordinal")
    func stableIdentity() {
        let ids = Fix.ids(4)
        let before = RailSectionLayout.sections(
            allProjectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3])], excluding: []
        )
        // Merge the two networks: the surviving section still starts at ids[0],
        // so it keeps its identity rather than re-identifying everything below.
        let after = RailSectionLayout.sections(
            allProjectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3]),
                    Fix.link(ids[1], ids[2])], excluding: []
        )
        #expect(after.count == 1)
        #expect(after[0].id == before[0].id)
        #expect(Set(before.map(\.id)).count == before.count, "ids are unique")
    }
}

// MARK: - Inbox scoping + chip precedence

@Suite("Inbox selection scoping")
@MainActor
struct InboxSelectionScopeTests {

    private func model() -> MessagesInboxModel { MessagesInboxModel(debounce: .zero) }

    @Test("selecting a project applies its chip")
    func selectionAppliesChip() {
        let ids = Fix.ids(2)
        let model = model()
        #expect(model.peerFilter == nil)
        model.applySelectionScope(ids[0])
        #expect(model.peerFilter == ids[0])
        #expect(!model.isFilterUserOwned)
    }

    @Test("selecting a DIFFERENT project re-scopes")
    func reselectRescopes() {
        let ids = Fix.ids(2)
        let model = model()
        model.applySelectionScope(ids[0])
        model.applySelectionScope(ids[1])
        #expect(model.peerFilter == ids[1])
    }

    @Test("selecting nothing clears the scope")
    func nilSelectionClears() {
        let ids = Fix.ids(1)
        let model = model()
        model.applySelectionScope(ids[0])
        model.applySelectionScope(nil)
        #expect(model.peerFilter == nil)
    }

    @Test("RULING: a manually toggled chip WINS over the standing selection")
    func chipBeatsStandingSelection() {
        let ids = Fix.ids(2)
        let model = model()
        model.applySelectionScope(ids[0])
        // The human picks a different project's chip while ids[0] is selected.
        model.togglePeerFilter(ids[1])
        #expect(model.peerFilter == ids[1])
        #expect(model.isFilterUserOwned)
        // Re-applying the SAME (unchanged) selection — every re-render, and a
        // map click that re-selects what is already selected — must not stomp it.
        model.applySelectionScope(ids[0])
        model.applySelectionScope(ids[0])
        #expect(model.peerFilter == ids[1], "the chip stands")
    }

    @Test("clearing the chip under a standing selection leaves the inbox unscoped")
    func clearingChipStands() {
        let ids = Fix.ids(1)
        let model = model()
        model.applySelectionScope(ids[0])
        model.togglePeerFilter(ids[0])            // toggle off
        #expect(model.peerFilter == nil)
        model.applySelectionScope(ids[0])         // a re-render
        #expect(model.peerFilter == nil, "it stays cleared")
    }

    @Test("clear-filters also beats the standing selection")
    func clearFiltersStands() {
        let ids = Fix.ids(1)
        let model = model()
        model.applySelectionScope(ids[0])
        model.clearFilters()
        model.applySelectionScope(ids[0])
        #expect(model.peerFilter == nil)
        #expect(model.isFilterUserOwned)
    }

    @Test("selecting a NEW project reclaims the filter from the human")
    func newSelectionReclaims() {
        let ids = Fix.ids(2)
        let model = model()
        model.applySelectionScope(ids[0])
        model.togglePeerFilter(ids[1])
        model.applySelectionScope(ids[1])
        // The selection moved; the scope is the app's again.
        #expect(model.peerFilter == ids[1])
        #expect(!model.isFilterUserOwned)
    }

    @Test("the very first pass applies even when nothing is selected")
    func firstPassWithNilSelection() {
        let ids = Fix.ids(1)
        let model = model()
        model.togglePeerFilter(ids[0])
        model.applySelectionScope(nil)
        #expect(model.peerFilter == nil, "boot with no selection means no scope")
    }

    @Test("deleting the selected project re-scopes to whatever selection replaces it")
    func deletedSelection() {
        let ids = Fix.ids(2)
        let model = model()
        model.applySelectionScope(ids[0])
        // ProjectStore.deleteProject moves selection off the deleted row first;
        // the inbox follows it.
        model.applySelectionScope(ids[1])
        #expect(model.peerFilter == ids[1])
        // Deleting the LAST project leaves no selection at all.
        model.applySelectionScope(nil)
        #expect(model.peerFilter == nil)
    }

    @Test("the scoped inbox says so in its caption")
    func caption() {
        #expect(MessagesTabView.filteredCaption(projectName: "Ledgerline")
                    .contains("Ledgerline"))
    }
}

// MARK: - The mock scenario, end to end

@Suite("Mock scenario clustering")
@MainActor
struct MockClusteringTests {

    /// The links mirror fills in through the store's OBSERVATION, not the
    /// initial fetch, so every case here waits for it rather than reading
    /// `MockData.projectLinks` directly — the point is that the real store feeds
    /// the real derivation.
    private func activated() async throws -> AppStores {
        let stores = MockData.makeStores()
        await stores.activate()
        _ = try await pollUntil { !stores.crossProject.links.isEmpty }
        return stores
    }

    @Test("the mock shows two networks and one project off the network")
    func mockShape() async throws {
        let stores = try await activated()
        let clusters = ProjectClusters(
            projectIDs: stores.projects.projects.map(\.id),
            links: stores.crossProject.links
        )
        #expect(clusters.networks == [
            [MockData.ID.ledgerline, MockData.ID.driftwood],
            [MockData.ID.beacon, MockData.ID.kestrel],
        ])
        #expect(clusters.unlinked == [MockData.ID.halyard])
    }

    @Test("selecting Ledgerline dims Beacon, Kestrel and Halyard on the map")
    func mockScoping() async throws {
        let stores = try await activated()
        stores.projects.select(MockData.ID.ledgerline)
        let layout = BusMapLayout(clusters: ProjectClusters(
            projectIDs: stores.projects.projects.map(\.id),
            links: stores.crossProject.links
        ))
        let focus = layout.clusters.clusterSet(containing: stores.projects.selectedProjectID)
        #expect(BusMapView.isInScope(MockData.ID.driftwood, focus))
        #expect(!BusMapView.isInScope(MockData.ID.beacon, focus))
        #expect(!BusMapView.isInScope(MockData.ID.kestrel, focus))
        #expect(!BusMapView.isInScope(MockData.ID.halyard, focus))
    }

    @Test("the rail puts Ledgerline in PINNED and never repeats it in its cluster")
    func mockRailSections() async throws {
        let stores = try await activated()
        let sections = RailSectionLayout.sections(
            allProjectIDs: stores.projects.projects.map(\.id),
            links: stores.crossProject.links,
            excluding: Set(stores.projects.pinnedProjects.map(\.id))
        )
        #expect(stores.projects.pinnedProjects.map(\.id) == [MockData.ID.ledgerline])
        #expect(sections.map(\.projectIDs) == [
            [MockData.ID.driftwood],
            [MockData.ID.beacon, MockData.ID.kestrel],
            [MockData.ID.halyard],
        ])
        #expect(sections.map(\.isUnlinked) == [false, false, true])
    }
}

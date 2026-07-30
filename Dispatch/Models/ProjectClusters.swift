// ProjectClusters.swift
// The DERIVED grouping of projects — the one union-find in the app.
//
// A "cluster" is a connected component of the link graph. It is NOT an entity:
// there is no group table, no membership rule, no name. Two projects are in the
// same cluster because a human linked a path between them, and linking across
// two clusters simply merges them the next time this is derived. Deleting the
// last link on that path splits them again. Nothing to migrate, nothing to keep
// consistent — which is exactly why the product has no group concept.
//
// A COMPONENT IS NOT A CLIQUE. In the chain A–B–C all three share a cluster, but
// A still cannot `ask_agent` C: only the actual pairwise `ProjectLink` rows are
// consent. So this type reports BOTH — `networks` (who is in the same reachable
// neighbourhood, which is what the rail groups and the map highlights) and
// `edges` (who may actually talk, which is what the map DRAWS). Never draw a
// blob around a component; it would be a lie about permission.
//
// ORDERING is a pure function of (project order, link set):
//   - members of a cluster come back in input order,
//   - clusters are ordered by their lowest member index — i.e. by the earliest
//     project in the caller's order, which for the rail is the registry order,
//   - every UNLINKED project lands in one trailing `unlinked` group.
// Same input, same sections, every launch. No sorting by uuid (random), no
// sorting by size (a link would reshuffle the rail).
//
// Consumers: `BusMapLayout` (station placement + which stations get dimmed) and
// `ProjectsRailView` (one section per cluster). They MUST agree, so they share
// this rather than each rolling their own traversal.

import Foundation

nonisolated struct ProjectClusters: Equatable, Sendable {

    /// One canonical link between two REGISTERED projects, ends ordered by the
    /// caller's input order (not by uuid). Duplicated rows and self-links are
    /// already collapsed away.
    struct Edge: Equatable, Sendable {
        let a: UUID
        let b: UUID
    }

    /// The registered project ids, deduplicated, in input order.
    let ids: [UUID]
    /// Multi-project components ("networks"), ordered by lowest member index;
    /// members in input order. A single project on its own is never here.
    let networks: [[UUID]]
    /// Projects with no link at all — off the network, in input order. They can
    /// neither ask nor be asked, and both surfaces render them apart.
    let unlinked: [UUID]
    /// Canonical pairwise links, ordered by their endpoints' input indices.
    let edges: [Edge]

    /// Input index per id (lookup for consumers that place by index).
    private let indexByID: [UUID: Int]
    /// Network index per id; absent for unlinked projects.
    private let networkByID: [UUID: Int]

    /// The groups to lay out, in order: every network, then ONE trailing group
    /// holding every unlinked project (empty groups are never emitted). Both the
    /// map's columns and the rail's sections walk this.
    var groups: [[UUID]] {
        unlinked.isEmpty ? networks : networks + [unlinked]
    }

    /// Index of the trailing unlinked group inside `groups`, or nil when every
    /// project is linked. Consumers use it to give "off the network" its extra
    /// separation.
    var unlinkedGroupIndex: Int? {
        unlinked.isEmpty ? nil : networks.count
    }

    /// - Parameters:
    ///   - projectIDs: every registered project, in the order the surface should
    ///     read. Later duplicates are ignored.
    ///   - links: the `projectLink` rows. A link naming a project that is not
    ///     registered (deleted mid-flight) contributes nothing — no phantom
    ///     edge, no phantom membership.
    init(projectIDs: [UUID], links: [ProjectLink]) {
        var indexOf: [UUID: Int] = [:]
        var ordered: [UUID] = []
        for id in projectIDs where indexOf[id] == nil {
            indexOf[id] = ordered.count
            ordered.append(id)
        }
        self.ids = ordered
        self.indexByID = indexOf
        let count = ordered.count
        guard count > 0 else {
            self.networks = []
            self.unlinked = []
            self.edges = []
            self.networkByID = [:]
            return
        }

        // Normalized pair set over INDICES: both ends registered, no self-pairs,
        // and (x, y) == (y, x) so a duplicated row collapses to one edge.
        var pairs: Set<Pair> = []
        for link in links {
            guard let x = indexOf[link.projectA], let y = indexOf[link.projectB], x != y
            else { continue }
            pairs.insert(Pair(min(x, y), max(x, y)))
        }

        // Union-find over the pairs.
        var parent = Array(0..<count)
        func find(_ x: Int) -> Int {
            var root = x
            while parent[root] != root { root = parent[root] }
            var walk = x
            while parent[walk] != walk {           // path compression
                let next = parent[walk]
                parent[walk] = root
                walk = next
            }
            return root
        }
        for pair in pairs {
            let (rx, ry) = (find(pair.low), find(pair.high))
            if rx != ry { parent[rx] = ry }
        }

        var membersByRoot: [Int: [Int]] = [:]
        for index in 0..<count { membersByRoot[find(index), default: []].append(index) }

        let networkIndices = membersByRoot.values
            .filter { $0.count > 1 }
            .map { $0.sorted() }
            .sorted { ($0.first ?? 0) < ($1.first ?? 0) }
        let looseIndices = membersByRoot.values
            .filter { $0.count == 1 }
            .compactMap(\.first)
            .sorted()

        self.networks = networkIndices.map { $0.map { ordered[$0] } }
        self.unlinked = looseIndices.map { ordered[$0] }
        var byID: [UUID: Int] = [:]
        for (network, members) in networkIndices.enumerated() {
            for member in members { byID[ordered[member]] = network }
        }
        self.networkByID = byID
        self.edges = pairs
            .sorted { $0.low == $1.low ? $0.high < $1.high : $0.low < $1.low }
            .map { Edge(a: ordered[$0.low], b: ordered[$0.high]) }
    }

    // MARK: - Lookup

    func index(of id: UUID) -> Int? { indexByID[id] }

    /// The network this project belongs to, or nil when it is unlinked.
    func networkIndex(of id: UUID) -> Int? { networkByID[id] }

    func isUnlinked(_ id: UUID) -> Bool {
        indexByID[id] != nil && networkByID[id] == nil
    }

    /// Every project in `id`'s cluster, INCLUDING itself — a lone project's
    /// cluster is just itself, and an unregistered id has none.
    ///
    /// This is the SCOPE both surfaces highlight: reachable neighbourhood, not
    /// permission. `ask_agent` still needs a real edge (see `edges`).
    func cluster(containing id: UUID) -> [UUID] {
        guard indexByID[id] != nil else { return [] }
        guard let network = networkByID[id] else { return [id] }
        return networks[network]
    }

    /// Set form of `cluster(containing:)`, for the per-node "is this in the
    /// focused cluster?" test the map runs once per station and line.
    func clusterSet(containing id: UUID?) -> Set<UUID>? {
        guard let id, indexByID[id] != nil else { return nil }
        return Set(cluster(containing: id))
    }

    /// An unordered index pair, so a link and its reverse collapse to one edge.
    private struct Pair: Hashable {
        let low: Int
        let high: Int
        init(_ low: Int, _ high: Int) {
            self.low = low
            self.high = high
        }
    }
}

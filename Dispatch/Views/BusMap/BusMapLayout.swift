// BusMapLayout.swift
// The PURE geometry of the bus map — stations are PROJECTS, lines
// are `projectLink` edges. No SwiftUI, no colors: just the math the band draws,
// isolated so it is unit-testable without a window.
//
// WHY PAIRWISE, NOT BLOBS: the map's whole job is to show who may talk to whom,
// and linking is the product's consent gate. A chain A–B–C must therefore render
// A–B and B–C and NOTHING between A and C: `ask_agent` from A to C fails closed,
// so a blob drawn around the component would be a lie about permission. Every
// edge here comes from one real ProjectLink row.
//
// LAYOUT (deterministic, no force simulation — a map that reshuffles itself on
// every event is not calm):
//   1. Connected components over the link edges — derived by `ProjectClusters`,
//      the ONE union-find in the app, shared with the rail's section grouping so
//      the two surfaces can never disagree about who is in whose cluster.
//   2. Multi-station components first, ordered by their lowest input index;
//      every ISOLATED (unlinked) project is packed into ONE trailing group so
//      seven lonely repos don't spread across seven gaps.
//   3. Inside a group, stations fill a row-major grid — one row up to
//      `maxSingleRow`, two rows beyond — in HUB-AWARE order (below). A chain
//      therefore reads left to right, which is what makes the "subway" legible.
// The result is a function of (project order, link set) alone: same input, same
// pixels, every launch.
//
// HUB-AWARE ORDER. Placing in raw input order let a real link pass
// BEHIND an unrelated station: two leaves each linking to a shared hub
// (A–C and B–C), laid out A, B, C, drew the A–C line straight through B's tile,
// and the picture read as an A–B–C chain that does not exist and would fail
// closed if anyone tried it. So each group is sequenced by attachment: seed the
// highest-degree station (the hub), then repeatedly take the unplaced station
// adjacent to an END of the run and grow that end outward. The hub therefore
// lands BETWEEN its leaves instead of at the edge, and in the two-leaf case
// every edge ends up connecting grid neighbours. Ties break by degree then input
// index, so the sequence is a pure deterministic function of the input.
//
// ARCS. A heuristic cannot make every edge adjacent (a 4-station star has to
// span something), so anything still spanning is routed as a quadratic ARC that
// bows over the station band instead of through it — see `control`. Between the
// two the map can no longer draw a connection that isn't there.
//
// LABEL SIDES, AND WHY CROSS-ROW LINES ARE STRAIGHT. Every station
// carries a NAME, and a line drawn through somebody else's name is as unreadable
// as one drawn behind their tile. With every label hanging below its tile, the
// corridor between two rows was solid text: a hub on row 0 reaching a leaf on
// row 1 crossed the hub's OWN label on the way down, because the label box is 88
// wide inside a 100 pitch and a one-column step only moves 29pt by the time the
// line is level with it. No quadratic threads that reliably.
//
// So the corridor is CLEARED instead of dodged: in a two-row group the TOP row's
// names sit ABOVE their tiles and the bottom row's below, which puts every label
// box outside the band between the two rows. Cross-row lines are then straight
// and provably clear — they only ever occupy y between the two row centers — and
// same-row arcs bow INTO that same corridor (down from the top row, up from the
// bottom row) rather than over their own names. A one-row group is untouched:
// labels below, arcs up, exactly as before. The invariant this buys, asserted as
// a property over every topology in the tests: NO drawn edge ever enters any
// station's label rect.
//
// COORDINATE SPACE: `nodes[].center` is the STATION TILE's center, in the band's
// content space (origin top-left). Lines run tile-center to tile-center and are
// drawn UNDER the opaque tiles, so no line-end trimming is needed. The name
// label hangs `labelDrop * 2` from the tile, on the side `labelAbove` names.

import Foundation

/// One station: a project, placed.
nonisolated struct BusMapNode: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The station TILE's center, in content space.
    let center: CGPoint
    /// Which laid-out group this station belongs to (render/debug identity).
    /// Isolated projects all share the last group.
    let groupIndex: Int
    /// This project has no links at all — it sits apart from the network and
    /// renders dimmed. It can neither ask nor be asked.
    let isIsolated: Bool
    /// This station's NAME hangs above its tile rather than below it — true only
    /// for the top row of a two-row group, which is what keeps the corridor
    /// between the rows free of text for the cross-row lines to run through.
    let labelAbove: Bool

    /// The box this station's name occupies, in content space. Nothing drawn
    /// (line or pulse) may enter it — see the file header.
    var labelRect: CGRect { BusMapLayout.labelRect(center: center, above: labelAbove) }

    /// Where the station's composed VStack (tile + name) must be positioned so
    /// its TILE lands exactly on `center`.
    var viewCenter: CGPoint {
        CGPoint(x: center.x,
                y: center.y + (labelAbove ? -BusMapLayout.labelDrop : BusMapLayout.labelDrop))
    }
}

/// One line: an actual `ProjectLink` row between two placed stations.
nonisolated struct BusMapEdge: Identifiable, Equatable, Sendable {
    /// Canonical low end (by the caller's input order, not uuid).
    let a: UUID
    let b: UUID
    let from: CGPoint
    let to: CGPoint
    /// Quadratic control point when this line has to SPAN a station — i.e. some
    /// other tile sits on the straight segment between its ends. nil means the
    /// two stations are clear of each other and the line is drawn straight.
    ///
    /// The arc bows toward the side its row's names are NOT on: up for a row
    /// whose labels hang below (every one-row group, and the bottom row of a
    /// two-row group), down for the top row of a two-row group, whose names sit
    /// above. Either way the bow lands in empty space rather than in text.
    let control: CGPoint?

    var id: String { "\(a.uuidString)|\(b.uuidString)" }

    /// True when this line connects the two given projects, in either order.
    func connects(_ x: UUID, _ y: UUID) -> Bool {
        (a == x && b == y) || (a == y && b == x)
    }

    /// This line passes over at least one station rather than between neighbours.
    var isArc: Bool { control != nil }

    /// The point `t` (0…1) of the way along the drawn line — the straight lerp,
    /// or the quadratic Bézier when this edge arcs. The travelling pulse dot is
    /// positioned by this, so the dot rides the SAME curve the stroke draws
    /// instead of cutting the corner through the station it was routed around.
    func point(at t: CGFloat) -> CGPoint {
        guard let control else {
            return CGPoint(x: from.x + (to.x - from.x) * t,
                           y: from.y + (to.y - from.y) * t)
        }
        let inverse = 1 - t
        let a0 = inverse * inverse
        let a1 = 2 * inverse * t
        let a2 = t * t
        return CGPoint(x: a0 * from.x + a1 * control.x + a2 * to.x,
                       y: a0 * from.y + a1 * control.y + a2 * to.y)
    }

    /// Same line, walked from `origin` — the layout's edge is canonical, but a
    /// pulse knows which way the message actually went. The arc is symmetric, so
    /// reversing the ends keeps the identical curve.
    func oriented(from origin: UUID) -> BusMapEdge {
        guard origin == b else { return self }
        return BusMapEdge(a: b, b: a, from: to, to: from, control: control)
    }
}

nonisolated struct BusMapLayout: Equatable, Sendable {

    // MARK: - Geometry constants (owned here so the math is testable alone)

    /// Horizontal pitch between stations in a group.
    static let cellWidth: CGFloat = 100
    /// Vertical pitch between station rows.
    static let cellHeight: CGFloat = 80
    /// Gap between two laid-out groups (separate networks read as separate).
    static let componentGap: CGFloat = 40
    /// Extra breathing room BEFORE the trailing group of unlinked projects, on
    /// top of `componentGap`. "Off the network" has to read at a glance, and at
    /// one plain gap an isolated station looks like it might just be the far end
    /// of the network next to it.
    static let isolatedGap: CGFloat = 36
    /// The station tile's side.
    static let stationTile: CGFloat = 34
    /// A group with more stations than this wraps onto a second row.
    static let maxSingleRow = 4
    /// The name label's own height — one line at the station's type size.
    static let labelHeight: CGFloat = 14
    /// The station VStack's tile-to-name gap.
    static let labelSpacing: CGFloat = 6
    /// The name label's width — the Text frame the station composes. Note it is
    /// only 12pt narrower than the cell pitch: adjacent labels leave a 12pt
    /// gutter, which is why routing a line BETWEEN two names is not a plan.
    static let labelWidth: CGFloat = cellWidth - 12
    /// How far the station's VStack (tile + name) sits from the tile center, so
    /// a view positioned at `center.y ± labelDrop` puts the tile exactly on
    /// `center`. Half the (label height + spacing) the station composes.
    static let labelDrop: CGFloat = (labelHeight + labelSpacing) / 2
    /// How far above the row an arc's apex rises. Must clear the tile's half
    /// height (17) AND the live/attention dot pinned to its top-trailing corner,
    /// with enough air left that the curve reads as going OVER the station
    /// rather than touching it. At 26 the arc grazed that dot on screen.
    static let arcRise: CGFloat = 30
    /// The apex never rises nearer than this to the top of the content box, so a
    /// row-0 arc can't be clipped by the band. (At the current cell height the
    /// clamp is slack — it exists so tuning `cellHeight` can't silently crop.)
    static let arcTopInset: CGFloat = 4

    // MARK: - Result

    /// Stations, in the caller's input order (stable across relayouts).
    let nodes: [BusMapNode]
    /// Lines, ordered by their endpoints' input indices.
    let edges: [BusMapEdge]
    /// The drawn content's size — the band scrolls horizontally past its width.
    let contentSize: CGSize
    /// The derived grouping this placement came from — the map asks it which
    /// stations share the selected project's cluster (the dimming scope).
    let clusters: ProjectClusters

    /// - Parameters:
    ///   - projectIDs: every registered project, in the order the map should
    ///     read (the rail's order). Duplicates are ignored.
    ///   - links: the `projectLink` rows. A link naming a project that is not in
    ///     `projectIDs` (deleted mid-flight) contributes NO edge — the map never
    ///     draws a line to a station that isn't there.
    init(projectIDs: [UUID], links: [ProjectLink]) {
        self.init(clusters: ProjectClusters(projectIDs: projectIDs, links: links))
    }

    /// Places an ALREADY-DERIVED grouping. The view derives `ProjectClusters`
    /// once per body and hands the same value to both the layout and the
    /// selection highlight, so the two can never disagree about who is in whose
    /// cluster.
    init(clusters: ProjectClusters) {
        self.clusters = clusters
        let ids = clusters.ids
        let count = ids.count
        guard count > 0 else {
            self.nodes = []
            self.edges = []
            self.contentSize = .zero
            return
        }
        var indexOf: [UUID: Int] = [:]
        for (index, id) in ids.enumerated() { indexOf[id] = index }

        let groups = clusters.groups
        let looseGroupIndex = clusters.unlinkedGroupIndex ?? -1

        // Who is adjacent to whom, by input index — the input to the hub-aware
        // ordering below. Built once for every group.
        var neighbours = [Set<Int>](repeating: [], count: count)
        for edge in clusters.edges {
            guard let x = indexOf[edge.a], let y = indexOf[edge.b] else { continue }
            neighbours[x].insert(y)
            neighbours[y].insert(x)
        }

        // Place each group in a row-major grid, groups left to right.
        var centers = [CGPoint](repeating: .zero, count: count)
        var groupOf = [Int](repeating: 0, count: count)
        /// Whose name goes ABOVE its tile: the top row of a two-row group, so
        /// the corridor between the rows carries lines instead of text.
        var labelAboveOf = [Bool](repeating: false, count: count)
        var xOffset: CGFloat = 0
        var rowsUsed = 1
        for (groupIndex, rawMembers) in groups.enumerated() {
            if groupIndex == looseGroupIndex && groupIndex > 0 { xOffset += Self.isolatedGap }
            let members = Self.placementOrder(
                rawMembers, indexOf: indexOf, neighbours: neighbours
            )
            let rows = members.count <= Self.maxSingleRow ? 1 : 2
            let columns = Int((Double(members.count) / Double(rows)).rounded(.up))
            rowsUsed = max(rowsUsed, rows)
            for (slot, member) in members.enumerated() {
                guard let memberIndex = indexOf[member] else { continue }
                let column = slot % columns
                let row = slot / columns
                centers[memberIndex] = CGPoint(
                    x: xOffset + (CGFloat(column) + 0.5) * Self.cellWidth,
                    y: (CGFloat(row) + 0.5) * Self.cellHeight
                )
                groupOf[memberIndex] = groupIndex
                labelAboveOf[memberIndex] = rows > 1 && row == 0
            }
            xOffset += CGFloat(columns) * Self.cellWidth + Self.componentGap
        }

        self.nodes = ids.enumerated().map { index, id in
            BusMapNode(
                id: id, center: centers[index], groupIndex: groupOf[index],
                isIsolated: groupOf[index] == looseGroupIndex,
                labelAbove: labelAboveOf[index]
            )
        }
        self.edges = clusters.edges.compactMap { edge in
            guard let x = indexOf[edge.a], let y = indexOf[edge.b] else { return nil }
            // Bow AWAY from the names: a row whose labels are above arcs down
            // into the corridor, everyone else arcs up.
            let rise = labelAboveOf[x] ? Self.arcRise : -Self.arcRise
            return BusMapEdge(
                a: edge.a, b: edge.b, from: centers[x], to: centers[y],
                control: Self.arcControl(from: centers[x], to: centers[y],
                                         stations: centers, rise: rise)
            )
        }
        self.contentSize = CGSize(
            width: max(0, xOffset - Self.componentGap),
            height: CGFloat(rowsUsed) * Self.cellHeight
        )
    }

    // MARK: - Hub-aware ordering (pure, testable)

    /// The order `members` should fill their grid slots in, so that as many real
    /// links as possible connect grid NEIGHBOURS.
    ///
    /// Greedy attachment, fully deterministic:
    ///   1. Seed the highest-degree station — the hub — breaking ties by input
    ///      index. Seeding a hub is what puts it in the MIDDLE: it gets grown on
    ///      from both sides.
    ///   2. Repeatedly take the unplaced station adjacent to the most ends of the
    ///      run (ties: higher degree, then lower input index) and extend that
    ///      end — prepend when it attaches to the head, append otherwise.
    /// A station adjacent to neither end (the third leaf of a star) is appended;
    /// its edge then spans, and `arcControl` routes it over the row.
    ///
    /// With no edges at all — the trailing unlinked group — every score is 0 and
    /// this degenerates to the input order it was handed.
    static func placementOrder(
        _ members: [UUID], indexOf: [UUID: Int], neighbours: [Set<Int>]
    ) -> [UUID] {
        guard members.count > 2 else { return members }
        let indices = members.compactMap { indexOf[$0] }
        guard indices.count == members.count else { return members }
        let inGroup = Set(indices)
        // Degree WITHIN the group (it is a component, so this is the full degree,
        // but intersecting keeps the function honest if it is ever reused).
        func degree(_ index: Int) -> Int { neighbours[index].intersection(inGroup).count }

        var remaining = indices
        guard let seed = remaining.min(by: {
            degree($0) == degree($1) ? $0 < $1 : degree($0) > degree($1)
        }) else { return members }
        remaining.removeAll { $0 == seed }
        var run = [seed]

        while !remaining.isEmpty {
            let head = run[0]
            let tail = run[run.count - 1]
            func score(_ index: Int) -> Int {
                var value = neighbours[index].contains(head) ? 1 : 0
                if head != tail, neighbours[index].contains(tail) { value += 1 }
                return value
            }
            // `min(by:)` over a strict "is better" ordering keeps the first
            // best candidate, and `remaining` is in input order — so the
            // tie-break is input order, no sort stability assumption needed.
            guard let next = remaining.min(by: {
                if score($0) != score($1) { return score($0) > score($1) }
                if degree($0) != degree($1) { return degree($0) > degree($1) }
                return $0 < $1
            }) else { break }
            remaining.removeAll { $0 == next }
            // Attaching to the HEAD (and only the head) grows the run left;
            // everything else — the tail, both ends, or neither — grows it
            // right. While the run is one station long both ends are the same
            // station, so the first attachment always goes right and the second
            // one wraps around to the left: that is what centres the hub.
            let growsLeft = run.count > 1
                && neighbours[next].contains(head)
                && !neighbours[next].contains(tail)
            if growsLeft { run.insert(next, at: 0) } else { run.append(next) }
        }
        var idByIndex: [Int: UUID] = [:]
        for (offset, index) in indices.enumerated() { idByIndex[index] = members[offset] }
        return run.compactMap { idByIndex[$0] }
    }

    // MARK: - Arc routing (pure, testable)

    /// The quadratic control point for a line from `from` to `to`, or nil when
    /// the line is clear. A line is NOT clear when another station sits on the
    /// same row strictly between its ends — that is exactly the case where a
    /// straight segment would vanish behind an opaque tile and read as a chain
    /// through a station the two ends may not actually reach.
    ///
    /// A CROSS-ROW line is always nil — straight. That is not a shortcut: the
    /// label sides (see the file header) are chosen precisely so the band
    /// between two row centers holds no text, and a straight segment between two
    /// row centers cannot leave that band.
    ///
    /// The apex sits `|rise|` off the row (a quadratic's midpoint is halfway to
    /// its control point, hence the doubling). NEGATIVE `rise` bows UP and is
    /// clamped so the apex stays inside the content box; positive bows DOWN,
    /// which only ever happens for the TOP row of a two-row group and therefore
    /// always has a whole row's worth of box beneath it.
    static func arcControl(
        from: CGPoint, to: CGPoint, stations: [CGPoint], rise: CGFloat = -arcRise
    ) -> CGPoint? {
        guard from.y == to.y else { return nil }        // not a same-row run
        let low = min(from.x, to.x)
        let high = max(from.x, to.x)
        let spans = stations.contains { $0.y == from.y && $0.x > low && $0.x < high }
        guard spans else { return nil }
        let clamped = rise < 0
            ? -min(-rise, max(0, from.y - Self.arcTopInset))
            : rise
        return CGPoint(x: (from.x + to.x) / 2, y: from.y + 2 * clamped)
    }

    // MARK: - Label boxes (pure, testable)

    /// The box a station's name occupies, given its tile center and which side
    /// the name hangs on. This is the ONE definition of the obstruction: the
    /// station view composes its VStack from the same constants, and the layout
    /// property test checks every drawn edge against it.
    static func labelRect(center: CGPoint, above: Bool) -> CGRect {
        let top = above
            ? center.y - stationTile / 2 - labelSpacing - labelHeight
            : center.y + stationTile / 2 + labelSpacing
        return CGRect(x: center.x - labelWidth / 2, y: top,
                      width: labelWidth, height: labelHeight)
    }

    // MARK: - Lookup

    func node(_ id: UUID) -> BusMapNode? { nodes.first { $0.id == id } }

    /// The line between two stations, in either order — nil when the pair is not
    /// linked (a pulse with no line has nowhere to travel and is not drawn).
    func edge(between x: UUID, and y: UUID) -> BusMapEdge? {
        edges.first { $0.connects(x, y) }
    }
}

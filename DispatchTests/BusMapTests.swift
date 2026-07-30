// BusMapTests.swift
// The bus map's two testable halves: the PURE layout math
// (deterministic placement, component separation, isolated projects) and the
// pulse model (ring buffer, coalescing, reduce-motion path).
//
// The SwiftUI band itself is verified by the screenshot pass — but everything
// that could be silently wrong (a chain drawing a line it must not, a pulse
// surviving a project deletion, a ring buffer that grows forever) is here.

import Foundation
import Testing

@testable import DispatchApp

// MARK: - Fixtures

private enum Fix {
    static func ids(_ count: Int) -> [UUID] {
        (0..<count).map { index in
            UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", index))!
        }
    }

    static func link(_ a: UUID, _ b: UUID) -> ProjectLink {
        ProjectLink(a, b, createdAt: Date(timeIntervalSince1970: 0))
    }

    static func message(id: String = "q-1", from: UUID, to: UUID) -> BusMessage {
        BusMessage(id: id, from: from, to: to, subject: "s", body: "b",
                   askedAt: Date(timeIntervalSince1970: 0),
                   expiresAt: Date(timeIntervalSince1970: 86_400))
    }
}

// MARK: - Layout

@Suite("Bus map layout")
struct BusMapLayoutTests {

    @Test("no projects lays out nothing")
    func empty() {
        let layout = BusMapLayout(projectIDs: [], links: [])
        #expect(layout.nodes.isEmpty)
        #expect(layout.edges.isEmpty)
        #expect(layout.contentSize == .zero)
    }

    @Test("positions are deterministic — same input, same pixels")
    func deterministic() {
        let ids = Fix.ids(5)
        let links = [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        let first = BusMapLayout(projectIDs: ids, links: links)
        let second = BusMapLayout(projectIDs: ids, links: links)
        #expect(first == second)
        #expect(first.nodes.map(\.center) == second.nodes.map(\.center))
    }

    @Test("nodes come back in input order")
    func inputOrder() {
        let ids = Fix.ids(4)
        let layout = BusMapLayout(projectIDs: ids, links: [])
        #expect(layout.nodes.map(\.id) == ids)
    }

    @Test("an A–B–C chain links A–B and B–C but NEVER A–C")
    func chainIsNotABlob() {
        let ids = Fix.ids(3)
        let layout = BusMapLayout(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        )
        #expect(layout.edges.count == 2)
        #expect(layout.edge(between: ids[0], and: ids[1]) != nil)
        #expect(layout.edge(between: ids[1], and: ids[2]) != nil)
        #expect(layout.edge(between: ids[0], and: ids[2]) == nil)
        // All three are in ONE component, so none of them is isolated.
        #expect(layout.nodes.allSatisfy { !$0.isIsolated })
    }

    @Test("an edge is found in either order")
    func edgeIsUnordered() {
        let ids = Fix.ids(2)
        let layout = BusMapLayout(projectIDs: ids, links: [Fix.link(ids[1], ids[0])])
        #expect(layout.edge(between: ids[0], and: ids[1]) != nil)
        #expect(layout.edge(between: ids[1], and: ids[0]) != nil)
    }

    @Test("separate components sit side by side, never overlapping")
    func componentsAreSeparated() {
        let ids = Fix.ids(4)
        // Two disjoint pairs: 0–1 and 2–3.
        let layout = BusMapLayout(
            projectIDs: ids, links: [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3])]
        )
        let x = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.center.x) })
        let firstRight = max(x[ids[0]]!, x[ids[1]]!)
        let secondLeft = min(x[ids[2]]!, x[ids[3]]!)
        #expect(secondLeft - firstRight >= BusMapLayout.componentGap)
        // Different groups.
        let groups = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.groupIndex) })
        #expect(groups[ids[0]] == groups[ids[1]])
        #expect(groups[ids[2]] == groups[ids[3]])
        #expect(groups[ids[0]] != groups[ids[2]])
    }

    @Test("unlinked projects are marked isolated and pushed past the networks")
    func isolatedSitApart() {
        let ids = Fix.ids(4)
        // 0–1 linked; 2 and 3 alone.
        let layout = BusMapLayout(projectIDs: ids, links: [Fix.link(ids[0], ids[1])])
        let node = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0) })
        #expect(node[ids[0]]!.isIsolated == false)
        #expect(node[ids[1]]!.isIsolated == false)
        #expect(node[ids[2]]!.isIsolated)
        #expect(node[ids[3]]!.isIsolated)
        // Every isolated station is to the RIGHT of the linked network.
        let networkRight = max(node[ids[0]]!.center.x, node[ids[1]]!.center.x)
        #expect(node[ids[2]]!.center.x > networkRight)
        #expect(node[ids[3]]!.center.x > networkRight)
        // …and they share ONE trailing group rather than one gap each.
        #expect(node[ids[2]]!.groupIndex == node[ids[3]]!.groupIndex)
    }

    @Test("a lone project is isolated and the map is one cell wide")
    func singleProject() {
        let ids = Fix.ids(1)
        let layout = BusMapLayout(projectIDs: ids, links: [])
        #expect(layout.nodes.count == 1)
        #expect(layout.nodes[0].isIsolated)
        #expect(layout.edges.isEmpty)
        #expect(layout.contentSize.width == BusMapLayout.cellWidth)
        #expect(layout.contentSize.height == BusMapLayout.cellHeight)
    }

    @Test("a link naming a deleted project draws no line")
    func danglingLinkIsDropped() {
        let ids = Fix.ids(3)
        // ids[2] is NOT registered — the link to it must vanish.
        let layout = BusMapLayout(
            projectIDs: [ids[0], ids[1]],
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[1], ids[2])]
        )
        #expect(layout.edges.count == 1)
        #expect(layout.node(ids[2]) == nil)
    }

    @Test("a self-link and a duplicated row each draw at most one line")
    func degenerateLinks() {
        let ids = Fix.ids(2)
        let layout = BusMapLayout(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[0]),
                    Fix.link(ids[0], ids[1]),
                    Fix.link(ids[1], ids[0])]
        )
        #expect(layout.edges.count == 1)
    }

    @Test("a network wraps to a second row past the single-row limit")
    func wrapsToTwoRows() {
        let ids = Fix.ids(6)
        let links = (0..<5).map { Fix.link(ids[$0], ids[$0 + 1]) }
        let layout = BusMapLayout(projectIDs: ids, links: links)
        #expect(layout.contentSize.height == BusMapLayout.cellHeight * 2)
        #expect(Set(layout.nodes.map(\.center.y)).count == 2)
    }

    @Test("ten projects all get a placed, distinct station")
    func tenProjects() {
        let ids = Fix.ids(10)
        let links = [Fix.link(ids[0], ids[1]), Fix.link(ids[2], ids[3]),
                     Fix.link(ids[3], ids[4])]
        let layout = BusMapLayout(projectIDs: ids, links: links)
        #expect(layout.nodes.count == 10)
        #expect(Set(layout.nodes.map { "\($0.center.x),\($0.center.y)" }).count == 10)
        #expect(layout.contentSize.width > 0)
    }

    @Test("duplicate project ids are placed once")
    func duplicatesIgnored() {
        let ids = Fix.ids(2)
        let layout = BusMapLayout(projectIDs: [ids[0], ids[1], ids[0]], links: [])
        #expect(layout.nodes.count == 2)
    }
}

// MARK: - Hub ordering + arc routing

/// The map used to be able to draw a topology that does not exist: stations sat
/// in raw input order and every line was a straight segment UNDER the opaque
/// tiles, so a link spanning a station vanished behind it and read as a chain.
/// Two guarantees are asserted here — the hub sits between its leaves, and any
/// line that still spans a station goes OVER it.
@Suite("Bus map hub ordering and arcs")
struct BusMapRoutingTests {

    /// True when no line passes behind a station: nothing arcs, because nothing
    /// needed to.
    private func spanningEdges(_ layout: BusMapLayout) -> [BusMapEdge] {
        layout.edges.filter(\.isArc)
    }

    @Test("the real dogfood case: the hub lands BETWEEN its two leaves")
    func hubBetweenLeaves() {
        // Two leaves (0 and 1) both link to the hub (2); the leaves are NOT
        // linked to each other. In input order the 0–2 line ran straight
        // through 1's tile.
        let ids = Fix.ids(3)
        let layout = BusMapLayout(
            projectIDs: ids, links: [Fix.link(ids[0], ids[2]), Fix.link(ids[1], ids[2])]
        )
        let x = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.center.x) })
        let hub = x[ids[2]]!
        #expect(min(x[ids[0]]!, x[ids[1]]!) < hub)
        #expect(hub < max(x[ids[0]]!, x[ids[1]]!))
        // Both edges now join grid NEIGHBOURS, so nothing has to arc.
        #expect(spanningEdges(layout).isEmpty)
        #expect(layout.edges.allSatisfy { abs($0.from.x - $0.to.x) == BusMapLayout.cellWidth })
    }

    @Test("a 4-station star centres the hub and arcs the one edge that must span")
    func fourStationStar() {
        // 0 is the hub; 1, 2, 3 hang off it. A row can seat the hub next to at
        // most two leaves, so exactly one edge has to travel over a station.
        let ids = Fix.ids(4)
        let layout = BusMapLayout(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[0], ids[2]),
                    Fix.link(ids[0], ids[3])]
        )
        let x = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.center.x) })
        let hub = x[ids[0]]!
        // The hub is interior: leaves on both sides of it.
        #expect(x.values.contains { $0 < hub })
        #expect(x.values.contains { $0 > hub })
        let arcs = spanningEdges(layout)
        #expect(arcs.count == 1)
        // The arc bows UP — above the row, clear of the tiles, and never below
        // where the station names hang.
        let arc = arcs[0]
        let apex = arc.point(at: 0.5)
        #expect(apex.y < arc.from.y - BusMapLayout.stationTile / 2)
        #expect(apex.y >= BusMapLayout.arcTopInset - 1)
    }

    @Test("a straight edge stays straight and its midpoint is the plain midpoint")
    func straightEdgeIsStraight() {
        let ids = Fix.ids(2)
        let layout = BusMapLayout(projectIDs: ids, links: [Fix.link(ids[0], ids[1])])
        let edge = layout.edge(between: ids[0], and: ids[1])!
        #expect(!edge.isArc)
        #expect(edge.point(at: 0) == edge.from)
        #expect(edge.point(at: 1) == edge.to)
        #expect(edge.point(at: 0.5).y == edge.from.y)
    }

    @Test("the pulse rides the ARC, not the chord it was routed around")
    func pulseFollowsTheArc() {
        let ids = Fix.ids(4)
        let layout = BusMapLayout(
            projectIDs: ids,
            links: [Fix.link(ids[0], ids[1]), Fix.link(ids[0], ids[2]),
                    Fix.link(ids[0], ids[3])]
        )
        let arc = layout.edges.first(where: \.isArc)!
        // Ends are exact; everything in between is lifted off the straight line.
        #expect(arc.point(at: 0) == arc.from)
        #expect(arc.point(at: 1) == arc.to)
        #expect(arc.point(at: 0.5).y < arc.from.y)
        #expect(arc.point(at: 0.25).y < arc.from.y)
        // Orienting the edge for travel keeps the same curve, just walked the
        // other way: the dot's path can't depend on who asked whom.
        let reversed = arc.oriented(from: arc.b)
        #expect(reversed.from == arc.to)
        #expect(reversed.control == arc.control)
        #expect(reversed.point(at: 0.5) == arc.point(at: 0.5))
        #expect(arc.oriented(from: arc.a) == arc)
    }

    @Test("hub ordering is deterministic and does not depend on link order")
    func deterministicOrdering() {
        let ids = Fix.ids(5)
        let links = [Fix.link(ids[0], ids[3]), Fix.link(ids[1], ids[3]),
                     Fix.link(ids[2], ids[3]), Fix.link(ids[3], ids[4])]
        let forward = BusMapLayout(projectIDs: ids, links: links)
        let backward = BusMapLayout(projectIDs: ids, links: links.reversed())
        #expect(forward == backward)
        #expect(forward.nodes.map(\.center) == backward.nodes.map(\.center))
        // Repeated derivation is identical too — the map never reshuffles.
        #expect(forward == BusMapLayout(projectIDs: ids, links: links))
    }

    @Test("a chain still reads left to right after hub ordering")
    func chainStaysAChain() {
        let ids = Fix.ids(4)
        let links = (0..<3).map { Fix.link(ids[$0], ids[$0 + 1]) }
        let layout = BusMapLayout(projectIDs: ids, links: links)
        let x = Dictionary(uniqueKeysWithValues: layout.nodes.map { ($0.id, $0.center.x) })
        // Every hop is one cell — a path graph needs no arc at all.
        #expect(spanningEdges(layout).isEmpty)
        #expect(abs(x[ids[0]]! - x[ids[1]]!) == BusMapLayout.cellWidth)
        #expect(abs(x[ids[1]]! - x[ids[2]]!) == BusMapLayout.cellWidth)
        #expect(abs(x[ids[2]]! - x[ids[3]]!) == BusMapLayout.cellWidth)
    }

    @Test("unlinked projects keep their input order")
    func unlinkedKeepInputOrder() {
        let ids = Fix.ids(4)
        let layout = BusMapLayout(projectIDs: ids, links: [])
        let xs = layout.nodes.map(\.center.x)
        #expect(xs == xs.sorted())
    }

    // MARK: - The property: no line is ever drawn through a name

    /// Every topology worth laying out, named so a failure says which shape
    /// broke. Each is (projects, links).
    nonisolated static let topologies: [(name: String, count: Int, links: [(Int, Int)])] = [
        ("a single pair", 2, [(0, 1)]),
        ("a chain of four", 4, [(0, 1), (1, 2), (2, 3)]),
        ("a four-station star", 4, [(0, 1), (0, 2), (0, 3)]),
        // Six in ONE component is the case that wraps to two rows — the one the
        // old test asserted could never need routing.
        ("a six-station star, two rows", 6, [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5)]),
        ("a six-station chain, two rows", 6, [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5)]),
        ("two separate components", 6, [(0, 1), (1, 2), (3, 4), (4, 5)]),
        ("a component beside three loners", 6, [(0, 1), (1, 2)]),
        ("ten projects, one dense network", 10,
         [(0, 1), (0, 2), (0, 3), (0, 4), (0, 5), (0, 6), (0, 7), (0, 8), (0, 9),
          (1, 2), (3, 4), (5, 6), (7, 8)]),
        ("ten projects, a long chain", 10,
         [(0, 1), (1, 2), (2, 3), (3, 4), (4, 5), (5, 6), (6, 7), (7, 8), (8, 9)]),
    ]

    private func layout(_ topology: (name: String, count: Int, links: [(Int, Int)]))
        -> BusMapLayout {
        let ids = Fix.ids(topology.count)
        return BusMapLayout(projectIDs: ids,
                            links: topology.links.map { Fix.link(ids[$0.0], ids[$0.1]) })
    }

    /// THE invariant. Not "cross-row edges don't arc" — that was
    /// the old test restating the bug's own assumption, while the diagonals it
    /// blessed ran straight through the hub's name. What actually matters is
    /// that nothing drawn lands in text, whichever way the router gets there.
    ///
    /// The curve is SAMPLED rather than solved: every edge is walked at a
    /// fraction of a point per step, which is finer than any label box by two
    /// orders of magnitude.
    @Test("no drawn line ever passes through a station's label",
          arguments: BusMapRoutingTests.topologies.indices)
    func noEdgeCrossesALabel(_ index: Int) {
        let topology = Self.topologies[index]
        let layout = layout(topology)
        let labels = layout.nodes.map(\.labelRect)
        #expect(!layout.edges.isEmpty, "\(topology.name): nothing to check")
        for edge in layout.edges {
            let steps = 2_000
            for step in 0...steps {
                let point = edge.point(at: CGFloat(step) / CGFloat(steps))
                if let hit = labels.firstIndex(where: { $0.contains(point) }) {
                    Issue.record("""
                        \(topology.name): an edge passes through station \(hit)'s \
                        label \(labels[hit]) at \(point)
                        """)
                    return
                }
            }
        }
    }

    @Test("every drawn line stays inside the content box",
          arguments: BusMapRoutingTests.topologies.indices)
    func edgesStayInTheBox(_ index: Int) {
        let topology = Self.topologies[index]
        let layout = layout(topology)
        for edge in layout.edges {
            for step in 0...200 {
                let point = edge.point(at: CGFloat(step) / 200)
                #expect(point.y >= 0, "\(topology.name): clipped off the top")
                #expect(point.y <= layout.contentSize.height,
                        "\(topology.name): clipped off the bottom")
            }
        }
    }

    /// The labels themselves have to fit too, or the fix would just have moved
    /// the clipping from the lines to the names.
    @Test("every label box stays inside the content box",
          arguments: BusMapRoutingTests.topologies.indices)
    func labelsStayInTheBox(_ index: Int) {
        let layout = layout(Self.topologies[index])
        for node in layout.nodes {
            #expect(node.labelRect.minY >= 0)
            #expect(node.labelRect.maxY <= layout.contentSize.height)
        }
    }

    @Test("the property survives relayout — same input, same clean picture")
    func propertyIsDeterministic() {
        for topology in Self.topologies {
            #expect(layout(topology) == layout(topology))
        }
    }

    @Test("a two-row group puts the top row's names above and the bottom row's below")
    func twoRowLabelSides() {
        let layout = layout(Self.topologies[3])           // six-station star
        #expect(layout.contentSize.height == BusMapLayout.cellHeight * 2)
        let rows = Dictionary(grouping: layout.nodes, by: \.center.y)
        #expect(rows.count == 2)
        let topY = rows.keys.min()!
        for node in layout.nodes {
            #expect(node.labelAbove == (node.center.y == topY))
        }
        // Cross-row lines exist and are STRAIGHT — the corridor they run in has
        // no text left in it, so there is nothing to route around.
        let crossRow = layout.edges.filter { $0.from.y != $0.to.y }
        #expect(!crossRow.isEmpty)
        #expect(crossRow.allSatisfy { !$0.isArc })
        // And the top row's arcs bow DOWN into that same corridor, away from
        // the names now sitting above them.
        let topArcs = layout.edges.filter { $0.isArc && $0.from.y == topY }
        for arc in topArcs { #expect(arc.point(at: 0.5).y > topY) }
    }

    @Test("a one-row group is unchanged: names below, arcs up")
    func oneRowIsUnchanged() {
        let layout = layout(Self.topologies[2])           // four-station star
        #expect(layout.nodes.allSatisfy { !$0.labelAbove })
        let arcs = layout.edges.filter(\.isArc)
        #expect(arcs.count == 1)
        #expect(arcs[0].point(at: 0.5).y < arcs[0].from.y)
    }

    @Test("arcControl ignores stations that are not between the ends")
    func arcControlBounds() {
        let left = CGPoint(x: 50, y: 40)
        let right = CGPoint(x: 150, y: 40)
        // Nothing in between.
        #expect(BusMapLayout.arcControl(from: left, to: right,
                                        stations: [left, right, CGPoint(x: 250, y: 40)]) == nil)
        // A station on another ROW is not in the way.
        #expect(BusMapLayout.arcControl(from: left, to: right,
                                        stations: [CGPoint(x: 100, y: 120)]) == nil)
        // A station between the ends, same row → arc.
        let control = BusMapLayout.arcControl(from: left, to: right,
                                              stations: [CGPoint(x: 100, y: 40)])
        #expect(control?.x == 100)
        #expect(control!.y < 40)
        // A positive rise bows the other way, for a row whose names are above.
        let down = BusMapLayout.arcControl(from: left, to: right,
                                           stations: [CGPoint(x: 100, y: 40)],
                                           rise: BusMapLayout.arcRise)
        #expect(down!.y > 40)
    }
}

// MARK: - Pulse model

@Suite("Bus map pulses")
struct BusPulseModelTests {

    private static let now = Date(timeIntervalSince1970: 1_000)

    @Test("an ask pulses from the asker to the asked")
    func askDirection() {
        let ids = Fix.ids(2)
        let pulse = BusPulseStore.pulse(
            for: .asked(Fix.message(from: ids[0], to: ids[1])), at: Self.now
        )
        #expect(pulse?.from == ids[0])
        #expect(pulse?.to == ids[1])
        #expect(pulse?.kind == .asked)
    }

    @Test("an answer pulses BACK — from the asked project to the asker")
    func answerDirection() {
        let ids = Fix.ids(2)
        let pulse = BusPulseStore.pulse(
            for: .answered(Fix.message(from: ids[0], to: ids[1])), at: Self.now
        )
        #expect(pulse?.from == ids[1])
        #expect(pulse?.to == ids[0])
        #expect(pulse?.kind == .answered)
    }

    @Test("events with no line to travel produce no pulse")
    func silentEvents() {
        let ids = Fix.ids(2)
        #expect(BusPulseStore.pulse(
            for: .closed(Fix.message(from: ids[0], to: ids[1])), at: Self.now) == nil)
        #expect(BusPulseStore.pulse(for: .connected(projectID: ids[0]), at: Self.now) == nil)
        #expect(BusPulseStore.pulse(for: .disconnected(projectID: ids[0]), at: Self.now) == nil)
    }

    @Test("the ring buffer never grows past capacity, dropping the oldest")
    func ringBuffer() {
        let ids = Fix.ids(2)
        var buffer: [BusPulse] = []
        let total = BusPulseStore.capacity + 3
        for index in 0..<total {
            let pulse = BusPulseStore.pulse(
                for: .asked(Fix.message(id: "q-\(index)", from: ids[0], to: ids[1])),
                at: Self.now
            )!
            buffer = BusPulseStore.appending(pulse, to: buffer)
        }
        #expect(buffer.count == BusPulseStore.capacity)
        // The survivors are the NEWEST ones.
        #expect(buffer.first?.messageID == "q-\(total - BusPulseStore.capacity)")
        #expect(buffer.last?.messageID == "q-\(total - 1)")
    }

    @Test("the same message on the same leg coalesces inside the window")
    func coalesces() {
        let ids = Fix.ids(2)
        let event = BusEvent.answered(Fix.message(id: "q-dup", from: ids[0], to: ids[1]))
        let first = BusPulseStore.pulse(for: event, at: Self.now)!
        let again = BusPulseStore.pulse(
            for: event, at: Self.now.addingTimeInterval(BusPulseStore.coalesceWindow / 2)
        )!
        let buffer = BusPulseStore.appending(again, to: [first])
        #expect(buffer.count == 1)
        #expect(buffer[0].id == first.id)
    }

    @Test("the same message past the window pulses again")
    func coalesceWindowExpires() {
        let ids = Fix.ids(2)
        let event = BusEvent.asked(Fix.message(id: "q-dup", from: ids[0], to: ids[1]))
        let first = BusPulseStore.pulse(for: event, at: Self.now)!
        let later = BusPulseStore.pulse(
            for: event, at: Self.now.addingTimeInterval(BusPulseStore.coalesceWindow + 1)
        )!
        #expect(BusPulseStore.appending(later, to: [first]).count == 2)
    }

    @Test("an ask and its answer are two pulses, not one")
    func askAndAnswerBothShow() {
        let ids = Fix.ids(2)
        let message = Fix.message(id: "q-1", from: ids[0], to: ids[1])
        let asked = BusPulseStore.pulse(for: .asked(message), at: Self.now)!
        let answered = BusPulseStore.pulse(for: .answered(message), at: Self.now)!
        #expect(BusPulseStore.appending(answered, to: [asked]).count == 2)
    }

    @Test("Reduce Motion picks the line highlight, everyone else the dot")
    func reduceMotionPath() {
        #expect(BusPulseStore.rendering(reduceMotion: true) == .lineHighlight)
        #expect(BusPulseStore.rendering(reduceMotion: false) == .travellingDot)
    }
}

@MainActor
@Suite("Bus pulse store")
struct BusPulseStoreTests {

    @Test("recording an ask puts one pulse in flight")
    func recordsAsk() {
        let ids = Fix.ids(2)
        let store = BusPulseStore()
        #expect(store.record(.asked(Fix.message(from: ids[0], to: ids[1]))) != nil)
        #expect(store.pulses.count == 1)
    }

    @Test("a coalesced repeat reports nothing new and adds nothing")
    func coalescedRecordReturnsNil() {
        let ids = Fix.ids(2)
        let store = BusPulseStore()
        let event = BusEvent.answered(Fix.message(id: "q-x", from: ids[0], to: ids[1]))
        let now = Date()
        #expect(store.record(event, at: now) != nil)
        #expect(store.record(event, at: now) == nil)
        #expect(store.pulses.count == 1)
    }

    @Test("a silent event leaves the buffer empty")
    func silentEventRecordsNothing() {
        let ids = Fix.ids(1)
        let store = BusPulseStore()
        #expect(store.record(.connected(projectID: ids[0])) == nil)
        #expect(store.pulses.isEmpty)
    }

    @Test("pruning drops pulses whose project was deleted")
    func pruneAfterDeletion() {
        let ids = Fix.ids(3)
        let store = BusPulseStore()
        store.record(.asked(Fix.message(id: "q-a", from: ids[0], to: ids[1])))
        store.record(.asked(Fix.message(id: "q-b", from: ids[0], to: ids[2])))
        #expect(store.pulses.count == 2)
        // ids[2] is deleted mid-flight.
        store.prune(knownProjectIDs: [ids[0], ids[1]])
        #expect(store.pulses.count == 1)
        #expect(store.pulses[0].messageID == "q-a")
    }

    @Test("the app's one bus fan-out feeds the map")
    func appStoresFanOut() {
        let stores = AppStores.mock()
        let message = Fix.message(id: "q-fan", from: MockData.ID.ledgerline,
                                  to: MockData.ID.driftwood)
        stores.handle(busEvent: .answered(message))
        #expect(stores.busPulses.pulses.count == 1)
        #expect(stores.busPulses.pulses[0].from == MockData.ID.driftwood)
    }
}

// MARK: - Band copy

@Suite("Bus map band")
struct BusMapSectionTests {

    @Test("the header prompts when nothing is linked")
    func noLinksCaption() {
        #expect(BusMapSection.caption(projectCount: 3, linkCount: 0)
                == "3 projects · nothing linked yet")
    }

    @Test("the header counts links, singular and plural")
    func linkCaption() {
        #expect(BusMapSection.caption(projectCount: 3, linkCount: 1)
                == "3 projects · 1 link")
        #expect(BusMapSection.caption(projectCount: 4, linkCount: 2)
                == "4 projects · 2 links")
    }

    @Test("a line announces both ends, and survives a deleted one")
    func lineLabel() {
        #expect(BusMapView.lineLabel(from: "Ledgerline", to: "Driftwood")
                == "Ledgerline linked to Driftwood")
        #expect(BusMapView.lineLabel(from: nil, to: "Driftwood")
                == "A deleted project linked to Driftwood")
    }
}

// BusMapView.swift
// The bus map — the switchboard, drawn. Stations are PROJECTS,
// lines are the `projectLink` rows that let two of them talk, and a dot runs the
// line every time a question or an answer actually crosses it.
//
// The four things a station has to answer, matching the rail card so the two
// surfaces never disagree:
//   WHO      — the tinted initial tile + the project's name.
//   REACHABLE— the live dot: filled + blinking while that repo's own session is
//              on the bus, a hollow ring when it is not.
//   SET UP   — an amber ring when the repo's `.mcp.json` has no live `dispatch`
//              entry. Same amber, same meaning as the card's chip.
//   IN SCOPE — an unlinked project is dimmed and sits apart. It can neither ask
//              nor be asked, and the map should say so at a glance.
//
// Clicking a station selects that project in the RAIL — one selection state, two
// views of it. There is no drag and no zoom: the map is a status surface, not a
// canvas, and a graph you can shove around stops being a reference.
//
// ACCESSIBILITY: every signal here is color or position, so both are spoken.
// A station announces name + connection + links + pending count; each line is
// its own element announcing "X linked to Y". The pulses are decorative — the
// ticker already says what happened in words — so they are hidden, and Reduce
// Motion swaps the travelling dot for a brief line highlight.

import AppKit
import SwiftUI

struct BusMapView: View {
    @Environment(AppStores.self) private var stores
    @Environment(Theme.self) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        let layout = BusMapLayout(clusters: ProjectClusters(
            projectIDs: stores.projects.projects.map(\.id),
            links: stores.crossProject.links
        ))
        // The SELECTION SCOPE: the cluster the selected project
        // belongs to. Everything outside it dims — other networks and every
        // unlinked project — so the map answers "what is in play right now"
        // without hiding anything. nil (no selection, or a selection that isn't
        // registered) means nothing dims: an unscoped map is the full map.
        //
        // NO FEEDBACK CYCLE: clicking a station calls `select`, which is a
        // no-op when the id is already selected; the selection change re-runs
        // this body and the highlight follows. Nothing here writes selection.
        let focus = layout.clusters.clusterSet(containing: stores.projects.selectedProjectID)
        let band = bandHeight(for: layout)
        // A map narrower than the band CENTERS rather than hugging the left
        // edge — two stations pinned to the corner of a 1000pt panel read as a
        // rendering accident, not a diagram. Wider than the band, it scrolls.
        GeometryReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                ZStack(alignment: .topLeading) {
                    // Lines UNDER the stations: the opaque tiles trim the line
                    // ends for free, so no endpoint inset math is needed.
                    ForEach(layout.edges) { edge in
                        line(edge, layout: layout, focus: focus)
                    }
                    ForEach(pulses(in: layout), id: \.pulse.id) { entry in
                        pulse(entry.pulse, on: entry.edge)
                    }
                    ForEach(layout.nodes) { node in
                        station(node, focus: focus)
                    }
                }
                .frame(width: max(layout.contentSize.width, 1),
                       height: max(layout.contentSize.height, 1),
                       alignment: .topLeading)
                .padding(.horizontal, 12)
                .frame(minWidth: max(proxy.size.width, 1), alignment: .center)
                // Centered in the band's height, so the stations don't ride
                // its top edge with all the slack below the labels.
                .frame(height: band, alignment: .center)
            }
        }
        .frame(height: band)
    }

    /// One row of stations or two — the band grows only when a network actually
    /// needs the second row, so the common 2–4 project case stays compact.
    private func bandHeight(for layout: BusMapLayout) -> CGFloat {
        layout.contentSize.height > BusMapLayout.cellHeight
            ? Metrics.busMapBandHeightTall
            : Metrics.busMapBandHeight
    }

    // MARK: - Lines

    private func line(_ edge: BusMapEdge, layout: BusMapLayout, focus: Set<UUID>?)
        -> some View {
        let lit = isLit(edge)
        // A line belongs to exactly one cluster (both ends share it), so testing
        // either end is enough — but test both, so a mid-flight delete can never
        // leave a half-focused line.
        let inScope = Self.isInScope(edge.a, focus) && Self.isInScope(edge.b, focus)
        return Path { path in
            path.move(to: edge.from)
            // An edge that would otherwise pass BEHIND a station arcs over the
            // row instead, so the map can never draw a connection
            // through a project that isn't part of it.
            if let control = edge.control {
                path.addQuadCurve(to: edge.to, control: control)
            } else {
                path.addLine(to: edge.to)
            }
        }
        .stroke(
            lit ? theme.accent : Ink.faint.opacity(0.5),
            style: StrokeStyle(lineWidth: lit ? Metrics.busMapLineWidth + 1
                                              : Metrics.busMapLineWidth,
                               lineCap: .round)
        )
        .opacity(inScope ? 1 : Metrics.busMapLineOutOfScope)
        .animation(Motion.busPulseHighlight, value: lit)
        .animation(Motion.state, value: inScope)
        .accessibilityElement()
        .accessibilityLabel(Self.lineLabel(
            from: stores.projects.project(id: edge.a)?.name,
            to: stores.projects.project(id: edge.b)?.name
        ))
    }

    /// Under Reduce Motion a pulse lights its whole LINE instead of moving a dot
    /// along it — the same fact, held still.
    private func isLit(_ edge: BusMapEdge) -> Bool {
        guard BusPulseStore.rendering(reduceMotion: reduceMotion) == .lineHighlight
        else { return false }
        return stores.busPulses.pulses.contains { edge.connects($0.from, $0.to) }
    }

    // MARK: - Pulses

    /// Pulses that have a line to travel. A pulse whose pair is no longer linked
    /// — or whose project was just deleted — resolves to no edge and draws
    /// nothing, rather than flying across empty space.
    private func pulses(in layout: BusMapLayout) -> [(pulse: BusPulse, edge: BusMapEdge)] {
        guard BusPulseStore.rendering(reduceMotion: reduceMotion) == .travellingDot
        else { return [] }
        return stores.busPulses.pulses.compactMap { pulse in
            guard let edge = layout.edge(between: pulse.from, and: pulse.to) else { return nil }
            // Orient the edge for TRAVEL — the layout's edge is canonical, the
            // pulse knows which way the message actually went. Orienting keeps
            // the layout's routing (straight or arc), so the dot rides exactly
            // the line that is drawn.
            return (pulse, edge.oriented(from: pulse.from))
        }
    }

    private func pulse(_ pulse: BusPulse, on edge: BusMapEdge) -> some View {
        BusMapPulseDot(
            edge: edge,
            tint: pulse.kind == .asked ? theme.accent : Status.successDot
        )
        .id(pulse.id)
    }

    // MARK: - Stations

    private func station(_ node: BusMapNode, focus: Set<UUID>?) -> some View {
        let project = stores.projects.project(id: node.id)
        return BusMapStationView(
            name: project?.name ?? "—",
            icon: stores.icons.icon(for: node.id),
            connection: stores.connection(for: node.id),
            installState: stores.repoInstallStates[node.id],
            isSelected: stores.projects.selectedProjectID == node.id,
            isIsolated: node.isIsolated,
            isOutOfScope: !Self.isInScope(node.id, focus),
            linkedPeerNames: stores.linkedPeerNames(of: node.id),
            pendingCount: stores.attentionCount(for: node.id),
            labelAbove: node.labelAbove,
            onSelect: { stores.projects.select(node.id) }
        )
        // The tile sits ON the node center; the name hangs off it, so the
        // composed view is offset by exactly half the label's vertical run —
        // the direction depends on which side the layout put the name.
        .position(node.viewCenter)
    }

    // MARK: - Pure copy (testable)

    static func lineLabel(from: String?, to: String?) -> String {
        "\(from ?? "A deleted project") linked to \(to ?? "a deleted project")"
    }

    /// With no selection scope (`focus == nil`) EVERYTHING is in scope — the
    /// map never dims itself into uselessness just because nothing is selected.
    static func isInScope(_ id: UUID, _ focus: Set<UUID>?) -> Bool {
        guard let focus else { return true }
        return focus.contains(id)
    }
}

// MARK: - Station

private struct BusMapStationView: View {
    @Environment(Theme.self) private var theme

    let name: String
    /// The repo's discovered app icon / favicon. nil → letter tile.
    let icon: NSImage?
    let connection: AppStores.ProjectConnection
    let installState: RepoMCPConfig.InstallState?
    let isSelected: Bool
    let isIsolated: Bool
    /// Outside the selected project's cluster. Same dim as
    /// `isIsolated`, different reason — and it is NOT spoken, because unlike
    /// "off the network" it is a transient view state driven by the reader's own
    /// selection, not a fact about the project.
    let isOutOfScope: Bool
    let linkedPeerNames: [String]
    let pendingCount: Int
    /// The name goes ABOVE the tile — the top row of a two-row group, so the
    /// corridor the cross-row lines run through holds no text (BusMapLayout).
    let labelAbove: Bool
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(spacing: BusMapLayout.labelSpacing) {
                if labelAbove { label }
                tile
                if !labelAbove { label }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // An unlinked project is inert on the bus; dimming is the honest face of
        // that, and the a11y label below says it out loud. A station outside the
        // selected cluster dims by the SAME amount — one "not in play" look.
        .opacity(isIsolated || isOutOfScope ? Metrics.busMapOutOfScope : 1)
        .animation(Motion.state, value: isOutOfScope)
        .help(helpText)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(BusMapStationView.accessibilityLabel(
            name: name, connection: connection, linkedPeerNames: linkedPeerNames,
            pendingCount: pendingCount, isSelected: isSelected
        ))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private var label: some View {
        Text(name)
            .textStyle(TextStyle(TypeScale.ui(10.5, isSelected ? .semibold : .regular)))
            .foregroundStyle(isSelected ? Ink.primary : Ink.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(width: BusMapLayout.labelWidth, height: BusMapLayout.labelHeight)
    }

    private var tile: some View {
        ProjectIconTile(
            icon: icon, name: name, size: BusMapLayout.stationTile,
            cornerRadius: Metrics.busMapStationRadius, letterSize: 15
        )
            .overlay {
                RoundedRectangle(cornerRadius: Metrics.busMapStationRadius, style: .continuous)
                    .strokeBorder(ringColor, lineWidth: ringWidth)
            }
            // Selection reads as a lift, not just a ring — the rail card does
            // the same, so the two selected states rhyme.
            .shadow(color: isSelected ? theme.accentTint(0.35) : .clear, radius: 6)
            .overlay(alignment: .topTrailing) {
                liveDot.offset(x: 3, y: -3)
            }
    }

    @ViewBuilder
    private var liveDot: some View {
        if connection.isConnected {
            Circle()
                .fill(Status.successDot)
                .frame(width: Metrics.busMapLiveDot, height: Metrics.busMapLiveDot)
                .overlay(Circle().strokeBorder(Surface.white, lineWidth: 1))
                .accessibilityHidden(true)
                .workingDotsBlink()
        } else {
            Circle()
                .fill(Surface.white)
                .overlay(Circle().strokeBorder(Ink.faint, lineWidth: 1))
                .frame(width: Metrics.busMapLiveDot, height: Metrics.busMapLiveDot)
                .accessibilityHidden(true)
        }
    }

    /// Selected wins the ring; otherwise an unfinished `.mcp.json` shows the
    /// same amber the card's chip uses. An installed, unselected station is
    /// quiet — no ring at all.
    private var ringColor: Color {
        if isSelected { return theme.accent }
        return needsAttention ? Status.warningDot : .clear
    }

    private var ringWidth: CGFloat { isSelected ? 2 : (needsAttention ? 1.5 : 0) }

    /// Every install state except `.installed` (and "not evaluated yet") means
    /// that repo's session cannot reach the bus.
    private var needsAttention: Bool {
        switch installState {
        case .installed, nil: false
        case .missing, .stale, .conflict, .invalid: true
        }
    }

    private var helpText: String {
        BusMapStationView.accessibilityLabel(
            name: name, connection: connection, linkedPeerNames: linkedPeerNames,
            pendingCount: pendingCount, isSelected: isSelected
        )
    }

    /// The station's spoken summary. Nothing here is available by sight alone.
    static func accessibilityLabel(
        name: String, connection: AppStores.ProjectConnection,
        linkedPeerNames: [String], pendingCount: Int, isSelected: Bool,
        now: Date = Date()
    ) -> String {
        var parts = [name]
        if isSelected { parts.append("selected") }
        parts.append(ProjectCardView.connectionLabel(connection, now: now))
        parts.append(linkedPeerNames.isEmpty
                     ? "not linked to any project"
                     : "linked to \(linkedPeerNames.joined(separator: ", "))")
        if pendingCount > 0 {
            parts.append("\(pendingCount) questions awaiting an answer")
        }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Pulse dot

/// One travelling dot. Lives in its OWN view so each pulse gets FRESH @State —
/// the animation therefore starts from the line's origin every time, with no
/// timer to arm and nothing to reset. CoreAnimation drives the move, so no frame
/// loop runs, and none runs at all while the band is collapsed: this view is
/// simply not in the tree.
///
/// It interpolates PROGRESS rather than the position directly: interpolating
/// `.position` only ever produces a straight line, which was fine while every
/// edge was straight but would have cut the dot straight through the station an
/// arc was routed around. `BusMapEdge.point(at:)` is the one definition of where
/// the line goes, and both the stroke and this dot come from it.
private struct BusMapPulseDot: View {
    let edge: BusMapEdge
    let tint: Color

    @State private var arrived = false

    var body: some View {
        Circle()
            .fill(tint)
            .frame(width: Metrics.busMapPulseDot, height: Metrics.busMapPulseDot)
            .shadow(color: tint.opacity(0.5), radius: 4)
            .modifier(AlongEdge(edge: edge, progress: arrived ? 1 : 0))
            .animation(Motion.busPulseTravel, value: arrived)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear { arrived = true }
    }

    /// Positions its content at `progress` along the edge. `Animatable` on the
    /// scalar is what makes CoreAnimation walk the CURVE: it interpolates the
    /// single number and asks the edge for the point each frame.
    private struct AlongEdge: ViewModifier, Animatable {
        let edge: BusMapEdge
        var progress: CGFloat

        var animatableData: CGFloat {
            get { progress }
            set { progress = newValue }
        }

        func body(content: Content) -> some View {
            let point = edge.point(at: progress)
            return content.position(x: point.x, y: point.y)
        }
    }
}

#Preview("Bus map — mock scenario") {
    let stores = AppStores.mock()
    BusMapView()
        .environment(Theme())
        .environment(stores)
        .frame(width: 720)
        .background(Surface.white)
        .task { await stores.activate() }
}

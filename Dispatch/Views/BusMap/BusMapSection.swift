// BusMapSection.swift
// The bus map's home on the workbench: a collapsible band at the
// TOP of the center pane, directly above the Messages inbox.
//
// WHY HERE AND NOT A TAB: the map answers "who can talk to whom, and is anything
// moving" — which is the question you have WHILE reading the inbox, not instead
// of it. A tab would make the map a place you go; a band makes it a thing you
// glance at. It collapses to a single header strip, and that choice persists.
//
// WHEN IT HIDES: with fewer than two projects there is no graph — one station
// and no lines is a diagram of nothing, and the rail already shows that project
// better. The section disappears entirely rather than rendering a lonely dot.
// Two or more projects with NO links still render: "nothing is connected" is
// exactly the state the map exists to make obvious, and the caption says so.

import Defaults
import SwiftUI

extension Defaults.Keys {
    /// Whether the bus map band is collapsed to its header. Persisted so the
    /// human's choice survives a relaunch.
    static let busMapCollapsed = Key<Bool>("busMapCollapsed", default: false)
}

struct BusMapSection: View {
    @Environment(AppStores.self) private var stores
    @Environment(Theme.self) private var theme
    @Default(.busMapCollapsed) private var collapsed

    var body: some View {
        if stores.projects.projects.count >= 2 {
            VStack(alignment: .leading, spacing: 6) {
                header
                if !collapsed {
                    BusMapView()
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.radiusPanel,
                                             style: .continuous)
                                .fill(Surface.white)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Metrics.radiusPanel,
                                             style: .continuous)
                                .strokeBorder(Surface.hairline)
                        )
                        .cardShadow()
                }
            }
            .padding(.horizontal, Metrics.surfacePadding)
            .padding(.top, 6)
        }
    }

    private var header: some View {
        Button {
            withAnimation(Motion.rise) { collapsed.toggle() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .textStyle(TextStyle(TypeScale.ui(9, .bold)))
                    .rotationEffect(.degrees(collapsed ? 0 : 90))
                    .accessibilityHidden(true)
                Text("BUS MAP")
                    .textStyle(TypeScale.sectionLabel)
                Text(caption)
                    .textStyle(TypeScale.monoTiny)
                    .foregroundStyle(Ink.faint)
                Spacer(minLength: 0)
            }
            .foregroundStyle(Ink.tertiary)
            .frame(height: Metrics.busMapHeaderHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(collapsed ? "Show the bus map" : "Hide the bus map")
        .accessibilityLabel("Bus map, \(caption)")
        .accessibilityHint(collapsed ? "Expands the map" : "Collapses the map")
        .accessibilityAddTraits(collapsed ? [] : .isSelected)
    }

    private var caption: String {
        Self.caption(projectCount: stores.projects.projects.count,
                     linkCount: linkCount)
    }

    /// The number of LINES the map draws — not the number of `projectLink`
    /// rows.
    ///
    /// The two differ. `ProjectClusters` normalises each row to an unordered
    /// pair, so `A→B` and `B→A` — two perfectly ordinary rows, since either end
    /// can be the one that linked — collapse into ONE drawn line, as does a
    /// duplicate row. Counting rows made the header say "2 links" over a map
    /// showing one, which is the header calling the picture a liar. Asking the
    /// same union-find the map is laid out from means they cannot disagree;
    /// dropping links whose ends are no longer registered comes free with it.
    private var linkCount: Int {
        Self.drawnLinkCount(projectIDs: stores.projects.projects.map(\.id),
                            links: stores.crossProject.links)
    }

    /// Pure, so the agreement between caption and picture is a unit test rather
    /// than a screenshot.
    static func drawnLinkCount(projectIDs: [UUID], links: [ProjectLink]) -> Int {
        ProjectClusters(projectIDs: projectIDs, links: links).edges.count
    }

    /// The header's one-line summary. The no-links case is a PROMPT, not a
    /// count: an unlinked switchboard is the one state the human must act on.
    static func caption(projectCount: Int, linkCount: Int) -> String {
        guard linkCount > 0 else {
            return "\(projectCount) projects · nothing linked yet"
        }
        return "\(projectCount) projects · \(linkCount) link\(linkCount == 1 ? "" : "s")"
    }
}

#Preview("Bus map section — mock scenario") {
    let stores = AppStores.mock()
    BusMapSection()
        .environment(Theme())
        .environment(stores)
        .frame(width: 900)
        .background(Theme().canvas)
        .task { await stores.activate() }
}

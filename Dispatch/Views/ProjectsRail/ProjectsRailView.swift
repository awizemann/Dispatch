// ProjectsRailView.swift
// Projects rail (238pt default, DARK chrome — v3 Obsidian): TWO stacked top
// rows per handoff §1 — Row 1 (traffic lights only, the window-drag region) and
// Row 2 (the brand row: 26px accent app-icon tile + "Dispatch" wordmark) —
// then PINNED / PROJECTS card sections, "+ Add project", MCP health footer
// (design §1/§2). The rail sits directly on the window's dark-chrome gradient
// (no fill, no trailing border — one continuous shell); a drag handle on its
// inner edge resizes it live. Settings is retired from the rail — it lives on
// the app menu (⌘,) per macOS convention (Phase 2 wired CommandGroup .appSettings).

import SwiftUI
import AppKit   // NSImage(named:) — the app-icon-asset resolution for the brand tile

struct ProjectsRailView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    var body: some View {
        @Bindable var theme = theme
        return VStack(alignment: .leading, spacing: 0) {
            titlebarStrip
            brandRow
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    section("PINNED", projects: stores.projects.pinnedProjects)
                    clusteredProjects
                }
                .padding(.bottom, 12)
            }
            AddProjectButton { stores.projects.modalRoute = .add }
            BusHealthFooter()
        }
        .frame(width: theme.projectsRailWidth)
        .frame(maxHeight: .infinity)
        // No fill / no trailing border: the rail sits on the window's dark-chrome
        // gradient (one continuous shell). Drag handle on the INNER (trailing)
        // edge resizes the rail live.
        .overlay(alignment: .trailing) {
            RailResizeHandle(
                edge: .trailing,
                width: $theme.projectsRailWidth,
                defaultWidth: Metrics.projectsRailWidthDefault
            )
        }
    }

    // MARK: - Titlebar strip (Row 1 — traffic lights only)

    /// Row 1 (handoff §1): the macOS traffic lights ONLY. The window is
    /// `.hiddenTitleBar`, so the lights float over this leading strip; keeping it
    /// empty and non-interactive preserves it as the window-drag region and lets
    /// the lights stay clickable. `titleBarHeight` matches the stoplight band so
    /// the lights sit centered. The brand row (Row 2) lives BELOW it.
    private var titlebarStrip: some View {
        Color.clear
            .frame(height: Metrics.titleBarHeight)
            .frame(maxWidth: .infinity)
    }

    // MARK: - Brand row (Row 2 / v3 Obsidian)

    /// Row 2 (handoff §1): the 26px accent app-icon tile + "Dispatch" wordmark
    /// (14.5/700, Chrome.textPrimary), a full-width row of its own BELOW the
    /// traffic-light strip — no longer squeezed beside the lights. The PROJECTS
    /// sections follow directly below.
    private var brandRow: some View {
        HStack(spacing: 8) {
            appIconTile
            Text("Dispatch")
                .textStyle(TextStyle(TypeScale.ui(14.5, .bold)))
                .foregroundStyle(Chrome.textPrimary)
            Spacer(minLength: 0)
        }
        .padding(.leading, 14)
        .padding(.trailing, 12)
        .padding(.vertical, 6)
    }

    /// The 26px brand tile. When a real app icon has been configured in the
    /// asset catalog it renders that icon (rounded to match the tile); until then
    /// it falls back to the designed ◈ accent-gradient placeholder. The moment
    /// Alan drops art into Dispatch/Assets.xcassets/AppIcon.appiconset, this
    /// picks it up with zero code change (see `hasCustomAppIcon`).
    @ViewBuilder
    private var appIconTile: some View {
        // Resolve the AppIcon asset by name (the SAME lookup that gates the
        // fallback, so the gate and the rendered image can never disagree). An
        // EMPTY AppIcon set resolves to nil OR a zero-size image depending on the
        // toolchain — the `size.width > 0` guard treats BOTH as "no icon" so the
        // placeholder shows until Alan drops real art in, at which point this
        // resolves and the tile shows it with no code change.
        if let appIcon = NSImage(named: "AppIcon"), appIcon.isValid, appIcon.size.width > 0 {
            Image(nsImage: appIcon)
                .resizable()
                .interpolation(.high)
                .frame(width: Metrics.appIconTile, height: Metrics.appIconTile)
                .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusAppIcon, style: .continuous))
                .accessibilityHidden(true)
        } else {
            appIconPlaceholder
        }
    }

    /// The designed placeholder: 135° accent→accentHover gradient, radius 7,
    /// inset-top white highlight (ObsidianDepth.primaryButtonHighlight), white
    /// ◈ glyph (handoff §2).
    private var appIconPlaceholder: some View {
        RoundedRectangle(cornerRadius: Metrics.radiusAppIcon, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [theme.accent, theme.accentHover],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: Metrics.appIconTile, height: Metrics.appIconTile)
            .overlay(alignment: .top) {
                // Inset top highlight — a 1px white bar hugging the tile's top
                // edge (SwiftUI has no true inset shadow).
                RoundedRectangle(cornerRadius: Metrics.radiusAppIcon, style: .continuous)
                    .strokeBorder(ObsidianDepth.primaryButtonHighlight, lineWidth: 1)
                    .mask(
                        LinearGradient(
                            colors: [.white, .clear],
                            startPoint: .top, endPoint: .bottom
                        )
                    )
            }
            .overlay(
                Text("◈")
                    .textStyle(TextStyle(TypeScale.ui(13, .bold)))
                    .foregroundStyle(Surface.white)
            )
            .accessibilityHidden(true)
    }

    // MARK: - Clustered PROJECTS section

    /// The unpinned projects, grouped by CLUSTER — the connected component of
    /// the link graph they sit in. The grouping is derived on every render from
    /// (projects, links); there is no group entity to keep in sync, so linking
    /// two clusters merges their sections on the next frame and unlinking splits
    /// them, with nothing to migrate.
    ///
    /// The clusters stay ANONYMOUS: one "PROJECTS" label, then a hairline
    /// between groups. They are emergent — naming them would invite the human to
    /// treat them as things they can rename or move a project into, and neither
    /// is true. The one group that IS named is the trailing unlinked set,
    /// because "off the network" is a real, actionable fact about those repos
    /// (and the map says the same about them, dimmed and set apart).
    ///
    /// PINNED WINS: a pinned project renders in the PINNED section only, never
    /// duplicated into its cluster below. A cluster whose members are all pinned
    /// therefore contributes no section at all.
    @ViewBuilder
    private var clusteredProjects: some View {
        let sections = RailSectionLayout.sections(
            allProjectIDs: stores.projects.projects.map(\.id),
            links: stores.crossProject.links,
            excluding: Set(stores.projects.pinnedProjects.map(\.id))
        )
        if !sections.isEmpty {
            Text("PROJECTS")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
                .padding(.leading, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            ForEach(Array(sections.enumerated()), id: \.element.id) { index, section in
                // One cluster → no separators at all. Two or more → a hairline
                // between them, and a wider gap before the unlinked set so
                // "off the network" reads as a break, not the next network.
                if index > 0 {
                    Divider()
                        .overlay(Chrome.cardBorder)
                        .padding(.horizontal, 14)
                        .padding(.top, section.isUnlinked ? 12 : 8)
                        .padding(.bottom, section.isUnlinked ? 6 : 8)
                }
                if section.isUnlinked && sections.count > 1 {
                    Text("NOT LINKED")
                        .textStyle(TypeScale.sectionLabel)
                        .foregroundStyle(Chrome.sectionLabel.opacity(0.7))
                        .padding(.leading, 14)
                        .padding(.bottom, 6)
                        .accessibilityLabel("Not linked to any project")
                }
                cards(section.projectIDs.compactMap { stores.projects.project(id: $0) })
            }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func section(_ label: String, projects: [Project]) -> some View {
        if !projects.isEmpty {
            Text(label)
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
                .padding(.leading, 14)
                .padding(.top, 14)
                .padding(.bottom, 6)
            cards(projects)
        }
    }

    /// One run of project cards — shared by the PINNED section and every derived
    /// cluster section, so a card looks and behaves identically wherever the
    /// grouping puts it.
    private func cards(_ projects: [Project]) -> some View {
        VStack(spacing: 4) {
            ForEach(projects) { project in
                ProjectCardView(
                    project: project,
                    icon: stores.icons.icon(for: project.id),
                    attentionCount: stores.attentionCount(for: project.id),
                    connection: stores.connection(for: project.id),
                    linkedPeerNames: stores.linkedPeerNames(of: project.id),
                    isSelected: project.id == stores.projects.selectedProjectID,
                    isFolderMissing: stores.projects.staleFolderIDs.contains(project.id),
                    installState: stores.repoInstallStates[project.id],
                    needsSessionRestart: stores.needsSessionRestart(project.id),
                    onSelect: { stores.projects.select(project.id) },
                    onTogglePin: { stores.projects.togglePin(id: project.id) },
                    onEdit: { stores.projects.modalRoute = .edit(project) },
                    onRequestDelete: { stores.projects.deletionRoute = project },
                    onRotateBusToken: {
                        Task { await stores.rotateBusToken(for: project.id) }
                    },
                    onOpenOldestQuestion: {
                        stores.routeToOldestPendingQuestion(in: project.id)
                    }
                )
            }
        }
    }
}

// MARK: - Rail sections (pure)

/// One rendered run of the rail's PROJECTS area: a cluster, or the trailing
/// "not linked" set.
nonisolated struct RailSection: Equatable, Sendable {
    /// Index into the derived networks, or nil for the unlinked set.
    let networkIndex: Int?
    /// The projects to render here, in registry order.
    let projectIDs: [UUID]

    var isUnlinked: Bool { networkIndex == nil }
    /// Stable ForEach identity. The section's identity is its FIRST member, not
    /// its ordinal: when a link merges two clusters the surviving section keeps
    /// its identity and the other disappears, rather than every section below
    /// re-identifying and re-animating.
    var id: String {
        (isUnlinked ? "unlinked-" : "network-") + (projectIDs.first?.uuidString ?? "empty")
    }
}

nonisolated enum RailSectionLayout {

    /// The rail's PROJECTS sections.
    ///
    /// Clusters are derived over EVERY project — pinning must not change who is
    /// in whose network — and pinned projects are then removed from the rendered
    /// runs, because they already have their slot in PINNED and a project must
    /// appear in the rail exactly once. A section that empties out that way is
    /// dropped entirely.
    ///
    /// - Parameters:
    ///   - allProjectIDs: every registered project, in registry order.
    ///   - links: the `projectLink` rows.
    ///   - excluding: ids rendered elsewhere (the pinned set).
    static func sections(
        allProjectIDs: [UUID], links: [ProjectLink], excluding: Set<UUID>
    ) -> [RailSection] {
        let clusters = ProjectClusters(projectIDs: allProjectIDs, links: links)
        var sections: [RailSection] = []
        for (index, network) in clusters.networks.enumerated() {
            let members = network.filter { !excluding.contains($0) }
            if !members.isEmpty {
                sections.append(RailSection(networkIndex: index, projectIDs: members))
            }
        }
        let loose = clusters.unlinked.filter { !excluding.contains($0) }
        if !loose.isEmpty {
            sections.append(RailSection(networkIndex: nil, projectIDs: loose))
        }
        return sections
    }
}

// MARK: - Add project

/// The "+ Add project" affordance, translated to dark chrome from the agent
/// rail's "+ New agent" idiom: a full-width dashed rounded border
/// with centered label, brightening on hover. The light rail draws this with
/// Surface.hairlineStrong / Ink.tertiary; here the Chrome tokens carry it on the
/// dark shell so the two "add" front doors read as one family.
private struct AddProjectButton: View {
    let action: () -> Void
    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            Text("＋ Add project")
                .textStyle(TypeScale.control)
                .foregroundStyle(isHovering ? Chrome.text : Chrome.textMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                        .strokeBorder(
                            isHovering ? Chrome.railTabBorder : Chrome.cardBorder,
                            style: StrokeStyle(lineWidth: 1, dash: [4, 3])
                        )
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .onHover { hovering in
            withAnimation(Motion.state) { isHovering = hovering }
        }
        .help("Add a project")
        .accessibilityLabel("Add a project")
    }
}

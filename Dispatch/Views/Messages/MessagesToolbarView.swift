// MessagesToolbarView.swift
// The Messages inbox toolbar (design §6, prototype lines 613–625): 280pt
// search well, status pills `All · N / Open · N / Answered · N` (accent tint
// when active), then right-aligned single-select per-agent chips (agent tint
// when active). Counts are project-scoped and ignore search/agent narrowing
// (prototype behavior).

import SwiftUI

struct MessagesToolbarView: View {
    @Environment(Theme.self) private var theme

    let model: MessagesInboxModel
    let counts: MessageCounts
    /// The projects this one exchanges questions with — the filter chips.
    let peers: [Project]

    @FocusState private var searchFocused: Bool

    var body: some View {
        // ONE row while the chips fit, TWO when they don't. The project chip row
        // is data-driven — it is as long as the human has projects — and at five
        // it used to squeeze the status pills until their own labels wrapped
        // mid-word ("Answere d · 3"). ViewThatFits picks the honest layout
        // instead of compressing text that has nowhere to go.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                controls
                Spacer(minLength: 8)
                HStack(spacing: 6) { chips }
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    controls
                    Spacer(minLength: 8)
                }
                FlowRow(spacing: 6) { chips }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    /// Search + status pills + expand-all. `fixedSize` so a tight row can never
    /// wrap a pill's own label — the row wraps, the words don't.
    @ViewBuilder
    private var controls: some View {
        searchField
        ForEach(MessageStatusFilter.allCases) { filter in
            statusPill(filter).fixedSize()
        }
        expandAllToggle.fixedSize()
    }

    @ViewBuilder
    private var chips: some View {
        ForEach(peers) { peer in
            peerChip(peer).fixedSize()
        }
    }

    // MARK: - Global expand / collapse all

    /// Header disclosure-all: the compact list defaults to collapsed (tight);
    /// this flips every card at once. State announced via the a11y label.
    private var expandAllToggle: some View {
        let expanded = model.allExpanded
        return Button {
            withAnimation(Motion.state) { model.setGlobalExpansion(!expanded) }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: expanded ? "chevron.up.chevron.down"
                                           : "chevron.down.chevron.up")
                    .textStyle(TextStyle(TypeScale.ui(9, .semibold)))
                    .accessibilityHidden(true)
                Text(expanded ? "Collapse all" : "Expand all")
                    .textStyle(TextStyle(TypeScale.ui(12, .semibold)))
            }
            .foregroundStyle(Ink.secondary)
            .padding(.horizontal, 11)
            .padding(.vertical, 4)
            .overlay(
                Capsule().strokeBorder(Surface.controlBorder)
            )
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.state, value: expanded)
        .help(expanded ? "Collapse every question to a compact row"
                       : "Expand every question to its full card")
        .accessibilityLabel(expanded ? "Collapse all questions" : "Expand all questions")
        .accessibilityAddTraits(expanded ? .isSelected : [])
    }

    // MARK: - Search (debounced in the model, ~250ms)

    private var searchField: some View {
        // The placeholder is drawn by US, not by TextField's prompt: SwiftUI
        // resolves a plain field's prompt against the inherited foreground
        // style, which on this sheet rendered near-white on the light grey
        // well — an unreadable label that made the field look broken. Owning
        // it means owning its contrast (the answer editor does the same).
        TextField(
            "",
            text: Binding(get: { model.searchText }, set: { model.setSearch($0) })
        )
        .textFieldStyle(.plain)
        .textStyle(TextStyle(TypeScale.ui(13)))
        .foregroundStyle(Ink.primary)
        .overlay(alignment: .leading) {
            if model.searchText.isEmpty {
                Text("Search questions, projects, IDs…")
                    .textStyle(TextStyle(TypeScale.ui(13)))
                    .foregroundStyle(Ink.faint)
                    .allowsHitTesting(false)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .fill(Surface.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .strokeBorder(searchFocused ? theme.accent : Surface.controlBorder)
        )
        // Accent focus ring: 0 0 0 3px accent@28% (design tokens).
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                .stroke(theme.accentTint(0.28), lineWidth: 3)
                .opacity(searchFocused ? 1 : 0)
        )
        .animation(Motion.state, value: searchFocused)
        .focused($searchFocused)
        .accessibilityLabel("Search questions, projects, and question IDs")
    }

    // MARK: - Status pills

    private func count(for filter: MessageStatusFilter) -> Int {
        switch filter {
        case .all: counts.all
        case .pending: counts.pending
        case .answered: counts.answered
        case .expired: counts.expired
        case .closed: counts.closed
        }
    }

    private func statusPill(_ filter: MessageStatusFilter) -> some View {
        let active = model.statusFilter == filter
        return Button {
            model.statusFilter = filter
        } label: {
            Text("\(filter.rawValue) · \(count(for: filter))")
                .textStyle(TextStyle(TypeScale.ui(12, .semibold)))
                .foregroundStyle(active ? theme.accentHover : Ink.secondary)
                .padding(.horizontal, 11)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? theme.accentTint(0.14) : .clear))
                .overlay(
                    Capsule().strokeBorder(
                        active ? theme.accentTint(0.45) : Surface.controlBorder
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.state, value: active)
        .help("Show \(filter.rawValue.lowercased()) questions")
        .accessibilityLabel("\(filter.rawValue) filter, \(count(for: filter)) questions")
        .accessibilityAddTraits(active ? .isSelected : [])
    }

    // MARK: - Peer-project chips (single-select toggle)

    private func peerChip(_ peer: Project) -> some View {
        let active = model.peerFilter == peer.id
        return Button {
            model.togglePeerFilter(peer.id)
        } label: {
            Text(peer.name)
                .textStyle(TextStyle(TypeScale.ui(11)))
                .foregroundStyle(active ? theme.accentHover : Ink.secondary)
                .lineLimit(1)
                .padding(.horizontal, 9)
                .padding(.vertical, 4)
                .background(Capsule().fill(active ? theme.accentTint(0.14) : .clear))
                .overlay(
                    Capsule().strokeBorder(
                        active ? theme.accentTint(0.45) : Surface.controlBorder
                    )
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.state, value: active)
        .help("Filter to questions exchanged with \(peer.name)")
        .accessibilityLabel("Filter by project \(peer.name)")
        .accessibilityAddTraits(active ? .isSelected : [])
    }
}

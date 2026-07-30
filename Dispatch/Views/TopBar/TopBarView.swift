// TopBarView.swift
// Top bar (54pt, v3 Obsidian): the sheet's title block on the left — "Dispatch"
// over a one-line statement of what the app IS — and, on the right, the tab
// switcher ONCE THERE IS SOMETHING TO SWITCH (recessed `Surface.segmented`
// track, `radiusSegment`, 3px padding, active segment = white pill + drop).
// With Messages the only tab, the right side shows the pending-question count
// instead. The whole band carries a white@55% wash over the canvas sheet
// (design §2/§6).
//
// The title block replaces P2's bare one-tab segmented control floating alone
// on the left, which read as a broken tab bar rather than a heading.

import Defaults
import SwiftUI

struct TopBarView: View {
    @Environment(AppStores.self) private var stores
    @Environment(Theme.self) private var theme
    @Default(.messagesShowAllProjects) private var showAllProjects
    @Binding var selectedTab: WorkbenchTab

    var body: some View {
        HStack(spacing: 12) {
            titleBlock
            Spacer(minLength: 12)
            segmentedControl
        }
        .padding(.horizontal, Metrics.surfacePadding)
        .frame(height: Metrics.topBarHeight)
        // White@55% wash over the canvas — a faint frost band, no hard divider.
        .background(Surface.topBarWash)
    }

    /// Title + subtitle. The subtitle states the SCOPE the inbox is showing,
    /// because that is the one piece of context a card cannot carry itself.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text("Dispatch")
                .textStyle(TextStyle(TypeScale.ui(14.5, .bold)))
                .foregroundStyle(Ink.primary)
            Text(subtitle)
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
        .accessibilityLabel("Dispatch. \(subtitle)")
    }

    private var subtitle: String {
        guard !showAllProjects else {
            return "Switchboard · questions across every linked project"
        }
        guard let projectID = stores.projects.selectedProjectID,
              let name = stores.projects.project(id: projectID)?.name else {
            return "Switchboard · no project selected"
        }
        return "Switchboard · \(name)"
    }

    /// The macOS-style segmented control: a recessed track holding one segment
    /// per tab. The active segment is a raised white pill; inactive segments are
    /// quiet text that brightens on hover. 3px inner padding so the active pill
    /// insets from the track edge.
    ///
    /// A ONE-tab track is not a control — it is a switch with nothing to switch
    /// to, and clicking it does nothing visible (audit S4). While Messages is the
    /// only tab, the track collapses to the count it was really carrying. The
    /// segmented branch stays live for the moment a second tab lands.
    @ViewBuilder
    private var segmentedControl: some View {
        if WorkbenchTab.allCases.count > 1 {
            HStack(spacing: 0) {
                ForEach(WorkbenchTab.allCases) { tab in
                    TabPill(
                        title: tab.title,
                        isActive: tab == selectedTab,
                        badge: tab == .messages ? openQuestionCount : 0
                    ) {
                        selectedTab = tab
                    }
                }
            }
            .padding(3)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusSegment, style: .continuous)
                    .fill(Surface.segmented)
            )
        } else if openQuestionCount > 0 {
            awaitingCount
        }
    }

    /// The badge the retired one-segment track was carrying: how many questions
    /// are waiting on somebody. Text, not just a number — a bare pill in the
    /// corner of a top bar means nothing on its own.
    private var awaitingCount: some View {
        HStack(spacing: 6) {
            Text("\(openQuestionCount)")
                .textStyle(TextStyle(TypeScale.mono(10, .semibold)))
                .foregroundStyle(Surface.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 16, minHeight: 16)
                .background(Capsule().fill(theme.accent))
            Text("awaiting an answer")
                .textStyle(TextStyle(TypeScale.ui(12, .medium)))
                .foregroundStyle(Ink.secondary)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(openQuestionCount) questions awaiting an answer")
    }

    /// Messages badge = the UNANSWERED questions the tab would actually show —
    /// every pending question in the all-projects inbox, or just the selected
    /// project's inbound ones when the inbox is scoped. A badge that counted
    /// rows the tab then hides would be a bug the user can see.
    private var openQuestionCount: Int {
        guard !showAllProjects else { return stores.messages.pendingCount }
        guard let projectID = stores.projects.selectedProjectID else { return 0 }
        return stores.messages.openCount(for: projectID)
    }

}

/// One segment of the top-bar segmented control (v3 Obsidian, design §6).
/// Active = a raised white pill (`radiusControl`, `0 1 3 ink@16%` drop);
/// inactive = quiet text that brightens on hover — never a mistaken second
/// active pill. Messages appends the accent badge.
struct TabPill: View {
    @Environment(Theme.self) private var theme
    @State private var isHovering = false

    let title: String
    let isActive: Bool
    var badge: Int = 0
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                    .textStyle(TextStyle(TypeScale.ui(13, isActive ? .semibold : .medium)))
                    .foregroundStyle(textColor)
                if badge > 0 {
                    Text("\(badge)")
                        .textStyle(TextStyle(TypeScale.mono(10, .semibold)))
                        .foregroundStyle(Surface.white)
                        .padding(.horizontal, 5)
                        .frame(minWidth: 16, minHeight: 16)
                        .background(Capsule().fill(theme.accent))
                        .accessibilityLabel("\(badge) questions awaiting an answer")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(pillBackground)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            withAnimation(Motion.state) { isHovering = hovering }
        }
        .animation(Motion.state, value: isActive)
    }

    private var textColor: Color {
        if isActive { return Ink.primary }
        return isHovering ? Ink.primary : Ink.secondary
    }

    /// Active = a raised white pill + drop shadow (the clearly-distinct selected
    /// segment). Inactive segments have no fill — the recessed track is their
    /// backdrop; hover is carried by the text brightening, not a competing pill.
    @ViewBuilder
    private var pillBackground: some View {
        if isActive {
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .fill(Surface.white)
                .shadow(color: Surface.segmentActiveShadow, radius: 1.5, y: 1)
        } else {
            Color.clear
        }
    }
}

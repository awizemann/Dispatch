// ProjectCardView.swift
// One project card in the rail (v3 Obsidian — DARK chrome). A Dispatch project
// is a repo on the switchboard, so the card answers the four questions the
// human actually has about one:
//   ① WHO — icon tile, name, repo path, plus the amber attention badge when a
// BACKGROUND project has unanswered questions.
//   ② IS IT REACHABLE — the live dot: filled + pulsing while that repo's own
//      session is on the bus, a hollow ring when it is not, with last-seen in
//      the tooltip and the a11y summary.
//   ③ WHAT STATE IS THE REPO IN — branch, unpushed commits, and the amber
//      `.mcp.json` install chip when the repo can't reach the bus at all.
//   ④ WHO CAN IT TALK TO — the link chips. No links means no peer can be
//      asked and none can ask it; that is worth seeing without opening a modal.
//
// SELECTED: a self-contained card — `Chrome.selected` fill +
// `Chrome.selectedBorder` border, radius `Metrics.radiusCard`, soft dark shadow.

import AppKit
import SwiftUI

struct ProjectCardView: View {
    @Environment(Theme.self) private var theme

    let project: Project
    /// The repo's discovered app icon / favicon. nil → letter tile.
    var icon: NSImage?
    let attentionCount: Int
    /// This repo's own session on the bus (from the router's traffic-based
    /// liveness; scripted in the mock scenario).
    var connection: AppStores.ProjectConnection = .never
    /// Names of the projects this one is linked to — the link chips.
    var linkedPeerNames: [String] = []
    let isSelected: Bool
    /// Last git refresh couldn't reach the repo folder (amber note).
    let isFolderMissing: Bool
    /// Whether the `dispatch` entry is live in this repo's `.mcp.json` (P4).
    /// nil = not evaluated yet (no chip).
    var installState: RepoMCPConfig.InstallState?
    /// Dispatch has rewritten this repo's `.mcp.json` and that repo's session
    /// hasn't been heard from since — it is still running against the old entry
    /// until the human restarts it (audit S1). Never inferred from anything but
    /// a real write + real silence.
    var needsSessionRestart: Bool = false
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onEdit: () -> Void
    /// Opens the DELETE confirmation. First of the double
    /// confirmation — the dialog it raises is the second (type-the-name) step.
    let onRequestDelete: () -> Void
    /// Mints a fresh bus token, revokes the old one, and rewrites this repo's
    /// `.mcp.json` (P4).
    var onRotateBusToken: () -> Void = {}
    /// The amber badge's action: jump to the question that has been waiting
    /// longest for an answer. The badge says a number; this makes it useful.
    var onOpenOldestQuestion: () -> Void = {}

    /// Volatile hover state stays in this leaf view (view discipline).
    @State private var isHovering = false

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 7) {
                identityRow
                gitRow
                linksRow
            }
            .padding(EdgeInsets(top: 10, leading: 12, bottom: 10, trailing: 12))
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardShape.fill(fillColor))
            .overlay {
                if isSelected {
                    cardShape.strokeBorder(Chrome.selectedBorder)
                }
            }
            // Soft dark lift on the selected card only (a warm cardShadow would
            // vanish on the dark rail); unselected cards stay flat on the chrome.
            .darkCardShadow(isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 10)
        .onHover { hovering in
            withAnimation(Motion.state) { isHovering = hovering }
        }
        .contextMenu {
            Button("Edit project & links…", action: onEdit)
            Button(project.pinned ? "Unpin" : "Pin to top", action: onTogglePin)
            Divider()
            // The bus credential lives in this repo's .mcp.json URL. Rotating
            // kills the old one instantly and rewrites the file (P4).
            Button("Rotate bus token", action: onRotateBusToken)
            Divider()
            // Destructive — role: .destructive tints it red and marks it for
            // assistive tech. The type-the-name confirmation dialog is the
            // second gate.
            Button("Delete project…", role: .destructive, action: onRequestDelete)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilitySummary)
        // The combined card swallows the Links… button, so the action it opens
        // is offered here instead — the affordance must not be mouse-only.
        .accessibilityAction(named: "Edit links", onEdit)
    }

    // MARK: - ① Identity

    private var identityRow: some View {
        HStack(alignment: .top, spacing: 9) {
            iconTile
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .textStyle(TextStyle(TypeScale.ui(13.5, .semibold)))
                    .foregroundStyle(Chrome.text)
                Text(project.repoPath)
                    .textStyle(TypeScale.monoMeta)
                    .foregroundStyle(Chrome.textMeta)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            liveDot
            if Self.showsAttentionBadge(attentionCount: attentionCount, isSelected: isSelected) {
                attentionBadge
            }
        }
    }

    /// ② The bus live dot. The SLOT is always present (a hollow ring when the
    /// project is offline), so the card never changes size as sessions come and
    /// go. CONTAINMENT: the pulse bakes in `.accessibilityElement(children:
    /// .combine)`; the dot itself is a11y-hidden — the card's combined summary
    /// voices the connection state, because a color-only signal is not a signal.
    @ViewBuilder
    private var liveDot: some View {
        if connection.isConnected {
            Circle()
                .fill(Status.successDot)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
                .workingDotGlow(Status.successDot)
                .workingDotsBlink()
                .help(connectionHelp)
        } else {
            Circle()
                .strokeBorder(Chrome.textDisabled, lineWidth: 1)
                .frame(width: 6, height: 6)
                .accessibilityHidden(true)
                .help(connectionHelp)
        }
    }

    private var connectionHelp: String {
        Self.connectionLabel(connection) + " — the Claude Code session in this repo"
    }

    /// The repo's real face when Dispatch found one, the letter tile when it
    /// didn't. Decorative either way — the name is right beside it.
    private var iconTile: some View {
        ProjectIconTile(
            icon: icon, name: project.name, size: 28,
            cornerRadius: Metrics.radiusControl, letterSize: 13
        )
        .accessibilityHidden(true)
    }

    /// Amber "needs your eyes" pill — unanswered questions addressed to a
    /// BACKGROUND project. Amber, not red: an unanswered question
    /// is pending, not broken, and the design vocabulary reserves red for hard
    /// failures.
    private var attentionBadge: some View {
        Button(action: onOpenOldestQuestion) {
            Text("\(attentionCount)")
                .textStyle(TextStyle(TypeScale.mono(10, .semibold)))
                .foregroundStyle(Surface.white)
                .padding(.horizontal, 5)
                .frame(minWidth: 17, minHeight: 17)
                .background(Capsule().fill(Status.warningDot))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help("Show the question that has been waiting longest")
        .accessibilityLabel("\(attentionCount) questions awaiting an answer, opens the oldest")
    }

    // MARK: - ③ Repo state

    @ViewBuilder
    private var gitRow: some View {
        HStack(spacing: 6) {
            if let git = project.git {
                Text("⎇ \(git.branch)")
                    .truncationMode(.middle)
                if git.unpushedCommits > 0 {
                    Chip("↥ \(git.unpushedCommits) unpushed",
                         style: .amberPillDark, mono: true)
                        .fixedSize()
                }
            }
            if isFolderMissing {
                folderMissingNote
            }
            busInstallNote
            if needsSessionRestart {
                restartNote
            }
            Spacer(minLength: 0)
        }
        .lineLimit(1)
        .textStyle(TypeScale.monoMeta)
        .foregroundStyle(Chrome.textMeta)
    }

    /// Amber note when the repo's `.mcp.json` does NOT carry a live `dispatch`
    /// entry — the session in that repo cannot reach the bus at all, which is
    /// the single most important thing to know about a project. An INSTALLED
    /// project shows nothing (the quiet default).
    @ViewBuilder
    private var busInstallNote: some View {
        switch installState {
        case .installed, nil:
            EmptyView()
        case .missing:
            Chip("bus not installed", style: .amberPillDark, mono: true)
                .fixedSize()
                .help("This repo's .mcp.json has no dispatch entry yet, so its session can't reach the bus.")
        case .stale:
            Chip("bus entry stale", style: .amberPillDark, mono: true)
                .fixedSize()
                .help("This repo's dispatch entry points at an old address. Rotate the bus token to rewrite it.")
        case .conflict(let reason):
            Chip("entry not ours", style: .amberPillDark, mono: true)
                .fixedSize()
                .help(reason + " Press Links… on this card to replace it.")
        case .invalid(let reason):
            Chip("bus blocked", style: .amberPillDark, mono: true)
                .fixedSize()
                .help(reason)
        }
    }

    /// The post-install cue. Dispatch cannot see a terminal, so this claims
    /// nothing about the session — it states what Dispatch DID (rewrote the
    /// file) and what only the human can do (restart the session that reads it).
    private var restartNote: some View {
        Chip("restart Claude Code", style: .amberPillDark, mono: true)
            .fixedSize()
            .help("Dispatch wrote this repo's .mcp.json. A Claude Code session reads that file "
                  + "only at startup — restart it in this repo (and approve the project-scoped "
                  + "“dispatch” server when it asks). This clears itself the moment that "
                  + "session reaches the bus.")
    }

    /// Amber non-blocking note: the repo folder didn't resolve on the last
    /// scan (moved/deleted). On-dark amber.
    private var folderMissingNote: some View {
        Chip("folder missing", style: .amberPillDark, mono: true)
            .fixedSize()
            .help("The repo folder couldn't be found at its last known location.")
    }

    // MARK: - ④ Links

    /// The peers this project may exchange questions with. Linking is the whole
    /// consent model — an unlinked project is inert on the bus — so the empty
    /// case says so plainly and points at where to fix it.
    @ViewBuilder
    private var linksRow: some View {
        HStack(alignment: .top, spacing: 6) {
            if linkedPeerNames.isEmpty {
                // Short enough to survive the narrowest rail: the tooltip and the
                // a11y summary carry the consequence, the chip carries the state.
                Text("not linked")
                    .textStyle(TypeScale.monoMeta)
                    .foregroundStyle(Chrome.textDisabled)
                    .lineLimit(1)
                    .help("This project can't ask or be asked anything. Use Links… to connect it "
                          + "to another project so their sessions can reach each other.")
            } else {
                // Wraps rather than truncating: a project with four peers should
                // show four chips, not "Driftwood, Hal…".
                FlowRow(spacing: 4) {
                    ForEach(linkedPeerNames, id: \.self) { name in
                        Chip("⇄ \(name)", style: .neutralDark, mono: true, shape: .tag)
                            .fixedSize()
                    }
                }
                .help("Linked to \(linkedPeerNames.joined(separator: ", "))")
            }
            Spacer(minLength: 4)
            linksButton
        }
    }

    /// The explicit way in (audit S2): link management used to live ONLY behind
    /// a right-click, which is not a thing a first-run user finds — and linking
    /// is the consent gate the whole product turns on.
    ///
    /// ALWAYS VISIBLE. It used to appear only on hover or on the
    /// selected card, and a second person hit the same wall the right-click-only
    /// version created: an affordance you have to already know about isn't a way
    /// in. Idle it is a ghost — dimmed label, no capsule — and it takes full
    /// prominence on hover or selection, so the rail stays quiet without hiding
    /// the one control that opens the consent gate.
    ///
    /// The card combines its children for VoiceOver, so assistive tech reaches
    /// the same destination through the card's "Edit links" accessibility action
    /// rather than through this button.
    private var linksButton: some View {
        let prominent = isHovering || isSelected
        return Button(action: onEdit) {
            Text("Links…")
                .textStyle(TypeScale.monoMeta)
                .foregroundStyle(prominent ? Chrome.text : Chrome.textDisabled)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule().fill(prominent ? Chrome.hover : Color.clear)
                )
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .animation(Motion.state, value: prominent)
        .help("Edit this project's name and the projects it may exchange questions with")
        .accessibilityLabel("Edit \(project.name)'s links")
    }

    // MARK: - Card chrome (v3 Obsidian — dark)

    private var cardShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: Metrics.radiusCard, style: .continuous)
    }

    /// Selected = `Chrome.selected` (white@8%); hover = `Chrome.hover`
    /// (white@7%); otherwise transparent (sits on the dark rail).
    private var fillColor: Color {
        if isSelected { return Chrome.selected }
        if isHovering { return Chrome.hover }
        return .clear
    }

    private var accessibilitySummary: String {
        Self.accessibilitySummary(
            name: project.name, repoPath: project.repoPath,
            attentionCount: attentionCount, isSelected: isSelected,
            connection: connection, linkedPeerNames: linkedPeerNames
        )
    }

    // MARK: - Pure card logic (testable)

    /// The amber attention badge shows on a BACKGROUND card with unanswered
    /// questions. Pinned to unselected only: the selected project's questions
    /// are on screen in the inbox, so a badge there would be redundant.
    static func showsAttentionBadge(attentionCount: Int, isSelected: Bool) -> Bool {
        !isSelected && attentionCount > 0
    }

    /// Spoken/tooltip form of the live dot. Never color-only: this string is
    /// what makes the dot legible to VoiceOver and to anyone who can't tell a
    /// filled dot from a hollow one.
    static func connectionLabel(
        _ connection: AppStores.ProjectConnection, now: Date = Date()
    ) -> String {
        if connection.isConnected { return "connected to the bus" }
        guard let lastSeen = connection.lastSeenAt else { return "never connected to the bus" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return "offline, last seen \(formatter.localizedString(for: lastSeen, relativeTo: now))"
    }

    /// The card's combined VoiceOver label. Everything the card shows only in
    /// color or glyph — the live dot, the amber count, the link chips — is
    /// spoken here, because a signal nobody can hear is not a signal.
    static func accessibilitySummary(
        name: String, repoPath: String, attentionCount: Int, isSelected: Bool,
        connection: AppStores.ProjectConnection = .never,
        linkedPeerNames: [String] = [],
        now: Date = Date()
    ) -> String {
        var parts = [name, repoPath]
        if isSelected { parts.append("selected") }
        parts.append(connectionLabel(connection, now: now))
        parts.append(linkedPeerNames.isEmpty
                     ? "not linked to any project"
                     : "linked to \(linkedPeerNames.joined(separator: ", "))")
        if showsAttentionBadge(attentionCount: attentionCount, isSelected: isSelected) {
            parts.append("\(attentionCount) questions awaiting an answer")
        }
        return parts.joined(separator: ", ")
    }
}

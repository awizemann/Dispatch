// QuestionCardView.swift
// One question card in the Messages inbox: header (from-chip · "asks" · to-chip
// · id · status pill), subject 13.5/600, body 12.5, then one of:
// - answered → inset answer block "↳ Driftwood answered" / "↳ You answered ·
//   arbitration"
// - closed/expired → the reason line, card dimmed
// - pending → age + expiry countdown, then the human's three moves:
//     Answer (arbitrate it yourself) · Nudge (copy a line to paste into that
//     repo's session) · Close (end the thread without an answer)
// - answering → inline editor + accent Answer / Cancel (⌘↩ submits, Esc cancels)
//
// NUDGE, specifically: Dispatch has no channel into somebody else's terminal.
// It cannot ring a session. The only honest "poke" is text the human pastes,
// so the button copies rather than pretending to send.

import SwiftUI

struct QuestionCardView: View {
    @Environment(Theme.self) private var theme

    let message: BusMessage
    /// Display names for the asking / asked PROJECTS (P3: bus participants are
    /// projects, not agents). nil = the project is no longer registered.
    let fromProjectName: String?
    let toProjectName: String?
    /// Compact-list expansion: false = tight one-line row, true =
    /// the full card below. Default true keeps every existing call site (and the
    /// previews) rendering the full card unchanged.
    var isExpanded: Bool = true
    let isAnswering: Bool
    let isSubmitting: Bool
    /// True while the chip→card focus pulse runs (accent outline).
    let isHighlighted: Bool
    /// false = no arbitration seam wired (Answer/Close disabled, explained).
    let canAnswer: Bool
    /// True right after this card's nudge was copied — the transient
    /// confirmation, owned by the inbox model so only one card shows it.
    var didCopyNudge: Bool = false
    @Binding var draft: String
    /// Per-card chevron in the compact list. nil = no disclosure control (the
    /// previews / any always-expanded caller).
    var onToggleExpand: (() -> Void)? = nil
    let onStartAnswer: () -> Void
    let onCancelAnswer: () -> Void
    let onSubmitAnswer: () -> Void
    /// Copies the "check your dispatch inbox" line for the asked project's
    /// session. nil = no nudge affordance (previews).
    var onNudge: (() -> Void)? = nil
    /// Closes the thread without an answer. nil = no close affordance.
    var onClose: (() -> Void)? = nil

    @FocusState private var editorFocused: Bool

    private var toLabel: String { toProjectName ?? "that project" }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if onToggleExpand != nil, !isExpanded {
                collapsedRow
            } else {
                header
                Text(message.subject)
                    .textStyle(TextStyle(TypeScale.ui(13.5, .semibold)))
                    .foregroundStyle(Ink.primary)
                    .textSelection(.enabled)
                    .padding(.top, 9)
                Text(message.body)
                    .textStyle(TextStyle(TypeScale.ui(12.5)))
                    .foregroundStyle(Ink.secondary)
                    .lineSpacing(3)
                    .textSelection(.enabled)
                    .padding(.top, 4)
                if message.status == .answered, let answer = message.answer {
                    answerBlock(answer)
                } else if message.status.isTerminal {
                    closedFooter
                } else if isAnswering {
                    answerEditor
                } else {
                    openFooter
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 13, leading: 15, bottom: 13, trailing: 15))
        // v3 Obsidian: question cards are WHITE floating cards with a soft
        // shadow — the flat grey panel fill is retired.
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Surface.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Surface.hairline)
        )
        .cardShadow()
        // Chip→card focus pulse (fades via the caller's withAnimation).
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(theme.accent, lineWidth: 1.5)
                .opacity(isHighlighted ? 1 : 0)
        )
        // A question that closed without an answer dims the whole card —
        // readable for the record, visibly not awaiting anyone.
        .opacity(message.status == .expired || message.status == .closed ? 0.55 : 1)
    }

    // MARK: - Header

    private var header: some View {
        HStack(spacing: 8) {
            if onToggleExpand != nil { disclosure }
            projectChip(fromProjectName)
            Text("asks")
                .textStyle(TextStyle(TypeScale.ui(12)))
                .foregroundStyle(Ink.tertiary)
            projectChip(toProjectName)
            Text(shortID)
                .textStyle(TypeScale.monoMeta)
                .foregroundStyle(Ink.faint)
                .textSelection(.enabled)
            Spacer(minLength: 8)
            statusPill
        }
    }

    // MARK: - Compact list

    /// The tight collapsed row: disclosure · from→to · subject (one line) ·
    /// status.
    private var collapsedRow: some View {
        Button {
            onToggleExpand?()
        } label: {
            HStack(spacing: 8) {
                disclosureChevron
                projectChip(fromProjectName)
                Image(systemName: "arrow.right")
                    .textStyle(TextStyle(TypeScale.ui(9, .semibold)))
                    .foregroundStyle(Ink.faint)
                    .accessibilityHidden(true)
                projectChip(toProjectName)
                Text(message.subject)
                    .textStyle(TextStyle(TypeScale.ui(12.5, .medium)))
                    .foregroundStyle(Ink.primary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 8)
                statusPill
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Expand question \(shortID)")
        .accessibilityElement(children: .combine)
        .accessibilityLabel(collapsedAccessibilityLabel)
        .accessibilityHint("Expands the full question and answer")
        .accessibilityAddTraits(.isButton)
    }

    /// Collapsed rows voice subject + status + from/to (a11y requirement).
    private var collapsedAccessibilityLabel: String {
        let from = fromProjectName ?? "an unknown project"
        let to = toProjectName ?? "an unknown project"
        return "\(shortID), \(statusLabel). \(from) asks \(to): \(message.subject)"
    }

    /// Correlation ids are 32 hex characters — the head is enough to identify a
    /// card on screen, and the full id is always one copy away in the body.
    private var shortID: String {
        message.id.count > 10 ? String(message.id.prefix(10)) + "…" : message.id
    }

    /// The chevron-only disclosure control on the EXPANDED header (collapses the
    /// card). ~28pt hit frame per the a11y convention.
    private var disclosure: some View {
        Button {
            onToggleExpand?()
        } label: {
            disclosureChevron
                .frame(width: 20, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Collapse question \(shortID)")
        .accessibilityLabel("Collapse question \(shortID)")
    }

    private var disclosureChevron: some View {
        Image(systemName: "chevron.down")
            .textStyle(TextStyle(TypeScale.ui(9, .semibold)))
            .foregroundStyle(Ink.faint)
            .rotationEffect(.degrees(isExpanded ? 0 : -90))
    }

    @ViewBuilder
    private func projectChip(_ name: String?) -> some View {
        if let name {
            Chip(name, style: .neutral, shape: .tag)
                .fixedSize()
                .accessibilityLabel("project \(name)")
        } else {
            // Participant no longer registered (project deleted).
            Chip("?", style: .neutral, mono: true, shape: .tag)
                .fixedSize()
                .accessibilityLabel("Unknown project")
        }
    }

    private var statusLabel: String { message.status.rawValue }

    @ViewBuilder
    private var statusPill: some View {
        switch message.status {
        case .expired, .closed:
            // Closed without an answer — muted: nothing succeeded, nothing is
            // awaited.
            Chip(statusLabel, style: .statusDark(Chrome.textMuted), mono: true)
                .help(message.closedReason.map { "Closed without an answer — \($0)" }
                        ?? "Closed without an answer")
                .accessibilityLabel("Status: \(statusLabel), closed without an answer")
        case .pending, .answered:
            Chip(statusLabel,
                 style: .status(message.status == .pending ? .warning : .success, dot: false),
                 mono: true, font: TextStyle(TypeScale.mono(10)))
                .fixedSize()
                .accessibilityLabel("Status: \(statusLabel)")
        }
    }

    // MARK: - Answered (inset white block)

    private var answeredLabel: String {
        let who = message.answeredByHuman ? "↳ You answered · arbitration" : "↳ \(toLabel) answered"
        // WHEN matters as much as who: an answer from four days ago may be
        // stale advice, and the row is the only place that says so.
        guard let answeredAt = message.answeredAt else { return who }
        return "\(who) · \(MessageInboxLogic.relative(answeredAt, to: Date()))"
    }

    private func answerBlock(_ answer: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(answeredLabel)
                .textStyle(TextStyle(TypeScale.mono(9.5)))
                .foregroundStyle(Status.successInk)
            Text(answer)
                .textStyle(TextStyle(TypeScale.ui(12.5)))
                .foregroundStyle(Ink.primary)
                .lineSpacing(3)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(EdgeInsets(top: 9, leading: 12, bottom: 9, trailing: 12))
        // Now that the card itself is white, the inset answer block reads as a
        // recessed grey well (was white-on-grey; would vanish white-on-white).
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .fill(Surface.panel)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                .strokeBorder(Surface.hairline)
        )
        .padding(.top, 10)
    }

    // MARK: - Closed without an answer

    /// The reason line in the answer block's slot: WHY the thread closed, so
    /// the human never mistakes a lapse for an answer — no success ink, no
    /// Answer affordance.
    private var closedFooter: some View {
        Text("⏸ \(message.status.rawValue) — \(message.closedReason ?? "closed without an answer")")
            .textStyle(TextStyle(TypeScale.mono(10)))
            .foregroundStyle(Ink.faint)
            .textSelection(.enabled)
            .padding(.top, 8)
    }

    // MARK: - Open (awaiting + Answer)

    /// The pending card's footer: WHERE the question stands (waiting on whom,
    /// since when, until when), then the human's three moves. The clock ticks
    /// on a 30-second TimelineView — the countdown must not go stale while the
    /// window sits open, and a pending question's TTL is measured in hours, so
    /// half-minute granularity is plenty.
    private var openFooter: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            VStack(alignment: .leading, spacing: 7) {
                statusLine(now: context.date)
                actionRow
            }
        }
        .padding(.top, 8)
    }

    private func statusLine(now: Date) -> some View {
        let expiringSoon = MessageInboxLogic.isExpiringSoon(message, now: now)
        return HStack(spacing: 6) {
            Text("awaiting \(toLabel) · \(MessageInboxLogic.age(of: message, now: now))")
                .textStyle(TextStyle(TypeScale.mono(10)))
                .foregroundStyle(Ink.faint)
            if let expiry = MessageInboxLogic.expiry(of: message, now: now) {
                Text("· \(expiry)")
                    .textStyle(TextStyle(TypeScale.mono(10, expiringSoon ? .semibold : .regular)))
                    // Amber only inside the last hour: a countdown that is
                    // always coloured stops meaning anything.
                    .foregroundStyle(expiringSoon ? Status.warningInk : Ink.faint)
            }
            Spacer(minLength: 0)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "Awaiting \(toLabel), \(MessageInboxLogic.age(of: message, now: now))"
            + (MessageInboxLogic.expiry(of: message, now: now).map { ", \($0)" } ?? "")
        )
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            secondaryButton(
                title: "Answer",
                help: canAnswer ? "Answer this yourself — human arbitration"
                                : "Arbitration unavailable — the bus isn't connected",
                a11y: "Answer \(shortID) yourself, human arbitration",
                enabled: canAnswer,
                action: onStartAnswer
            )
            if let onNudge {
                secondaryButton(
                    title: didCopyNudge ? "Copied" : "Nudge",
                    help: "Copy a line to paste into \(toLabel)'s Claude Code session — "
                        + "Dispatch can't reach into a terminal itself",
                    a11y: didCopyNudge
                        ? "Nudge for \(shortID) copied to the clipboard"
                        : "Copy a nudge for \(toLabel) about \(shortID)",
                    enabled: true,
                    action: onNudge
                )
            }
            if let onClose {
                secondaryButton(
                    title: "Close",
                    help: canAnswer ? "End this thread without an answer"
                                    : "Arbitration unavailable — the bus isn't connected",
                    a11y: "Close \(shortID) without an answer",
                    enabled: canAnswer,
                    action: onClose
                )
            }
            Spacer(minLength: 0)
        }
    }

    /// The card's quiet outline button — one definition so Answer, Nudge and
    /// Close cannot drift apart.
    private func secondaryButton(
        title: String, help: String, a11y: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Text(title)
                .textStyle(TextStyle(TypeScale.ui(11.5, .semibold)))
                .foregroundStyle(Ink.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .strokeBorder(Surface.controlBorder)
                )
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(a11y)
    }

    // MARK: - Answering (inline editor)

    private var answerEditor: some View {
        HStack(alignment: .bottom, spacing: 8) {
            editorField
            Button(action: onSubmitAnswer) {
                Text("Answer")
                    .textStyle(TextStyle(TypeScale.ui(12, .semibold)))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 13)
                    .padding(.vertical, 8)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(theme.accent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSubmitting || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .opacity(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? 0.5 : 1)
            .help("Record your answer (⌘↩)")
            .accessibilityLabel("Submit answer to \(shortID)")
            Button(action: onCancelAnswer) {
                Text("Cancel")
                    .textStyle(TextStyle(TypeScale.ui(12, .medium)))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 11)
                    .padding(.vertical, 8)
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .strokeBorder(Surface.controlBorder)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel (Esc)")
            .accessibilityLabel("Cancel answering \(shortID)")
        }
        .padding(.top, 10)
    }

    private var editorField: some View {
        TextEditor(text: $draft)
            .font(TypeScale.ui(13))
            .foregroundStyle(Ink.primary)
            .scrollContentBackground(.hidden)
            .frame(minHeight: 52, maxHeight: 88)
            .padding(.horizontal, 7)
            .padding(.vertical, 4)
            // Recessed field on the now-white card (was white-on-grey).
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                    .fill(Surface.panel)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                    .strokeBorder(editorFocused ? theme.accent : Surface.controlBorder)
            )
            // Accent focus ring: 0 0 0 3px accent@28% (design tokens).
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                    .stroke(theme.accentTint(0.28), lineWidth: 3)
                    .opacity(editorFocused ? 1 : 0)
            )
            .overlay(alignment: .topLeading) {
                if draft.isEmpty {
                    Text("Answer as the human decider…")
                        .textStyle(TextStyle(TypeScale.ui(13)))
                        .foregroundStyle(Ink.faint)
                        .padding(.horizontal, 12)
                        .padding(.top, 8)
                        .allowsHitTesting(false)
                }
            }
            .animation(Motion.state, value: editorFocused)
            .focused($editorFocused)
            .onKeyPress { press in
                if press.key == .escape {
                    onCancelAnswer()
                    return .handled
                }
                if press.key == .return, press.modifiers.contains(.command) {
                    onSubmitAnswer()
                    return .handled
                }
                return .ignored  // plain ↩ inserts a newline (textarea semantics)
            }
            .onAppear { editorFocused = true }
            .accessibilityLabel("Answer to \(shortID)")
    }
}

// MARK: - Previews (pixel-fidelity references vs screenshot 08)

#if DEBUG
@MainActor
private func previewCard(
    _ message: BusMessage, answering: Bool = false, highlighted: Bool = false
) -> some View {
    QuestionCardView(
        message: message,
        fromProjectName: MockData.projectName(message.from),
        toProjectName: MockData.projectName(message.to),
        isAnswering: answering,
        isSubmitting: false,
        isHighlighted: highlighted,
        canAnswer: true,
        draft: .constant(""),
        onStartAnswer: {}, onCancelAnswer: {}, onSubmitAnswer: {}
    )
}

#Preview("Question cards — every state") {
    let messages = MockData.busMessages
    return ScrollView {
        VStack(spacing: 8) {
            ForEach(messages) { message in
                previewCard(message)
            }
        }
        .padding(18)
    }
    .frame(width: 760, height: 700)
    .background(Theme().canvas)
    .environment(Theme())
}
#endif

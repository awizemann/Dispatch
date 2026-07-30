// ProjectAttentionBadgeTests.swift
// The background-project attention badge: a rail card lights an
// amber count when a project OTHER than the selected one needs the human (an
// open question, an inbound cross-project request).
//
// Pinned here (P2 dropped the TriageStore half with the triage subsystem):
//  - Pure view logic — the badge shows on unselected cards only, and the
//    a11y label speaks the count (color-only-signal rule).

import Foundation
import Testing
@testable import DispatchApp

@MainActor
@Suite("Project attention badge (background-project work queue)")
struct ProjectAttentionBadgeTests {

    // MARK: - Pure view logic (badge visibility + a11y)

    @Test("The badge shows only on an unselected card with pending work")
    func badgeVisibilityIsBackgroundOnly() {
        // Background project with work → shows.
        #expect(ProjectCardView.showsAttentionBadge(attentionCount: 2, isSelected: false))
        // Selected project → hidden even with work (the strip surfaces it inline).
        #expect(!ProjectCardView.showsAttentionBadge(attentionCount: 2, isSelected: true))
        // No pending work → hidden.
        #expect(!ProjectCardView.showsAttentionBadge(attentionCount: 0, isSelected: false))
    }

    @Test("The a11y label speaks the attention count on a background card")
    func accessibilityLabelSpeaksCount() {
        let label = ProjectCardView.accessibilitySummary(
            name: "Ledger", repoPath: "~/dev/ledger", attentionCount: 3, isSelected: false
        )
        #expect(label.hasSuffix("3 questions awaiting an answer"))
        #expect(label.hasPrefix("Ledger, ~/dev/ledger, "))
    }

    @Test("The a11y label omits the count on the selected card (no redundant signal)")
    func accessibilityLabelSelectedOmitsCount() {
        let label = ProjectCardView.accessibilitySummary(
            name: "Ledger", repoPath: "~/dev/ledger", attentionCount: 3, isSelected: true
        )
        #expect(label.contains("selected"), "the selected card says 'selected'…")
        #expect(!label.contains("awaiting an answer"), "…and never the count")
    }
}

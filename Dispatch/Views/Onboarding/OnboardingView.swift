// OnboardingView.swift
// First-run welcome surface: shown over the empty workbench while
// the projects registry is empty (OnboardingGate). One paragraph on what
// Dispatch is, then the guided step that reuses an EXISTING flow —
//   1. Add a project → ProjectModal (stores.projects.modalRoute = .add)
// Skippable (session-only dismiss). No new machinery — glue over existing
// modals/routes, design tokens, a11y labels.

import SwiftUI

struct OnboardingPresenter: View {
    @Environment(AppStores.self) private var stores

    var body: some View {
        ZStack {
            if stores.shouldShowOnboarding {
                Surface.scrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                OnboardingView()
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Motion.riseModal, value: stores.shouldShowOnboarding)
    }
}

struct OnboardingView: View {
    @Environment(AppStores.self) private var stores
    @Environment(Theme.self) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            Text("Dispatch is a switchboard for your repositories. Add each repo as a project, link the ones that should talk, and the Claude Code sessions you run in them can ask each other questions across repos — you watch, and answer anything they can't.")
                .textStyle(TypeScale.body)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(spacing: 10) {
                step(
                    number: 1,
                    title: "Add a project",
                    detail: "Point Dispatch at a local git repository. It writes a `dispatch` "
                        + "entry into that repo's .mcp.json — then restart Claude Code there "
                        + "and approve the server it asks about.",
                    actionLabel: "Add project",
                    action: { stores.projects.modalRoute = .add }
                )
                // Step 2 has no button by design: linking needs TWO projects, and
                // this surface only shows while there are none. Stating it here
                // stops the first-run user from adding one repo and wondering why
                // nothing can talk to anything.
                stepNote(
                    number: 2,
                    title: "Link two projects",
                    detail: "Add a second repo, then press Links… on a project's card in the rail "
                        + "to link them. Linking is the consent that opens the channel."
                )
            }

            skipRow
        }
        .padding(24)
        .frame(width: 460, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Surface.white)
        )
        .modalShadow()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Welcome to Dispatch")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
        }
        .accessibilityAddTraits(.isHeader)
    }

    // MARK: - Step rows

    /// A step with nothing to click yet — same well, dimmed number, no button.
    private func stepNote(number: Int, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)")
                .textStyle(TextStyle(TypeScale.ui(12, .bold)))
                .foregroundStyle(Ink.tertiary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(Surface.chipNeutral))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Ink.primary)
                Text(detail)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Surface.well)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number): \(title). \(detail)")
    }

    private func step(
        number: Int, title: String, detail: String,
        actionLabel: String, action: @escaping () -> Void
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text("\(number)")
                .textStyle(TextStyle(TypeScale.ui(12, .bold)))
                .foregroundStyle(theme.accent)
                .frame(width: 24, height: 24)
                .background(Circle().fill(theme.accentTint(0.14)))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Ink.primary)
                Text(detail)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 10)
            Button(action: action) {
                Text(actionLabel)
                    .textStyle(TextStyle(TypeScale.ui(12, .semibold)))
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(Surface.white)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .strokeBorder(Surface.controlBorder)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(detail)
            .accessibilityLabel("\(actionLabel). Step \(number): \(title)")
        }
        .padding(12)
        // Recessed step-row well (v3 Obsidian): Surface.well is the recessed-
        // element token — a fixed neutral grey, unlike theme.canvas (the
        // themeable sheet-interior color), which drifted with the user's canvas
        // swatch and read as a semantic misuse for an inner-card row.
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Surface.well)
        )
    }

    // MARK: - Skip

    private var skipRow: some View {
        HStack {
            Spacer()
            Button {
                stores.onboardingDismissed = true
            } label: {
                Text("Skip for now")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Ink.tertiary)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Dismiss the welcome — it reappears only while you have no projects")
            .accessibilityLabel("Skip onboarding for now")
        }
    }
}

#Preview("Onboarding — empty registry") {
    OnboardingView()
        .environment(Theme())
        .environment(AppStores.mock())
        .frame(width: 700, height: 620)
        .background(Theme().canvas)
}

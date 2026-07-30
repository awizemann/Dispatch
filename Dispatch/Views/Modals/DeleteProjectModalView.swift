// DeleteProjectModalView.swift
// The DELETE-project confirmation — the SECOND gate of the double
// confirmation (the card's "Delete project…" context-menu action is the first).
// Destructive-action territory, so the bar is the highest kind: the user must
// TYPE THE PROJECT NAME exactly before the destructive button enables, and the
// dialog spells out precisely what is and is NOT deleted ("your repository is
// untouched").
//
// Reuses ProjectModalPresenter's scrim + rise chrome (design §9). Preview-
// verified only (ui-verification-policy: no synthetic clicks).

import SwiftUI

// MARK: - Presenter (scrim + rise)

struct DeleteProjectPresenter: View {
    @Environment(AppStores.self) private var stores

    var body: some View {
        ZStack {
            if let project = stores.projects.deletionRoute {
                Surface.scrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { stores.projects.deletionRoute = nil }
                DeleteProjectModalView(project: project)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Motion.riseModal, value: stores.projects.deletionRoute)
    }
}

// MARK: - Modal card

struct DeleteProjectModalView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    let project: Project
    @State private var typedName: String = ""
    @State private var isDeleting = false
    @State private var errorMessage: String?
    @FocusState private var nameFocused: Bool

    /// The destructive button unlocks only on an EXACT match (trimmed) — the
    /// deliberate friction that makes this the "type the name" confirmation.
    private var nameMatches: Bool {
        typedName.trimmingCharacters(in: .whitespacesAndNewlines) == project.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Delete “\(project.name)”?")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)

            whatHappensSection
            confirmField

            if let errorMessage {
                Text(errorMessage)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Status.dangerInk)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Error: \(errorMessage)")
            }

            buttons
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Surface.white)
        )
        .modalShadow()
        .task(id: project.id) {
            typedName = ""
            errorMessage = nil
            nameFocused = true
        }
        .onExitCommand { dismiss() }
    }

    // MARK: - What is / isn't deleted

    private var whatHappensSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("This permanently removes Dispatch's state for this project:")
                .textStyle(TypeScale.body)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 3) {
                bullet("Every question asked to or from this project")
                bullet("Its links to your other projects")
                bullet("Its bus identity — sessions using it lose their connection")
                bullet("Its `dispatch` entry in the repo's .mcp.json (removed, nothing else in the file is touched)")
            }
            // The load-bearing reassurance: the user's repo is SACRED.
            HStack(alignment: .top, spacing: 7) {
                Text("✓")
                    .textStyle(TextStyle(TypeScale.ui(12, .bold)))
                    .foregroundStyle(Status.successInk)
                Text("Your code is untouched — files, commits, and history stay exactly as they are. The only thing Dispatch removes inside \(project.repoPath) is its own entry in .mcp.json.")
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(Status.successTint)
            )
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Your repository is untouched. Nothing is deleted inside the repo folder.")
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Text("•").foregroundStyle(Ink.tertiary)
            Text(text)
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Type-the-name confirmation

    private var confirmField: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("TYPE THE PROJECT NAME TO CONFIRM")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            TextField(project.name, text: $typedName)
                .textFieldStyle(.plain)
                .textStyle(TypeScale.body)
                .focused($nameFocused)
                .disabled(isDeleting)
                .onSubmit { if nameMatches { confirmDelete() } }
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                        .fill(Surface.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                        .strokeBorder(nameFocused ? Status.dangerDot.opacity(0.55) : Surface.hairlineStrong)
                )
                .accessibilityLabel("Type the project name \(project.name) to confirm deletion")
        }
    }

    // MARK: - Buttons

    private var buttons: some View {
        HStack {
            Spacer()
            Button(action: dismiss) {
                Text("Cancel")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Ink.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .disabled(isDeleting)

            Button(action: confirmDelete) {
                Text("Delete project")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Surface.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(Status.dangerDot)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            // No .defaultAction: a destructive act must never fire on a stray
            // Return before the name is typed. onSubmit (guarded) covers the
            // deliberate Enter-after-typing case.
            .disabled(!nameMatches || isDeleting)
            .opacity(nameMatches && !isDeleting ? 1 : 0.5)
            .accessibilityLabel("Delete project permanently")
            .accessibilityHint(nameMatches ? "" : "Type the project name first")
        }
    }

    // MARK: - Actions

    private func dismiss() {
        stores.projects.deletionRoute = nil
    }

    private func confirmDelete() {
        guard nameMatches, !isDeleting else { return }
        isDeleting = true
        let id = project.id
        Task {
            do {
                try await stores.projects.deleteProject(id: id)
                // Success clears the route (deleteProject sets modalRoute nil;
                // clear the deletion route explicitly).
                stores.projects.deletionRoute = nil
            } catch {
                isDeleting = false
                errorMessage = "Couldn't delete the project — \(error.localizedDescription). It's still listed; try again."
            }
        }
    }
}

#Preview("Delete project — mock") {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        DeleteProjectModalView(
            project: Project(
                id: UUID(), name: "Ledgerline",
                repoPath: "/Users/you/Developer/Ledgerline",
                pinned: false, git: nil, lastOpenedAt: nil
            )
        )
    }
    .environment(Theme())
    .environment(AppStores.mock())
    .frame(width: 900, height: 640)
}

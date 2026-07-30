// ProjectModalView.swift
// Add / Edit project modal (design §9, 440px card): Name field; project
// directory via "⌂ Choose folder…" NSOpenPanel ONLY (no typed path); picked
// path as a mono chip; inline validation error; footer note. Edit mode reuses
// the modal — rename only, path immutable by design.
//
// ProjectModalPresenter is the scrim host WorkbenchView overlays: rgba scrim +
// white 16px-radius card + rise animation (§9's modal chrome).
//
// P5 removed the SHARED MCP SERVERS approval section. It let the human approve
// servers from the repo's .mcp.json "to pass to this project's agents" — but
// Dispatch spawns no agents, so nothing ever read those approvals. A control
// whose setting is never consumed is worse than no control: it tells the user
// they have configured something. The discovery/grant SERVICES survive
// untouched (P6 owns their fate); only the false promise is gone.

import AppKit
import SwiftUI

// MARK: - Presenter (scrim + rise)

struct ProjectModalPresenter: View {
    @Environment(AppStores.self) private var stores

    var body: some View {
        ZStack {
            if let route = stores.projects.modalRoute {
                Surface.scrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { stores.projects.modalRoute = nil }
                ProjectModalView(route: route)
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
                    // Opening the modal is the other moment a project is about
                    // to be looked at closely, so its icon gets the same cheap
                    // re-check selection gets: one stat when the
                    // cached source file is unchanged.
                    .task(id: editedProjectID) {
                        guard let projectID = editedProjectID else { return }
                        await stores.icons.recheck(projectID: projectID)
                    }
            }
        }
        .animation(Motion.riseModal, value: stores.projects.modalRoute)
    }

    /// The project the modal is editing, or nil for the ADD route (which has no
    /// project to re-check yet).
    private var editedProjectID: UUID? {
        if case .edit(let project) = stores.projects.modalRoute { return project.id }
        return nil
    }
}

// MARK: - Modal card

struct ProjectModalView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    let route: ProjectModalRoute
    @State private var form: ProjectFormModel?
    @State private var isSubmitting = false
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let form {
                Text(form.title)
                    .textStyle(TypeScale.panelTitle)
                    .foregroundStyle(Ink.primary)
                nameField(form)
                directorySection(form)
                if case .edit(let project) = route {
                    RepoEntrySection(project: project)
                    CrossProjectLinksSection(project: project)
                }
                if let message = form.errorMessage {
                    Text(message)
                        .textStyle(TypeScale.caption)
                        .foregroundStyle(Status.dangerInk)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityLabel("Error: \(message)")
                }
                footerNote(form)
                buttons(form)
            }
        }
        .padding(20)
        .frame(width: 440, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Surface.white)
        )
        .modalShadow()
        .task(id: route) {
            form = ProjectFormModel(
                mode: mode,
                existingProjects: stores.projects.projects,
                git: stores.projects.git
            )
            nameFocused = true
        }
        .onExitCommand { dismiss() }
    }

    private var mode: ProjectFormModel.Mode {
        switch route {
        case .add: .add
        case .edit(let project): .edit(project)
        }
    }

    // MARK: - Name

    @ViewBuilder
    private func nameField(_ form: ProjectFormModel) -> some View {
        @Bindable var form = form
        VStack(alignment: .leading, spacing: 6) {
            Text("NAME")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            TextField("Project name", text: $form.name)
                .textFieldStyle(.plain)
                .textStyle(TypeScale.body)
                .focused($nameFocused)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                        .fill(Surface.white)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Metrics.radiusField, style: .continuous)
                        .strokeBorder(nameFocused ? theme.accentTint(0.45) : Surface.hairlineStrong)
                )
        }
    }

    // MARK: - Directory

    @ViewBuilder
    private func directorySection(_ form: ProjectFormModel) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("PROJECT DIRECTORY")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            HStack(spacing: 8) {
                if !form.isEditing {
                    Button(action: chooseFolder) {
                        Text("⌂ Choose folder…")
                            .textStyle(TypeScale.control)
                            .foregroundStyle(Ink.primary)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(
                                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                                    .fill(Surface.chipNeutral)
                            )
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help("Pick the project's git repository folder")
                }
                if form.validation == .validating {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("Checking folder")
                }
            }
            if let path = form.pickedPath {
                pathChip(path, immutable: form.isEditing)
            }
        }
    }

    private func pathChip(_ path: String, immutable: Bool) -> some View {
        Text(path)
            .textStyle(TypeScale.monoMeta)
            .foregroundStyle(Ink.mutedMono)
            .lineLimit(1)
            .truncationMode(.middle)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                    .fill(Surface.chipNeutral)
            )
            .opacity(immutable ? 0.65 : 1)
            .help(immutable
                  ? "The repo path can't change — this project's bus identity and question history are tied to it. Remove and re-add the project to move it."
                  : path)
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = false
        panel.prompt = "Choose"
        panel.message = "Pick the project's git repository folder"
        if panel.runModal() == .OK, let url = panel.url {
            form?.folderPicked(url)
        }
    }

    // MARK: - Footer

    /// Says what happens on disk AND what the human has to do about it. Claude
    /// Code reads `.mcp.json` once, when it starts, and asks about a
    /// project-scoped server the first time it sees one — so "it just works" was
    /// never true, and the copy said it anyway (audit S1).
    private func footerNote(_ form: ProjectFormModel) -> some View {
        Text(form.isEditing
             ? "Renaming changes nothing in the repo — the bus entry and this project's "
               + "question history stay as they are."
             : "Creating adds a `dispatch` entry to this repo's .mcp.json at the repository root. "
               + "Then restart the Claude Code session in that repo — it reads .mcp.json only at "
               + "startup — and approve the project-scoped “dispatch” server when it asks. "
               + "Link it to another project to let them ask each other questions.")
            .textStyle(TypeScale.caption)
            .foregroundStyle(Ink.tertiary)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func buttons(_ form: ProjectFormModel) -> some View {
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
            Button(action: submit) {
                Text(form.submitLabel)
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Surface.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(theme.accent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            .disabled(!form.canSubmit || isSubmitting)
            .opacity(form.canSubmit && !isSubmitting ? 1 : 0.5)
        }
    }

    // MARK: - Actions

    private func dismiss() {
        stores.projects.modalRoute = nil
    }

    private func submit() {
        guard let form, form.canSubmit, !isSubmitting else { return }
        isSubmitting = true
        Task {
            defer { isSubmitting = false }
            do {
                switch form.mode {
                case .add:
                    // The REPO ROOT (S3), not the picked subdirectory: the
                    // `.mcp.json` has to land where a session started in this
                    // repo will look for it.
                    guard let path = form.submissionPath else { return }
                    let newID = try await stores.projects.addProject(
                        name: form.trimmedName,
                        folderURL: URL(fileURLWithPath: path, isDirectory: true)
                    )
                    // P4 install: register the new project's bus endpoint and
                    // merge the `dispatch` entry into its repo's `.mcp.json`.
                    // This is the whole point of adding a project — the repo's
                    // own Claude Code session has no other way to reach the bus.
                    // Failures land in `repoInstallStates` (the rail shows them),
                    // never here: the project itself was created.
                    await stores.syncRepoInstall(for: newID)
                case .edit(let project):
                    try await stores.projects.renameProject(id: project.id, name: form.trimmedName)
                }
                // Success dismisses via the store (modalRoute = nil).
            } catch {
                form.submitFailed(message: "Couldn't save the project — \(error.localizedDescription)")
            }
        }
    }
}

// MARK: - Repo entry (edit mode; audit S2)

/// What this repo's `.mcp.json` says RIGHT NOW — re-read when the modal opens,
/// not remembered from the last install. Three things can be true and only one
/// of them is fine, so the section says which, and carries the one repair the
/// state allows:
///   • installed → the restart note if Dispatch has rewritten it since that
///     repo's session was last heard from;
///   • missing/stale/invalid → "Install entry" (the same register-and-write the
///     add flow runs);
///   • conflict → a foreign `dispatch` server is there, and NOTHING happens
///     without the human pressing Replace entry. Dispatch never takes a key it
///     did not write.
private struct RepoEntrySection: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    let project: Project
    @State private var isWorking = false

    private var state: RepoMCPConfig.InstallState? { stores.repoInstallStates[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("BUS ENTRY")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            Text(summary)
                .textStyle(TypeScale.caption)
                .foregroundStyle(isHealthy ? Ink.tertiary : Status.warningInk)
                .fixedSize(horizontal: false, vertical: true)
            if let action = repairLabel {
                Button {
                    repair()
                } label: {
                    Text(isWorking ? "Working…" : action)
                        .textStyle(TypeScale.control)
                        .foregroundStyle(Ink.primary)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(
                            RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                                .fill(Surface.chipNeutral)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(isWorking)
                .help(repairHelp)
                .accessibilityLabel("\(action) for \(project.name)")
            }
            if tokenIsCommittable {
                // INFO, not a warning: nothing is broken and nothing is pending
                // on the human. Tertiary ink, no badge, no button — the same
                // weight as the healthy install line, because this is a fact
                // about their repo, not a failure of ours.
                Text(RepoMCPInstaller.committedTokenHelp)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel(
                        "Bus token in a committed file for \(project.name). "
                        + RepoMCPInstaller.committedTokenHelp)
            }
            SessionHooksRow(project: project)
        }
        // Re-verify on open: the file may have been hand-edited since the last
        // install, and this section exists to tell the truth about it.
        .task(id: project.id) { await stores.verifyRepoInstall(for: project.id) }
    }

    private var isHealthy: Bool {
        state == .installed || state == nil
    }

    /// The repo brought its own `.mcp.json`, so Dispatch never touched its
    /// `.gitignore` — and the entry we merged in carries this project's token.
    /// Only worth saying while the entry is actually in there.
    private var tokenIsCommittable: Bool {
        stores.repoTokenExposure[project.id] == .committedFile && state != .missing
    }

    private var summary: String {
        switch state {
        case .installed:
            return stores.needsSessionRestart(project.id)
                ? "Installed at \(project.repoPath)/.mcp.json — Dispatch rewrote it since this "
                    + "repo's session was last heard from. Restart Claude Code there to pick it up."
                : "Installed at \(project.repoPath)/.mcp.json. A Claude Code session started in "
                    + "this repo reads it at startup."
        case nil:
            // Not evaluated yet — the .task below is reading the file right now.
            // Saying "not installed" here would be a guess presented as a fact.
            return "Checking this repo's .mcp.json…"
        case .missing:
            return "This repo's .mcp.json has no dispatch entry, so the session you run there "
                + "can't reach the bus."
        case .stale:
            return "This repo's dispatch entry points at an old address — reinstall it, then "
                + "restart the Claude Code session in that repo."
        case .conflict(let reason):
            return reason
        case .invalid(let reason):
            return reason
        }
    }

    private var repairLabel: String? {
        switch state {
        case .installed, nil: nil
        case .conflict: "Replace entry"
        case .missing, .stale, .invalid: "Install entry"
        }
    }

    private var repairHelp: String {
        if case .conflict = state {
            return "Overwrite the existing “dispatch” server in this repo's .mcp.json with "
                + "Dispatch's own entry. Whatever is there now stops working."
        }
        return "Write Dispatch's entry into this repo's .mcp.json"
    }

    private func repair() {
        isWorking = true
        Task {
            defer { isWorking = false }
            if case .conflict = state {
                await stores.replaceForeignRepoEntry(for: project.id)
            } else {
                await stores.syncRepoInstall(for: project.id)
            }
        }
    }
}

// MARK: - Session hooks (edit mode)

/// The OPT-IN, default OFF, for the two nudge hooks Dispatch merges into this
/// repo's `.claude/settings.local.json`.
///
/// It sits under BUS ENTRY because it is the same bargain one step further:
/// the entry lets the repo's session reach the bus, this makes it LOOK. It is
/// off by default and says plainly which file it writes — a second file inside
/// somebody's repository is not something to acquire quietly.
///
/// The state line is the install line's twin: what the file says RIGHT NOW,
/// re-read with `verifyRepoInstall`, including the case where the file is there
/// but not something Dispatch may rewrite.
private struct SessionHooksRow: View {
    @Environment(AppStores.self) private var stores

    let project: Project
    @State private var isWorking = false

    private var isOn: Bool {
        stores.projects.project(id: project.id)?.sessionHooksEnabled ?? false
    }

    private var state: RepoHooksConfig.InstallState? { stores.repoHooksStates[project.id] }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Session hooks — nudge Claude Code to check its dispatch inbox")
                        .textStyle(TypeScale.caption)
                        .foregroundStyle(Ink.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Writes three hooks into \(project.repoPath)/.claude/settings.local.json "
                         + "— the per-machine file, not the one your team shares. They print one "
                         + "line when a linked project is waiting, and nothing otherwise.")
                        .textStyle(TypeScale.caption)
                        .foregroundStyle(Ink.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 12)
                Toggle("", isOn: Binding(
                    get: { isOn },
                    set: { newValue in
                        guard !isWorking else { return }
                        isWorking = true
                        Task {
                            defer { isWorking = false }
                            await stores.setSessionHooks(newValue, for: project.id)
                        }
                    }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(isWorking)
            }
            if let note = stateNote {
                Text(note)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Status.warningInk)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Session hooks for \(project.name)")
    }

    /// Said only when something is WRONG. The healthy states (off, or on and
    /// installed) are already stated by the switch itself.
    private var stateNote: String? {
        guard isOn else { return nil }
        switch state {
        case .installed, nil: return nil
        case .missing:
            return "This repo's .claude/settings.local.json no longer carries Dispatch's hooks — "
                + "toggle this off and on to rewrite them."
        case .stale:
            return "This repo carries an older version of Dispatch's hooks — toggle this off "
                + "and on to refresh them."
        case .invalid(let reason): return reason
        }
    }
}

// MARK: - Linked projects (edit mode)

/// The LINKED PROJECTS editor — the whole consent model of Dispatch, in one
/// section. A link says: the Claude Code session in THIS repo and the session in
/// that one may ask each other questions, both directions, without asking me
/// each time. No link → `ask_agent` fails closed against that project.
///
/// Add = a picker over registered projects (self + already-linked excluded);
/// Remove = warn-then-allow when questions are still open (the pending rows are
/// then closed honestly rather than stranded — see AppStores.live's removeLink).
/// Reads the LIVE link list + message set so an add/remove repaints.
private struct CrossProjectLinksSection: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    let projectID: UUID

    /// The peer a pending removal targets (the in-flight warn confirm). nil = no
    /// dialog showing.
    @State private var removalWarnPeer: UUID?

    init(project: Project) { self.projectID = project.id }

    /// Links involving this project, resolved to (linkPeerID, peerName), name-sorted.
    private var linkedPeers: [(id: UUID, name: String)] {
        stores.crossProject.links(involving: projectID)
            .compactMap { link -> (id: UUID, name: String)? in
                guard let peerID = link.peer(of: projectID) else { return nil }
                // A link whose peer is no longer registered resolves to no name —
                // dropped from the list (it can't be addressed; deletion-prune
                // removes the row, this is the belt-and-suspenders read guard).
                guard let name = stores.projects.project(id: peerID)?.name else { return nil }
                return (peerID, name)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Registered projects eligible to link: every OTHER project not already
    /// linked, name-sorted.
    private var linkCandidates: [Project] {
        let linked = stores.crossProject.linkedPeerIDs(of: projectID)
        return stores.projects.projects
            .filter { $0.id != projectID && !linked.contains($0.id) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("LINKED PROJECTS")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            Text("The projects whose Claude Code sessions may ask this one questions — and be asked. Linking is your consent, given once; individual questions are never approved one by one.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            if linkedPeers.isEmpty {
                Text("Not linked to anything — this project can’t ask or be asked.")
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.faint)
            } else {
                ForEach(linkedPeers, id: \.id) { peer in
                    linkRow(peerID: peer.id, name: peer.name)
                }
            }
            addMenu
        }
        .confirmationDialog(
            "Unlink while questions are still open?",
            isPresented: removalWarnPresented,
            titleVisibility: .visible
        ) {
            Button("Unlink", role: .destructive) {
                if let peerID = removalWarnPeer { remove(peerID) }
                removalWarnPeer = nil
            }
            Button("Cancel", role: .cancel) { removalWarnPeer = nil }
        } message: {
            Text("Questions between these two projects are still awaiting answers. "
                 + "Unlinking closes them — an answer can’t cross a link that’s gone — "
                 + "and the asking sessions will see them as closed unanswered.")
        }
    }

    /// Unanswered questions still open between this project and a peer — the
    /// unlink WARN signal (never a block). Reads the one global message mirror.
    private func hasInFlightQuestions(with peerID: UUID) -> Bool {
        CrossProjectStore.hasInFlightQuestions(
            with: peerID, in: projectID, messages: stores.messages.messages(in: projectID)
        )
    }

    private func linkRow(peerID: UUID, name: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .textStyle(TypeScale.control)
                .foregroundStyle(Ink.primary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasInFlightQuestions(with: peerID) {
                Text("in flight")
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Status.warningInk)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Status.warningTint))
                    .help("Questions are still open with this project")
                    .accessibilityLabel("requests in flight")
            }
            Button {
                requestRemoval(peerID)
            } label: {
                Text("Unlink")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Status.dangerInk)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Unlink “\(name)” — their sessions can no longer reach each other")
            .accessibilityLabel("Unlink \(name)")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(Surface.chipNeutral)
        )
    }

    @ViewBuilder
    private var addMenu: some View {
        if linkCandidates.isEmpty {
            Text(stores.projects.projects.count <= 1
                 ? "Add another project to Dispatch to link it here."
                 : "Every other project is already linked.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.faint)
        } else {
            Menu {
                ForEach(linkCandidates) { candidate in
                    Button(candidate.name) { add(candidate.id) }
                }
            } label: {
                Text("＋ Link a project…")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(theme.accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("Link a project")
        }
    }

    // MARK: - Actions

    private var removalWarnPresented: Binding<Bool> {
        Binding(
            get: { removalWarnPeer != nil },
            set: { if !$0 { removalWarnPeer = nil } }
        )
    }

    /// Remove immediately when nothing is in flight; otherwise raise the warn
    /// confirm (plan default: warn, but always allow — orphan-safe).
    private func requestRemoval(_ peerID: UUID) {
        if hasInFlightQuestions(with: peerID) {
            removalWarnPeer = peerID
        } else {
            remove(peerID)
        }
    }

    private func add(_ peerID: UUID) {
        let store = stores.crossProject
        let id = projectID
        Task { await store.addLink(id, to: peerID) }
    }

    private func remove(_ peerID: UUID) {
        let store = stores.crossProject
        let id = projectID
        Task { await store.removeLink(id, from: peerID) }
    }
}

#Preview("Add project — mock") {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        ProjectModalView(route: .add)
    }
    .environment(Theme())
    .environment(AppStores.mock())
    .frame(width: 900, height: 600)
}

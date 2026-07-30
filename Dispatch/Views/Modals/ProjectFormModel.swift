// ProjectFormModel.swift
// Form state for the Add/Edit project modal (design §9): folder-pick →
// async validation (must be a git repo; duplicate guard) → submit gating.
// Pure state machine over the GitStatusProviding seam — unit-tested with
// MockGitStatus (ProjectFormModelTests).

import Foundation
import Observation

@MainActor
@Observable
final class ProjectFormModel {

    enum Mode: Equatable {
        case add
        case edit(Project)
    }

    enum Validation: Equatable {
        case idle          // nothing picked yet
        case validating
        case valid(repoRoot: String)
        case invalid(message: String)
    }

    let mode: Mode
    var name: String
    private(set) var pickedPath: String?
    private(set) var validation: Validation

    private let existingProjects: [Project]
    private let git: any GitStatusProviding
    /// Auto-suggestion only overwrites a name the user hasn't touched.
    private var lastSuggestedName: String?
    @ObservationIgnored private var validationTask: Task<Void, Never>?

    init(mode: Mode, existingProjects: [Project], git: any GitStatusProviding) {
        self.mode = mode
        self.git = git
        switch mode {
        case .add:
            self.name = ""
            self.pickedPath = nil
            self.validation = .idle
            self.existingProjects = existingProjects
        case .edit(let project):
            self.name = project.name
            self.pickedPath = project.repoPath
            // Path is immutable in edit mode — no re-validation.
            self.validation = .valid(repoRoot: project.repoPath)
            self.existingProjects = existingProjects.filter { $0.id != project.id }
        }
    }

    // MARK: - Derived UI state

    var isEditing: Bool {
        if case .edit = mode { return true }
        return false
    }

    var title: String { isEditing ? "Edit project" : "Add project" }
    var submitLabel: String { isEditing ? "Save changes" : "Create project" }

    var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var errorMessage: String? {
        if case .invalid(let message) = validation { return message }
        return nil
    }

    /// The path the project is actually CREATED against: the git repo ROOT, not
    /// whatever subdirectory the human happened to pick in the panel.
    ///
    /// `validate` has always resolved the root; until the audit (S3) it threw it
    /// away, so picking `repo/Sources` stored that path and wrote `.mcp.json`
    /// there — where Claude Code, which reads the file at the repo root of the
    /// directory it is started in, would never see it. nil = nothing valid to
    /// submit.
    var submissionPath: String? {
        if case .edit(let project) = mode { return project.repoPath }
        if case .valid(let repoRoot) = validation { return repoRoot }
        return nil
    }

    var canSubmit: Bool {
        guard !trimmedName.isEmpty else { return false }
        if isEditing { return true } // rename only; path already valid
        if case .valid = validation { return true }
        return false
    }

    // MARK: - Folder pick + validation

    /// NSOpenPanel result. Suggests the folder name as the project name
    /// (unless the user already typed one) and kicks async validation.
    func folderPicked(_ url: URL) {
        guard !isEditing else { return } // path immutable in edit mode
        let standardized = url.standardizedFileURL
        pickedPath = standardized.path
        if trimmedName.isEmpty || name == lastSuggestedName {
            name = standardized.lastPathComponent
            lastSuggestedName = name
        }
        validate(path: standardized.path)
    }

    /// Submit-time failures (e.g. the persistence write threw) surface in the
    /// same inline error slot.
    func submitFailed(message: String) {
        validation = .invalid(message: message)
    }

    private func validate(path: String) {
        validationTask?.cancel()
        validation = .validating
        let git = git
        let existing = existingProjects
        validationTask = Task { [weak self] in
            let outcome: Validation
            if await git.isGitRepo(at: path) {
                do {
                    let root = try await git.repoRoot(for: path)
                    if let duplicate = Self.duplicate(of: path, orRoot: root, in: existing) {
                        outcome = .invalid(message: "Already added as “\(duplicate.name)”.")
                    } else {
                        outcome = .valid(repoRoot: root)
                    }
                } catch {
                    outcome = .invalid(message: "Couldn't inspect this folder's git repository.")
                }
            } else {
                outcome = .invalid(message: "This folder isn't a git repository. Run “git init” first, or pick another folder.")
            }
            // Belt-and-braces against stale results: cancellation is checked
            // AND the outcome must still describe the currently picked path
            // (a re-pick cancels this task synchronously on MainActor, but the
            // path guard keeps that invariant local and future-proof).
            guard !Task.isCancelled, let self, self.pickedPath == path else { return }
            self.validation = outcome
            // The project IS the repo, so an untouched auto-suggestion follows
            // the resolved ROOT's name rather than the subfolder that was picked.
            if case .valid(let repoRoot) = outcome,
               self.name == self.lastSuggestedName || self.trimmedName.isEmpty {
                let rootName = URL(fileURLWithPath: repoRoot).lastPathComponent
                if !rootName.isEmpty {
                    self.name = rootName
                    self.lastSuggestedName = rootName
                }
            }
        }
    }

    /// Duplicate guard: an existing project whose stored path matches the
    /// picked folder or its repo root. (Existing projects' own roots aren't
    /// re-resolved here — subfolder-vs-subfolder of one repo passes; the
    /// common re-add case is caught.)
    nonisolated private static func duplicate(of path: String, orRoot root: String, in projects: [Project]) -> Project? {
        projects.first { project in
            let existing = URL(fileURLWithPath: project.repoPath).standardizedFileURL.path
            return existing == path || existing == root
        }
    }
}

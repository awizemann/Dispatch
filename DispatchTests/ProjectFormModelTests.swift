// ProjectFormModelTests.swift
// The add/edit modal's form state machine, driven through MockGitStatus —
// validation states, name auto-suggestion, duplicate guard, edit-mode rules.

import Foundation
import Testing
@testable import DispatchApp

@Suite("Project form model")
struct ProjectFormModelTests {

    private func makeProject(name: String, path: String) -> Project {
        Project(id: UUID(), name: name, repoPath: path,
                pinned: false, git: nil, lastOpenedAt: nil)
    }

    // MARK: - Add mode

    @Test("Folder pick auto-suggests the folder name and validates to .valid")
    func pickSuggestsNameAndValidates() async throws {
        let form = ProjectFormModel(mode: .add, existingProjects: [], git: MockGitStatus())
        #expect(!form.canSubmit)

        form.folderPicked(URL(fileURLWithPath: "/repos/Ledgerline", isDirectory: true))

        #expect(form.name == "Ledgerline")
        #expect(form.pickedPath == "/repos/Ledgerline")
        #expect(try await pollUntil { form.validation == .valid(repoRoot: "/repos/Ledgerline") },
                "validation never reached .valid")
        #expect(form.canSubmit)
        #expect(form.errorMessage == nil)
    }

    @Test("A user-typed name survives the folder pick; a suggestion follows re-picks")
    func nameSuggestionRules() async throws {
        let form = ProjectFormModel(mode: .add, existingProjects: [], git: MockGitStatus())

        form.name = "My Custom Name"
        form.folderPicked(URL(fileURLWithPath: "/repos/Ledgerline", isDirectory: true))
        #expect(form.name == "My Custom Name")

        // Untouched suggestion is replaced by the next pick's suggestion.
        let fresh = ProjectFormModel(mode: .add, existingProjects: [], git: MockGitStatus())
        fresh.folderPicked(URL(fileURLWithPath: "/repos/First", isDirectory: true))
        #expect(fresh.name == "First")
        fresh.folderPicked(URL(fileURLWithPath: "/repos/Second", isDirectory: true))
        #expect(fresh.name == "Second")
    }

    @Test("Non-repo folder → friendly inline error, submit disabled")
    func notARepo() async throws {
        let form = ProjectFormModel(
            mode: .add, existingProjects: [],
            git: MockGitStatus(allPathsAreRepos: false)
        )

        form.folderPicked(URL(fileURLWithPath: "/repos/Plain", isDirectory: true))

        #expect(try await pollUntil { form.errorMessage != nil },
                "validation never reached .invalid")
        #expect(form.errorMessage?.contains("isn't a git repository") == true)
        #expect(!form.canSubmit)
    }

    @Test("Duplicate path guard names the existing project")
    func duplicateGuard() async throws {
        let existing = makeProject(name: "Ledgerline", path: "/repos/Ledgerline")
        let form = ProjectFormModel(mode: .add, existingProjects: [existing], git: MockGitStatus())

        form.folderPicked(URL(fileURLWithPath: "/repos/Ledgerline", isDirectory: true))

        #expect(try await pollUntil { form.errorMessage != nil },
                "duplicate pick never invalidated")
        #expect(form.errorMessage?.contains("Ledgerline") == true)
        #expect(!form.canSubmit)
    }

    // MARK: - Edit mode

    @Test("Edit mode prefills, submits without re-validation, and ignores folder picks")
    func editMode() async throws {
        let project = makeProject(name: "Ledgerline", path: "/repos/Ledgerline")
        let form = ProjectFormModel(
            mode: .edit(project),
            existingProjects: [project],   // the edited project must not self-collide
            git: MockGitStatus(allPathsAreRepos: false) // git is never consulted
        )

        #expect(form.isEditing)
        #expect(form.name == "Ledgerline")
        #expect(form.pickedPath == "/repos/Ledgerline")
        #expect(form.canSubmit)

        // Path is immutable by design.
        form.folderPicked(URL(fileURLWithPath: "/repos/Other", isDirectory: true))
        #expect(form.pickedPath == "/repos/Ledgerline")

        form.name = "   "
        #expect(!form.canSubmit) // blank rename is still blocked
    }
}

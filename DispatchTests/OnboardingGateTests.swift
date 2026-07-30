// OnboardingGateTests.swift
// The first-run onboarding show-condition: empty registry shows,
// non-empty hides, and a session-only dismiss keeps it hidden WHILE empty (a
// relaunch — a fresh session with dismissed=false — re-onboards; documented in
// OnboardingGate). Pure logic, no view or store.

import Foundation
import Testing
@testable import DispatchApp

@Suite("OnboardingGate — show condition")
struct OnboardingGateTests {

    @Test("empty registry, not dismissed → shows")
    func emptyShows() {
        #expect(OnboardingGate.shouldShow(projectCount: 0, dismissedThisSession: false))
    }

    @Test("non-empty registry → never shows, dismissed or not")
    func nonEmptyHides() {
        #expect(!OnboardingGate.shouldShow(projectCount: 1, dismissedThisSession: false))
        #expect(!OnboardingGate.shouldShow(projectCount: 3, dismissedThisSession: true))
    }

    @Test("dismiss-while-empty stays hidden for the session")
    func dismissWhileEmptyHides() {
        #expect(!OnboardingGate.shouldShow(projectCount: 0, dismissedThisSession: true))
    }

    @Test("a fresh session (dismissed=false) with a still-empty registry re-onboards")
    func relaunchReonboards() {
        // Session-only dismiss: the flag resets on relaunch, so an empty
        // registry shows again — the wiped-DB-re-onboards property.
        #expect(OnboardingGate.shouldShow(projectCount: 0, dismissedThisSession: false))
    }
}

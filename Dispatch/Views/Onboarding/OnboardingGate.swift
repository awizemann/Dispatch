// OnboardingGate.swift
// Pure show-condition for the first-run onboarding surface. The
// trigger is an EMPTY PROJECTS REGISTRY — deliberately NOT a Defaults flag, so a
// wiped DB re-onboards. Dismiss is SESSION-ONLY (in-memory): skipping hides the
// welcome for the rest of the run, but a relaunch with a still-empty registry
// shows it again — the same "wiped DB re-onboards" property the empty-registry
// trigger gives us, kept consistent (a persisted dismiss would break it). Once
// a project exists it never shows, dismissed or not.
//
// Pure and static so the condition is unit-tested without a view or a store.

import Foundation

nonisolated enum OnboardingGate {

    /// Whether the welcome surface should show.
    /// - Parameters:
    ///   - projectCount: number of projects in the registry.
    ///   - dismissedThisSession: set once the human skips (in-memory only).
    /// - Returns: true iff the registry is empty AND not dismissed this session.
    static func shouldShow(projectCount: Int, dismissedThisSession: Bool) -> Bool {
        projectCount == 0 && !dismissedThisSession
    }
}

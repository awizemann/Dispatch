// PathSafety.swift
// The shared repo-relative path rule. Hoisted from CommitGateService
// so staged-diff paths and work-item reference paths are judged
// by ONE rule — a divergence would let a reference point where a diff never
// could (or vice versa).

import Foundation

nonisolated enum PathSafety {

    /// Paths must stay relative, inside the repo, and outside both git
    /// internals and the app's own worktree area.
    static func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("~") else { return false }
        let segments = path.split(separator: "/")
        guard !segments.contains("..") else { return false }
        guard segments.first != ".git", !path.hasPrefix(".dispatch/") else { return false }
        return true
    }
}

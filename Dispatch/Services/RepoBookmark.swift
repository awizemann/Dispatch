// RepoBookmark.swift
// Bookmark lifecycle for user-picked repo folders: create at pick time,
// resolve (with staleness signal) before every git refresh, re-create when
// stale.
//
// This build is NON-sandboxed (decision-distribution-and-platform-target), so
// these are plain bookmarks: `.withSecurityScope` requires the sandbox
// entitlement and would throw here. The Access wrapper still calls
// start/stopAccessingSecurityScopedResource — a no-op today, correct if the
// app is ever sandboxed (file-safety convention: bookmark-style pickers as UX).

import Foundation

nonisolated enum RepoBookmark {

    struct Resolved: Sendable {
        var url: URL
        /// The system asks for the bookmark to be re-created (target moved).
        var isStale: Bool
    }

    /// Balanced start/stop of (would-be) security-scoped access.
    struct Access: Sendable {
        let url: URL
        private let didStart: Bool

        fileprivate init(url: URL) {
            self.url = url
            // Returns false for plain bookmarks / non-sandboxed builds — fine.
            self.didStart = url.startAccessingSecurityScopedResource()
        }

        func end() {
            if didStart { url.stopAccessingSecurityScopedResource() }
        }
    }

    static func create(for url: URL) throws -> Data {
        try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
    }

    static func resolve(_ data: Data) throws -> Resolved {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data, options: [],
            relativeTo: nil, bookmarkDataIsStale: &isStale
        )
        return Resolved(url: url, isStale: isStale)
    }

    /// Call before touching the bookmarked folder; `end()` when done.
    static func beginAccess(_ url: URL) -> Access {
        Access(url: url)
    }
}

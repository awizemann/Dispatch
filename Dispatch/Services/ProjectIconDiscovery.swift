// ProjectIconDiscovery.swift
// Finds the real face of a linked repo: its app icon or its favicon.
//
// A Dispatch project is somebody's repo, and every repo worth linking already
// carries a picture of itself — an `AppIcon.appiconset`, an `.icns`, a
// `favicon`. The rail card and the bus-map station show that instead of a
// letter tile, so the switchboard looks like the human's actual work rather
// than like five coloured squares.
//
// TWO HALVES, deliberately split:
//   • DISCOVERY (this file, nonisolated) walks the repo and returns an ORDERED
//     list of candidate file URLs. It never decodes an image, so it is pure
//     enough to run off the main actor and to test against a temp directory.
//   • DECODING (ProjectIconLoader, also nonisolated) turns the first candidate
//     that actually decodes into a `CGImage`, which IS Sendable — so the decode
//     rides off the main actor with the walk, and only the final NSImage wrap
//     (and the rare AppKit vector fallback) happens on the main actor.
//
// FAILS CLOSED, ALWAYS. Every path here returns "no icon" rather than throwing:
// a repo with a malformed Contents.json, a symlink loop, or a 50 MB PNG named
// `favicon.png` must degrade to the letter tile, never to an error in the UI
// and never to a stalled scan.
//
// The caller is responsible for the RepoBookmark access scope (see
// ProjectIconStore) — same contract as the git refresh and RepoMCPInstaller.

import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "icons")

nonisolated enum ProjectIconDiscovery {

    // MARK: - Types

    /// Where a candidate came from. Ordering of the enum is not the priority —
    /// `candidates(inRepoRoot:)` returns the list already in priority order.
    enum Kind: String, Sendable, Equatable {
        /// An Xcode asset catalog's AppIcon set (the best possible answer: a
        /// real app icon, at the largest size the app ships).
        case appIcon
        /// A loose `.icns` at a conventional spot.
        case icns
        /// A web favicon / apple-touch-icon.
        case web
    }

    struct Candidate: Sendable, Equatable {
        let url: URL
        let kind: Kind
    }

    /// One `images[]` entry of an appiconset's Contents.json, reduced to the
    /// only two things that matter: the file and how big it renders.
    struct AppIconEntry: Sendable, Equatable {
        let filename: String
        /// size × scale, in pixels. `"512x512" @ "2x"` → 1024.
        let pixels: Double
    }

    /// Bounds that keep a monorepo from turning a cosmetic lookup into a stall.
    /// Every one of these is a CAP, not a target — the common repo trips none.
    struct Limits: Sendable {
        /// Directory levels below the repo root the walk will descend.
        var maxDepth: Int = 6
        /// Total directory entries examined before the walk gives up.
        var maxEntries: Int = 6_000
        /// Files larger than this are never even opened. A favicon is a few KB;
        /// anything past 5 MB is either a mistake or someone's idea of a joke,
        /// and decoding it would cost more than the tile is worth.
        var maxBytes: Int = 5 * 1_024 * 1_024

        static let `default` = Limits()
    }

    // MARK: - Pure rules (testable without a filesystem)

    /// Directories the walk never enters. Build output and dependency trees are
    /// where the icons are COPIES — finding `AppIcon` inside DerivedData would
    /// be right by accident and slow on purpose.
    static let skippedDirectoryNames: Set<String> = [
        "DerivedData", "node_modules", "build", "Build", ".build", "dist",
        "Pods", "Carthage", "vendor", "target", ".git", ".svn", "venv",
        ".venv", "__pycache__", "Debug", "Release", "coverage", ".next",
        ".nuxt", ".gradle", ".cache", "bower_components",
    ]

    static func shouldSkip(directoryNamed name: String) -> Bool {
        // Hidden directories are skipped wholesale (`.git`, `.build`, caches):
        // no repo keeps the icon it wants shown inside a dotfile directory.
        if name.hasPrefix(".") { return true }
        if skippedDirectoryNames.contains(name) { return true }
        // `*.xcodeproj` / `*.xcworkspace` are bundles of project metadata, and
        // `*.app` is a BUILT product — its icon is a copy of the one we want.
        for suffix in [".xcodeproj", ".xcworkspace", ".app", ".framework"]
        where name.hasSuffix(suffix) {
            return true
        }
        return false
    }

    static func isAppIconSet(directoryNamed name: String) -> Bool {
        name.hasSuffix(".appiconset") && name.lowercased().hasPrefix("appicon")
    }

    static func isAssetCatalog(directoryNamed name: String) -> Bool {
        name.hasSuffix(".xcassets")
    }

    /// Parses an appiconset's `Contents.json` into its PNG entries, LARGEST
    /// FIRST. Malformed, truncated, or simply not-an-appiconset JSON yields an
    /// empty list — the caller then moves on to the next source.
    static func appIconEntries(fromContentsJSON data: Data) -> [AppIconEntry] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let images = root["images"] as? [[String: Any]]
        else { return [] }

        var entries: [AppIconEntry] = []
        for image in images {
            // An "unassigned" slot has no filename. Not an error — just empty.
            guard let filename = image["filename"] as? String,
                  !filename.isEmpty,
                  filename.lowercased().hasSuffix(".png")
            else { continue }
            let points = parseSizeDimension(image["size"] as? String)
            let scale = parseScale(image["scale"] as? String)
            entries.append(AppIconEntry(filename: filename, pixels: points * scale))
        }
        // Stable: equal-sized entries keep their Contents.json order, so the
        // pick is deterministic across runs.
        return entries.enumerated()
            .sorted { ($0.element.pixels, -Double($0.offset)) > ($1.element.pixels, -Double($1.offset)) }
            .map(\.element)
    }

    /// `"512x512"` → 512. Anything unparseable → 1, so the entry still sorts
    /// below every well-formed one instead of vanishing.
    static func parseSizeDimension(_ size: String?) -> Double {
        guard let size, let first = size.split(separator: "x").first,
              let value = Double(first), value > 0
        else { return 1 }
        return value
    }

    /// `"2x"` → 2. Missing/garbage → 1.
    static func parseScale(_ scale: String?) -> Double {
        guard let scale, let value = Double(scale.replacingOccurrences(of: "x", with: "")),
              value > 0
        else { return 1 }
        return value
    }

    /// Conventional homes for a loose `.icns`, relative to the repo root.
    static let icnsDirectories = ["", "Resources", "resources", "Assets", "assets"]

    /// Web icon filenames in PRIORITY order. `apple-touch-icon.png` first
    /// because it is the one a site author sized for a tile; `.ico` last
    /// because it is usually 16px and the ugliest upscale of the four.
    static let webIconNames = [
        "apple-touch-icon.png", "apple-touch-icon-precomposed.png",
        "favicon.svg", "favicon.png", "icon.png", "logo.png", "favicon.ico",
    ]

    /// Where those names are looked for, in order. Name-major: an
    /// `apple-touch-icon.png` in `public/` beats a `favicon.ico` at the root.
    static let webIconDirectories = ["", "public", "static", "src", "assets", "www"]

    // MARK: - Discovery

    /// The whole job: every icon candidate in this repo, best first.
    ///
    /// Returns `[]` when the repo has no face — the caller keeps the letter
    /// tile. Never throws; an unreadable directory is a directory with nothing
    /// in it as far as this is concerned.
    static func candidates(
        inRepoRoot root: URL, limits: Limits = .default
    ) -> [Candidate] {
        var result: [Candidate] = []
        result.append(contentsOf: appIconCandidates(inRepoRoot: root, limits: limits))
        result.append(contentsOf: icnsCandidates(inRepoRoot: root, limits: limits))
        result.append(contentsOf: webCandidates(inRepoRoot: root, limits: limits))
        return deduplicated(result)
    }

    /// One file, one candidate — keeping its FIRST (highest-priority) position.
    ///
    /// The same file reaches the list twice more easily than it looks: macOS
    /// filesystems are case-insensitive by default, so `Resources/` and
    /// `resources/` are the same folder, and a repo is free to keep
    /// `favicon.png` where two conventions overlap. A duplicate is harmless to
    /// render and confusing to reason about, so it dies here.
    static func deduplicated(_ candidates: [Candidate]) -> [Candidate] {
        var seen: Set<String> = []
        return candidates.filter { seen.insert($0.url.standardizedFileURL.path.lowercased()).inserted }
    }

    // MARK: (a) Xcode asset catalogs

    /// Every `AppIcon*.appiconset` in the repo, reduced to its largest existing
    /// PNG, ordered largest-icon-first across catalogs. A repo with an app and
    /// a sample app therefore shows the bigger, i.e. the real, icon.
    static func appIconCandidates(
        inRepoRoot root: URL, limits: Limits = .default
    ) -> [Candidate] {
        var best: [(url: URL, pixels: Double)] = []
        for setURL in appIconSetDirectories(inRepoRoot: root, limits: limits) {
            guard let pick = largestPNG(inAppIconSet: setURL, limits: limits) else { continue }
            best.append(pick)
        }
        return best
            .sorted { $0.pixels > $1.pixels }
            .map { Candidate(url: $0.url, kind: .appIcon) }
    }

    /// The largest PNG the set's Contents.json references AND that exists on
    /// disk at a sane size.
    static func largestPNG(
        inAppIconSet setURL: URL, limits: Limits = .default
    ) -> (url: URL, pixels: Double)? {
        let contentsURL = setURL.appendingPathComponent("Contents.json")
        guard let data = readSmallFile(at: contentsURL, maxBytes: 1_024 * 1_024) else { return nil }
        for entry in appIconEntries(fromContentsJSON: data) {
            // A Contents.json filename is a plain component by construction;
            // reject anything that tries to climb out of the set.
            guard !entry.filename.contains("/"), !entry.filename.contains("..") else { continue }
            let fileURL = setURL.appendingPathComponent(entry.filename)
            guard isUsableImageFile(at: fileURL, limits: limits) else { continue }
            return (fileURL, entry.pixels)
        }
        return nil
    }

    /// Bounded, symlink-free walk for `AppIcon*.appiconset` directories.
    ///
    /// Written by hand rather than with `FileManager.enumerator` for three
    /// reasons the enumerator can't give: a hard entry budget, per-directory
    /// skip rules, and an absolute refusal to traverse a symlink (a repo with
    /// `link -> ..` would otherwise walk forever).
    static func appIconSetDirectories(
        inRepoRoot root: URL, limits: Limits = .default
    ) -> [URL] {
        var found: [URL] = []
        var examined = 0
        /// Canonical paths already visited — belt and braces next to the
        /// symlink refusal, in case a hard-linked directory ever appears.
        var visited: Set<String> = []
        /// Depth-first with an explicit stack: `insideCatalog` buys three extra
        /// levels, because an asset catalog nests its own groups and those
        /// levels shouldn't eat the repo's depth budget.
        var stack: [(url: URL, depth: Int, insideCatalog: Bool)] = [
            (root.standardizedFileURL, 0, false)
        ]

        while let (directory, depth, insideCatalog) = stack.popLast() {
            guard examined < limits.maxEntries else {
                logger.info("icon walk hit the entry cap; stopping early")
                break
            }
            guard visited.insert(directory.path).inserted else { continue }

            // Never read more of this directory than the budget can still pay
            // for: the cap has to bind BEFORE the entries are materialised.
            let entries = boundedEntries(
                of: directory,
                keys: [.isDirectoryKey, .isSymbolicLinkKey],
                limit: limits.maxEntries - examined
            )

            for entry in entries {
                examined += 1
                guard examined < limits.maxEntries else { break }
                let values = try? entry.resourceValues(
                    forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
                )
                // NEVER follow a symlink. A repo is allowed to contain
                // `a -> b -> a`; a cosmetic icon lookup is not allowed to hang
                // on it.
                if values?.isSymbolicLink == true { continue }
                guard values?.isDirectory == true else { continue }

                let name = entry.lastPathComponent
                if isAppIconSet(directoryNamed: name) {
                    found.append(entry)
                    continue // an appiconset has no interesting subdirectories
                }
                if shouldSkip(directoryNamed: name) { continue }

                let isCatalog = insideCatalog || isAssetCatalog(directoryNamed: name)
                // Inside a catalog the budget is the catalog's own nesting, not
                // the repo's — so a deep-but-legitimate catalog still resolves.
                let budget = isCatalog ? limits.maxDepth + 3 : limits.maxDepth
                guard depth + 1 < budget else { continue }
                stack.append((entry, depth + 1, isCatalog))
            }
        }
        return found
    }

    // MARK: (b) .icns

    static func icnsCandidates(
        inRepoRoot root: URL, limits: Limits = .default
    ) -> [Candidate] {
        var found: [(url: URL, bytes: Int)] = []
        for directory in icnsDirectories {
            guard let dirURL = unlinkedDirectory(directory, inRepoRoot: root) else { continue }
            let entries = boundedEntries(
                of: dirURL, keys: [.fileSizeKey, .isSymbolicLinkKey],
                limit: limits.maxEntries
            )
            for entry in entries where entry.pathExtension.lowercased() == "icns" {
                guard isUsableImageFile(at: entry, limits: limits) else { continue }
                let bytes = (try? entry.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                found.append((entry, bytes))
            }
        }
        // Biggest file wins: an `.icns` with more/larger representations is the
        // one that survives being drawn at 28pt on a Retina display.
        return deduplicated(
            found.sorted { $0.bytes > $1.bytes }.map { Candidate(url: $0.url, kind: .icns) }
        )
    }

    // MARK: (c) Web favicons

    static func webCandidates(
        inRepoRoot root: URL, limits: Limits = .default
    ) -> [Candidate] {
        var found: [Candidate] = []
        for name in webIconNames {
            for directory in webIconDirectories {
                guard let dirURL = unlinkedDirectory(directory, inRepoRoot: root) else { continue }
                let fileURL = dirURL.appendingPathComponent(name)
                guard isUsableImageFile(at: fileURL, limits: limits) else { continue }
                found.append(Candidate(url: fileURL, kind: .web))
            }
        }
        return deduplicated(found)
    }

    // MARK: - Filesystem helpers

    /// At most `limit` direct children of `directory`, without materialising the
    /// whole directory first.
    ///
    /// `contentsOfDirectory` builds an array of EVERY entry and only then lets a
    /// cap apply, so a repo with a half-million-file directory paid for all of
    /// them before the entry budget was consulted — the budget was documented as
    /// a bound on work and wasn't one. `FileManager.enumerator` is lazy, so with
    /// `skipsSubdirectoryDescendants` it yields direct children one at a time and
    /// stops the instant the caller has enough.
    ///
    /// An unreadable directory is an empty one here, as everywhere in this file:
    /// a cosmetic lookup never surfaces an error.
    static func boundedEntries(
        of directory: URL, keys: [URLResourceKey], limit: Int
    ) -> [URL] {
        guard limit > 0 else { return [] }
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles, .skipsPackageDescendants,
                      .skipsSubdirectoryDescendants],
            errorHandler: { _, _ in true }
        ) else { return [] }
        var entries: [URL] = []
        entries.reserveCapacity(min(limit, 64))
        while entries.count < limit, let entry = enumerator.nextObject() as? URL {
            entries.append(entry)
        }
        return entries
    }

    /// A fixed relative subdirectory of the repo, or nil when ANY component of
    /// the path is a SYMLINK.
    ///
    /// The recursive walk refuses to traverse symlinks, and the final file is
    /// checked too — but the fixed-path lookups (`Resources`, `public`,
    /// `static`, `assets`, …) went straight from the root to the leaf, so a repo
    /// containing `public -> /somewhere/else` had its icon read from outside the
    /// folder the human actually linked. The repo root is the consent boundary
    /// for reads exactly as a project link is for asks; this is that boundary.
    ///
    /// `""` means the root itself, which is by definition inside itself.
    static func unlinkedDirectory(_ relative: String, inRepoRoot root: URL) -> URL? {
        var url = root
        for component in relative.split(separator: "/", omittingEmptySubsequences: true) {
            url = url.appendingPathComponent(String(component))
            var probe = url
            probe.removeAllCachedResourceValues()
            guard let values = try? probe.resourceValues(
                forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
            ), values.isSymbolicLink != true, values.isDirectory == true
            else { return nil }
        }
        return url
    }

    /// A file we are willing to hand to an image decoder: it exists, it is a
    /// REGULAR file (not a directory wearing a `.png` name), it is not a
    /// symlink, and it is small enough that decoding is cheap.
    static func isUsableImageFile(at url: URL, limits: Limits = .default) -> Bool {
        let url = freshened(url)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        ) else { return false }
        guard values.isSymbolicLink != true else { return false }
        guard values.isRegularFile == true else { return false }
        let bytes = values.fileSize ?? 0
        guard bytes > 0, bytes <= limits.maxBytes else {
            if bytes > limits.maxBytes {
                logger.info("skipping oversized icon candidate (\(bytes) bytes)")
            }
            return false
        }
        return true
    }

    static func readSmallFile(at url: URL, maxBytes: Int) -> Data? {
        let url = freshened(url)
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .isSymbolicLinkKey]
        ),
            values.isSymbolicLink != true,
            values.isRegularFile == true,
            let bytes = values.fileSize, bytes > 0, bytes <= maxBytes
        else { return nil }
        return try? Data(contentsOf: url, options: [.mappedIfSafe])
    }

    /// The cache's freshness key. nil when the file is gone — which is exactly
    /// the signal that a cached icon must be re-discovered.
    static func modificationDate(of url: URL) -> Date? {
        (try? freshened(url).resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate
    }

    /// A URL whose resource values are NOT the ones it was born with.
    ///
    /// `URL` memoises every resource value it has ever been asked for, so the
    /// URL held in the icon cache would keep answering with the mtime — and the
    /// existence — it had at discovery time, forever. That makes "re-check the
    /// cached path" a no-op that always says "unchanged": the icon would never
    /// update, and a deleted file would still look present. Every freshness
    /// probe in this file therefore goes through here.
    private static func freshened(_ url: URL) -> URL {
        var url = url
        url.removeAllCachedResourceValues()
        return url
    }
}

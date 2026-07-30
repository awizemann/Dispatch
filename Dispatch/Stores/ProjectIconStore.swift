// ProjectIconStore.swift
// The decoded-icon cache the rail cards and the bus-map stations read.
//
// WHY A STORE AND NOT A VIEW MODIFIER: an icon arrives asynchronously (a repo
// walk, off the main actor) and the same icon is drawn in two places at once —
// the rail card and the map station. One @Observable dictionary keyed by
// project id means the walk happens once and both surfaces repaint when it
// lands.
//
// NOT PERSISTED, ON PURPOSE. The repo is the source of truth for its own face:
// re-discovery costs a bounded directory walk, while image bytes in the DB
// would need their own invalidation story and would go stale the first time
// somebody redesigned their app icon. The freshness key is the source file's
// path + mtime, so a re-check is one `stat` in the common case.
//
// SCOPE: every read runs inside a `RepoBookmark.beginAccess` window, the same
// contract the git refresh and RepoMCPInstaller honour.

import AppKit
import Foundation
import ImageIO
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "icons")

// MARK: - Decoding (nonisolated: the pixels never need the main actor)

/// WHY THIS IS NOT @MainActor. Decoding an icon is pure
/// filesystem-and-CPU work — a header read, a resample, and for the rare
/// non-bitmap fallback an AppKit redraw. It used to run on the main actor for
/// one reason: `NSImage` is not `Sendable`, so it could not be returned from a
/// detached task. The rest followed: the store re-stat'ed, decoded and
/// (pre-ImageIO) `lockFocus`-redrew every project's icon on the main actor, one
/// after another, during launch.
///
/// `CGImage` IS `Sendable`, so the split is: measure and decode to a CGImage OFF
/// the main actor (`decodedPixels`), then wrap it in an `NSImage` wherever the
/// caller happens to be (`Loaded.image`). Only the vector fallback still needs
/// AppKit, and it is marked as such.
nonisolated enum ProjectIconLoader {

    /// A decoded icon in a form that can cross actor boundaries. `image` builds
    /// the `NSImage` on demand — cheap, and it means nothing non-Sendable is
    /// ever in flight.
    struct Loaded: Sendable {
        /// The decoded pixels, or nil when only the AppKit fallback could read
        /// this file (a vector source ImageIO does not measure).
        let pixels: CGImage?
        /// Set only for the AppKit fallback path, which must be built where
        /// AppKit is willing to draw.
        private let vectorURL: URL?
        let url: URL
        let modifiedAt: Date?
        let kind: ProjectIconDiscovery.Kind
        /// The candidates AFTER this one. Only the AppKit fallback can come
        /// back nil, and when it does the caller must keep looking down the
        /// list exactly as the all-on-main version did — a repo whose best
        /// candidate is an SVG nobody can rasterise still shows its second
        /// best.
        let remaining: [ProjectIconDiscovery.Candidate]

        init(pixels: CGImage?, vectorURL: URL?, url: URL,
             modifiedAt: Date?, kind: ProjectIconDiscovery.Kind,
             remaining: [ProjectIconDiscovery.Candidate] = []) {
            self.pixels = pixels
            self.vectorURL = vectorURL
            self.url = url
            self.modifiedAt = modifiedAt
            self.kind = kind
            self.remaining = remaining
        }

        /// The image to cache. nil only when this is the AppKit fallback and
        /// AppKit could not read the file either — see `remaining`.
        @MainActor var image: NSImage? {
            if let pixels {
                return NSImage(cgImage: pixels,
                               size: NSSize(width: pixels.width, height: pixels.height))
            }
            guard let vectorURL else { return nil }
            return ProjectIconLoader.appKitFallback(contentsOf: vectorURL)
        }
    }

    /// The first candidate that actually decodes into a usable image.
    ///
    /// FALLING THROUGH IS THE POINT: `favicon.svg` is a perfectly ordinary
    /// candidate that NSImage frequently cannot rasterise, and a repo whose
    /// best candidate fails must still show its second-best one rather than
    /// nothing. Same for a truncated PNG or a file that turned into a
    /// directory between the walk and the decode.
    ///
    /// Runs anywhere — the store calls it from a detached task.
    static func firstDecodable(
        _ candidates: [ProjectIconDiscovery.Candidate],
        limits: ProjectIconDiscovery.Limits = .default
    ) -> Loaded? {
        for (offset, candidate) in candidates.enumerated() {
            // Re-check on THIS side of the walk: the file may have been
            // swapped for a directory, deleted, or grown since.
            guard ProjectIconDiscovery.isUsableImageFile(at: candidate.url, limits: limits)
            else { continue }
            let rest = Array(candidates.dropFirst(offset + 1))
            switch safelyDecoded(candidate.url) {
            case .refused:
                logger.info("icon candidate did not decode; trying the next one")
                continue
            case .decoded(let pixels):
                return Loaded(
                    pixels: pixels, vectorURL: nil, url: candidate.url,
                    modifiedAt: ProjectIconDiscovery.modificationDate(of: candidate.url),
                    kind: candidate.kind, remaining: rest
                )
            case .unmeasured:
                // ImageIO has no geometry for this file (a vector source).
                // Whether AppKit can rasterise it is only answerable where
                // AppKit will draw, so the candidate is carried forward with
                // the rest of the list rather than resolved here.
                return Loaded(
                    pixels: nil, vectorURL: candidate.url, url: candidate.url,
                    modifiedAt: ProjectIconDiscovery.modificationDate(of: candidate.url),
                    kind: candidate.kind, remaining: rest
                )
            }
        }
        return nil
    }

    /// The candidate list resolved down to ONE image: the first candidate that
    /// yields pixels, falling through anything that doesn't.
    ///
    /// This is the loop, in one place. `scan` decides WHERE the (bounded,
    /// Sendable-returning) decode runs — the store hands it a detached task so
    /// nothing but the cache write touches the main actor, while a test can
    /// leave it nil and get the straight-line version. Either way the
    /// fall-through rule is the same one.
    @MainActor
    static func resolve(
        _ candidates: [ProjectIconDiscovery.Candidate],
        limits: ProjectIconDiscovery.Limits = .default,
        scan: (@Sendable ([ProjectIconDiscovery.Candidate]) async -> Loaded?)? = nil
    ) async -> (image: NSImage, loaded: Loaded)? {
        var pending = candidates
        while !pending.isEmpty {
            let found = if let scan { await scan(pending) }
                        else { firstDecodable(pending, limits: limits) }
            guard let found else { return nil }
            if let image = found.image { return (image, found) }
            // Only the AppKit fallback can land here, and only when AppKit
            // could not read it either: keep going down the list.
            pending = found.remaining
        }
        return nil
    }

    /// Decodes and normalises one file, or nil.
    ///
    /// NORMALISATION matters for `.ico` and `.icns`, which carry SEVERAL
    /// representations: NSImage's own `size` comes from the first one, which is
    /// routinely the 16×16 — drawing that at 28pt on a Retina display is the
    /// blurry-upscale bug. Picking the largest bitmap representation and
    /// restating the image's size in ITS pixels makes the tile sharp.
    /// The biggest edge worth keeping in memory. The tile draws at 28–40pt, so
    /// 256px is already 3× oversampled on a Retina display — while a 1024px
    /// `.icns` rep costs 4 MB of RAM per project for pixels nobody will ever
    /// see.
    static let maxCachedEdge = 256

    /// Refuse to DECOMPRESS beyond this many pixels. The discovery-side cap is
    /// 5 MB of FILE bytes, which a well-compressed PNG defeats completely: a
    /// 30000×30000 image fits inside it and costs gigabytes once decoded. A cap
    /// that runs after decompression is not a cap, so this one is enforced by
    /// ImageIO, which reads the header only.
    static let maxDecodedPixels = 64_000_000

    /// Decodes through ImageIO with a THUMBNAIL ceiling rather than
    /// `NSImage(contentsOf:)`, so an image whose pixel count is absurd is never
    /// fully decompressed — the header is read, the size is judged, and an
    /// oversized image is either sampled down during decode or refused.
    /// What the bounded decoder concluded. The three cases matter separately:
    /// only `unmeasured` may fall through to `NSImage`, because falling through
    /// on `refused` would hand the very image we just refused to the unbounded
    /// decoder.
    ///
    /// It yields a `CGImage`, not an `NSImage`, and that is the whole reason
    /// this decoder can run off the main actor: `CGImage` is `Sendable`.
    enum BoundedDecode: Sendable {
        case decoded(CGImage)
        /// Measured, and every representation was over the pixel cap (or the
        /// bounded decode failed): no icon, and no fallback.
        case refused
        /// ImageIO reports no geometry — a vector source. Not a refusal.
        case unmeasured
    }

    static func safelyDecoded(_ url: URL) -> BoundedDecode {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return .unmeasured }
        let count = CGImageSourceGetCount(source)
        guard count > 0 else { return .unmeasured }

        // A .ico/.icns is a CONTAINER of sizes and index 0 is routinely the
        // 16×16 — decoding that and drawing it at 28pt is the blurry-upscale
        // bug this loader exists to avoid. So judge every index by its header
        // (pixels only, no decompression) and decode the LARGEST that is within
        // the cap. An index over the cap is skipped rather than failing the
        // file: a container holding one absurd rep alongside sane ones is still
        // usable.
        var best: (index: Int, pixels: Int)?
        var sawGeometry = false
        for index in 0..<count {
            guard let header = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any],
                  let width = header[kCGImagePropertyPixelWidth] as? Int,
                  let height = header[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0
            else { continue }
            sawGeometry = true
            let pixels = width * height
            guard pixels <= maxDecodedPixels else {
                logger.error("icon rep refused: \(width, privacy: .public)x\(height, privacy: .public) exceeds the decode cap")
                continue
            }
            if best == nil || pixels > best!.pixels { best = (index, pixels) }
        }
        // No geometry at all means a format ImageIO does not measure (some
        // vector sources): fall through to NSImage, which is bounded by its own
        // nature rather than by a pixel count. Geometry that was ALL over the
        // cap is a refusal, not a fallthrough — nil here would hand the bomb
        // straight to NSImage.
        guard sawGeometry else { return .unmeasured }
        guard let winner = best else { return .refused }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxCachedEdge,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, winner.index, options as CFDictionary)
        else { return .refused }
        return .decoded(cgImage)
    }

    /// The whole decode, for callers that just want an image and are already on
    /// the main actor (tests, and nothing else — the store goes through
    /// `firstDecodable` so the ImageIO half stays off-main).
    @MainActor
    static func decode(contentsOf url: URL) -> NSImage? {
        // ImageIO first: it caps the decode by PIXELS instead of trusting the
        // file-byte cap, and it already picks the largest representation. Only
        // an unmeasurable (vector) source continues to NSImage below.
        switch safelyDecoded(url) {
        case .decoded(let pixels):
            return NSImage(cgImage: pixels,
                           size: NSSize(width: pixels.width, height: pixels.height))
        case .refused: return nil
        case .unmeasured: break
        }
        return appKitFallback(contentsOf: url)
    }

    /// The LAST resort: a source ImageIO reported no geometry for, handed to
    /// AppKit. Main-actor because `NSImage`/`lockFocus` are, and unbounded by a
    /// pixel cap — which is only acceptable because ImageIO already refused
    /// everything it *could* measure before we got here.
    @MainActor
    static func appKitFallback(contentsOf url: URL) -> NSImage? {
        guard let image = NSImage(contentsOf: url) else { return nil }
        let bitmaps = image.representations.compactMap { $0 as? NSBitmapImageRep }
        if let largest = bitmaps.max(by: { $0.pixelsWide * $0.pixelsHigh < $1.pixelsWide * $1.pixelsHigh }),
           largest.pixelsWide > 0, largest.pixelsHigh > 0 {
            let normalized = NSImage(size: NSSize(width: largest.pixelsWide, height: largest.pixelsHigh))
            normalized.addRepresentation(largest)
            return downsampledIfHuge(normalized)
        }
        // Vector / non-bitmap reps (a PDF rep, or an SVG NSImage managed to
        // build): usable as-is provided it has a real size.
        guard image.size.width > 0, image.size.height > 0, !image.representations.isEmpty
        else { return nil }
        return image
    }

    /// Redraws an oversized icon at `maxCachedEdge`, preserving aspect ratio.
    /// Returns the original untouched when it is already small enough — the
    /// common case, and the one that must not pay for this.
    @MainActor
    static func downsampledIfHuge(_ image: NSImage) -> NSImage {
        let width = image.size.width
        let height = image.size.height
        let longest = max(width, height)
        guard longest > CGFloat(maxCachedEdge), width > 0, height > 0 else { return image }
        let scale = CGFloat(maxCachedEdge) / longest
        let target = NSSize(width: (width * scale).rounded(), height: (height * scale).rounded())
        let scaled = NSImage(size: target)
        scaled.lockFocus()
        NSGraphicsContext.current?.imageInterpolation = .high
        image.draw(
            in: NSRect(origin: .zero, size: target),
            from: NSRect(origin: .zero, size: image.size),
            operation: .copy, fraction: 1
        )
        scaled.unlockFocus()
        return scaled
    }
}

// MARK: - Store

@MainActor
@Observable
final class ProjectIconStore {

    /// One cached icon plus everything needed to know it is still current.
    struct Entry {
        var image: NSImage
        /// The file the image came from.
        var sourceURL: URL
        var modifiedAt: Date?
        var kind: ProjectIconDiscovery.Kind
    }

    /// The observable surface the views read. Keyed by project id.
    private(set) var entries: [UUID: Entry] = [:]

    /// Projects whose repo has already been walked and offered nothing. Keeps a
    /// re-check from re-walking a repo with no icon on every selection.
    @ObservationIgnored private var knownEmpty: Set<UUID> = []
    @ObservationIgnored private var inFlight: Set<UUID> = []
    /// When each project was last WALKED. A project with no icon has no cached
    /// path to stat, so this is what stops "re-check on selection" from turning
    /// every click into a fresh directory walk.
    @ObservationIgnored private var lastWalkAt: [UUID: Date] = [:]
    /// Icons planted by the scripted scenario rather than found on disk.
    @ObservationIgnored private var seededIDs: Set<UUID> = []

    /// How long a "this repo has no icon" answer is trusted before a selection
    /// or modal open will look again.
    @ObservationIgnored var emptyRecheckInterval: TimeInterval = 120

    /// Bounds for the walk; overridable in tests.
    @ObservationIgnored var limits: ProjectIconDiscovery.Limits = .default

    /// Resolves a project's repo folder. Injected because bookmark resolution
    /// lives in ProjectStore and the mock composition has no real folders at
    /// all. Returning nil means "don't look" — the letter tile stands.
    @ObservationIgnored var repoURLProvider: ((UUID) async -> URL?)?

    init() {}

    /// The one thing the views call.
    func icon(for projectID: UUID) -> NSImage? {
        entries[projectID]?.image
    }

    // MARK: - Discovery entry points

    /// Launch, and every time the registry gains rows: walk anything not yet
    /// known. Cheap for projects already cached (a `stat`).
    ///
    /// CONCURRENT, BOUNDED. Each refresh is mostly a detached
    /// directory walk plus an off-main decode, so running them one at a time
    /// made launch cost the SUM of every repo's walk. Refreshes now go out a
    /// batch at a time so those walks overlap; the batch is deliberately small
    /// rather than "one task per project", because a switchboard with forty
    /// repos should not answer a launch by pointing forty concurrent walks at
    /// the disk.
    func refreshAll(projectIDs: [UUID]) async {
        var start = 0
        while start < projectIDs.count {
            let batch = Array(projectIDs[start..<min(start + Self.refreshWindow,
                                                     projectIDs.count)])
            var batchTasks: [Task<Void, Never>] = []
            for projectID in batch {
                batchTasks.append(Task { @MainActor in
                    await self.refresh(projectID: projectID)
                })
            }
            for task in batchTasks { await task.value }
            start += Self.refreshWindow
        }
    }

    /// How many project refreshes may be in flight at once.
    static let refreshWindow = 4

    /// Selection and modal open: re-check ONE project. If the cached source
    /// file is still there with the same mtime this is a single `stat` and
    /// returns without touching the filesystem again.
    func recheck(projectID: UUID, now: Date = .now) async {
        if let entry = entries[projectID] {
            let stillThere = ProjectIconDiscovery.isUsableImageFile(
                at: entry.sourceURL, limits: limits
            )
            let current = ProjectIconDiscovery.modificationDate(of: entry.sourceURL)
            // The cheap path, and the common one: one stat, same mtime, done.
            if stillThere, current == entry.modifiedAt { return }
            // Source changed, vanished, or turned into something we won't read.
            // The cached image is NOT dropped yet — dropping it here would
            // flash the letter tile before the replacement lands.
            await refresh(projectID: projectID, force: true, now: now)
            return
        }
        guard let last = lastWalkAt[projectID],
              now.timeIntervalSince(last) < emptyRecheckInterval
        else {
            await refresh(projectID: projectID, force: true, now: now)
            return
        }
    }

    /// Full re-discovery for one project. Without `force` it is a no-op for a
    /// project that is already cached or already known to have nothing.
    func refresh(projectID: UUID, force: Bool = false, now: Date = .now) async {
        if !force {
            guard entries[projectID] == nil, !knownEmpty.contains(projectID) else { return }
        }
        // A seeded icon is the scripted scenario's own fixture; no filesystem
        // answer may overwrite or clear it.
        guard !seededIDs.contains(projectID) else { return }
        guard inFlight.insert(projectID).inserted else { return }
        defer { inFlight.remove(projectID) }
        lastWalkAt[projectID] = now

        // No provider at all = discovery isn't wired in this composition (the
        // scripted mock). Leave everything, including seeded icons, alone.
        guard let repoURLProvider else { return }
        guard let repoURL = await repoURLProvider(projectID) else {
            // A provider that can't resolve the folder: the repo moved or was
            // deleted while its icon sat in the cache.
            knownEmpty.insert(projectID)
            entries[projectID] = nil
            return
        }
        let limits = limits
        // The walk is filesystem-bound and can touch thousands of entries and
        // the DECODE is ImageIO work over megabytes, so both run OFF the main
        // actor: only a Sendable CGImage (or, for a vector source, a URL) comes
        // back. The main actor's whole job here is the cache write.
        let candidates = await Task.detached(priority: .utility) { () -> [ProjectIconDiscovery.Candidate] in
            let access = RepoBookmark.beginAccess(repoURL)
            defer { access.end() }
            return ProjectIconDiscovery.candidates(inRepoRoot: repoURL, limits: limits)
        }.value

        // The main-actor window covers only the rare AppKit fallback inside
        // `resolve`; the ImageIO decode opens its own inside the detached scan.
        let access = RepoBookmark.beginAccess(repoURL)
        defer { access.end() }
        let resolved = await ProjectIconLoader.resolve(candidates, limits: limits) { pending in
            await Task.detached(priority: .utility) { () -> ProjectIconLoader.Loaded? in
                let inner = RepoBookmark.beginAccess(repoURL)
                defer { inner.end() }
                return ProjectIconLoader.firstDecodable(pending, limits: limits)
            }.value
        }
        guard let resolved else {
            // Nothing (any more): the letter tile is the honest answer, so a
            // stale cached image is dropped here rather than kept as a lie.
            knownEmpty.insert(projectID)
            entries[projectID] = nil
            return
        }
        knownEmpty.remove(projectID)
        entries[projectID] = Entry(
            image: resolved.image, sourceURL: resolved.loaded.url,
            modifiedAt: resolved.loaded.modifiedAt, kind: resolved.loaded.kind
        )
    }

    /// Registry pruning: a deleted project's icon must not outlive it (and its
    /// id must not be remembered as "empty" either, in case the id is reused).
    ///
    /// EVERY per-project map, not just the two obvious ones.
    /// Leaving `seededIDs` behind was the sharp one: a reused id inherits a
    /// stale "this icon is the mock's fixture" flag, and `refresh` returns
    /// early forever — the real repo's icon is never discovered. That is
    /// precisely the id-reuse case this method's own comment claims to defend
    /// against. `lastWalkAt` is unbounded growth rather than wrongness, but it
    /// is keyed the same way and goes the same way.
    ///
    /// `inFlight` is deliberately NOT swept: it is inserted and removed inside a
    /// single `refresh` call, so it cannot leak — and clearing an entry whose
    /// refresh is still running would re-open the door the marker is holding
    /// shut.
    func prune(knownProjectIDs: Set<UUID>) {
        entries = entries.filter { knownProjectIDs.contains($0.key) }
        knownEmpty.formIntersection(knownProjectIDs)
        seededIDs.formIntersection(knownProjectIDs)
        lastWalkAt = lastWalkAt.filter { knownProjectIDs.contains($0.key) }
    }

    // MARK: - Mock seeding

    /// The scripted scenario has no repos on disk, so the mixed icon/letter
    /// state it must demonstrate is seeded with images DRAWN IN CODE — never
    /// read from a path that exists only on one machine.
    func seed(_ image: NSImage, for projectID: UUID) {
        entries[projectID] = Entry(
            image: image,
            sourceURL: URL(fileURLWithPath: "/dev/null"),
            modifiedAt: nil,
            kind: .appIcon
        )
        knownEmpty.remove(projectID)
        seededIDs.insert(projectID)
    }
}

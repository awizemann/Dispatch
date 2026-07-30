// ProjectIconDiscoveryTests.swift
// Project icon discovery, against real temp-directory fixtures.
//
// Everything here is a fixture on disk rather than a mocked filesystem, because
// the failure modes worth catching are filesystem facts: a symlink loop, a file
// that turned into a directory, a Contents.json that references a PNG nobody
// shipped. A fake FS would happily pass all of those.
//
// The rule the whole feature turns on: discovery FAILS CLOSED. Every malformed,
// hostile, or absent case must produce "no icon" — the letter tile — and never
// an error, a hang, or a wrong picture.

import AppKit
import Foundation
import Testing

@testable import DispatchApp

// MARK: - Fixtures

private enum Repo {

    /// A fresh temp repo root. Callers remove it in a defer.
    static func make(_ label: String = "repo") throws -> URL {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dispatch-icon-\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    @discardableResult
    static func directory(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real, decodable PNG of the given pixel size.
    @discardableResult
    static func png(at url: URL, side: Int) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try pngData(width: side, height: side).write(to: url)
        return url
    }

    /// A PNG that DECLARES enormous dimensions in its IHDR without carrying the
    /// pixels — the shape of a decompression bomb, in a few hundred bytes. Only
    /// the header has to be well formed: the cap under test is enforced from
    /// ImageIO's header read, before any decompression is attempted.
    static func pngDeclaring(width: Int, height: Int) -> Data {
        func crc(_ bytes: [UInt8]) -> UInt32 {
            var table = [UInt32](repeating: 0, count: 256)
            for index in 0..<256 {
                var value = UInt32(index)
                for _ in 0..<8 {
                    value = (value & 1 == 1) ? (0xEDB8_8320 ^ (value >> 1)) : (value >> 1)
                }
                table[index] = value
            }
            var value: UInt32 = 0xFFFF_FFFF
            for byte in bytes {
                value = table[Int((value ^ UInt32(byte)) & 0xFF)] ^ (value >> 8)
            }
            return value ^ 0xFFFF_FFFF
        }
        func be32(_ value: UInt32) -> [UInt8] {
            [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF),
             UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
        }
        func chunk(_ type: String, _ payload: [UInt8]) -> [UInt8] {
            let typed = Array(type.utf8) + payload
            return be32(UInt32(payload.count)) + typed + be32(crc(typed))
        }
        let ihdr = be32(UInt32(width)) + be32(UInt32(height))
            + [8, 6, 0, 0, 0]  // 8-bit RGBA, no interlace
        var bytes: [UInt8] = [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]
        bytes += chunk("IHDR", ihdr)
        bytes += chunk("IDAT", [0x78, 0x9C, 0x03, 0x00, 0x00, 0x00, 0x00, 0x01])
        bytes += chunk("IEND", [])
        return Data(bytes)
    }

    static func pngData(width: Int, height: Int) throws -> Data {
        let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        )!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        NSColor.systemBlue.setFill()
        NSRect(x: 0, y: 0, width: width, height: height).fill()
        NSGraphicsContext.restoreGraphicsState()
        guard let data = rep.representation(using: .png, properties: [:]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        return data
    }

    /// An `AppIcon.appiconset` with the given Contents.json body.
    @discardableResult
    static func appIconSet(
        in root: URL, path: String = "Dispatch/Assets.xcassets/AppIcon.appiconset",
        contents: String
    ) throws -> URL {
        let setURL = try directory(root.appendingPathComponent(path))
        try contents.data(using: .utf8)!
            .write(to: setURL.appendingPathComponent("Contents.json"))
        return setURL
    }

    /// A well-formed Contents.json referencing three sizes.
    static func contentsJSON(_ entries: [(String, String, String)]) -> String {
        let images = entries.map { filename, size, scale in
            """
            {"filename":"\(filename)","idiom":"mac","size":"\(size)","scale":"\(scale)"}
            """
        }.joined(separator: ",")
        return #"{"images":[\#(images)],"info":{"author":"xcode","version":1}}"#
    }

    /// A chain of nested directories, returning the deepest one.
    @discardableResult
    static func chain(from root: URL, depth: Int) throws -> URL {
        var url = root
        for level in 0..<depth {
            url = url.appendingPathComponent("level\(level)")
        }
        return try directory(url)
    }
}

// MARK: - Contents.json parsing (pure)

@Suite("AppIcon Contents.json parsing")
struct AppIconContentsTests {

    @Test("Entries come back largest first, size × scale")
    func sortsBySizeTimesScale() {
        let json = Repo.contentsJSON([
            ("small.png", "16x16", "1x"),
            ("huge.png", "512x512", "2x"),   // 1024
            ("medium.png", "256x256", "1x"),
        ])
        let entries = ProjectIconDiscovery.appIconEntries(fromContentsJSON: Data(json.utf8))
        #expect(entries.map(\.filename) == ["huge.png", "medium.png", "small.png"])
        #expect(entries.first?.pixels == 1_024)
    }

    @Test("Unassigned slots and non-PNG entries are ignored, not fatal")
    func skipsUnassignedSlots() {
        let json = #"""
        {"images":[
          {"idiom":"mac","size":"16x16","scale":"1x"},
          {"filename":"icon.pdf","idiom":"mac","size":"32x32","scale":"1x"},
          {"filename":"real.png","idiom":"mac","size":"64x64","scale":"1x"}
        ],"info":{"version":1}}
        """#
        let entries = ProjectIconDiscovery.appIconEntries(fromContentsJSON: Data(json.utf8))
        #expect(entries.map(\.filename) == ["real.png"])
    }

    @Test("Malformed JSON yields no entries rather than throwing")
    func malformedJSONIsEmpty() {
        #expect(ProjectIconDiscovery.appIconEntries(fromContentsJSON: Data("{not json".utf8)).isEmpty)
        #expect(ProjectIconDiscovery.appIconEntries(fromContentsJSON: Data()).isEmpty)
        #expect(ProjectIconDiscovery.appIconEntries(
            fromContentsJSON: Data(#"{"images":"nope"}"#.utf8)
        ).isEmpty)
    }

    @Test("Missing or garbage size/scale degrade to 1 instead of vanishing")
    func degradesUnparseableDimensions() {
        #expect(ProjectIconDiscovery.parseSizeDimension("512x512") == 512)
        #expect(ProjectIconDiscovery.parseSizeDimension(nil) == 1)
        #expect(ProjectIconDiscovery.parseSizeDimension("banana") == 1)
        #expect(ProjectIconDiscovery.parseScale("3x") == 3)
        #expect(ProjectIconDiscovery.parseScale(nil) == 1)
    }

    @Test("Skip rules cover build output, dependencies and hidden trees")
    func skipRules() {
        for name in ["DerivedData", "node_modules", ".git", "build", "Pods", ".build"] {
            #expect(ProjectIconDiscovery.shouldSkip(directoryNamed: name), "\(name) must be skipped")
        }
        #expect(ProjectIconDiscovery.shouldSkip(directoryNamed: "Dispatch.xcodeproj"))
        #expect(ProjectIconDiscovery.shouldSkip(directoryNamed: "Dispatch.app"))
        #expect(!ProjectIconDiscovery.shouldSkip(directoryNamed: "Sources"))
        #expect(ProjectIconDiscovery.isAppIconSet(directoryNamed: "AppIcon.appiconset"))
        #expect(ProjectIconDiscovery.isAppIconSet(directoryNamed: "AppIcon-Beta.appiconset"))
        #expect(!ProjectIconDiscovery.isAppIconSet(directoryNamed: "Logo.appiconset"))
    }
}

// MARK: - Asset catalogs

@Suite("Asset catalog discovery")
struct AppIconSetDiscoveryTests {

    @Test("Picks the largest PNG the Contents.json references AND that exists")
    func picksLargestExistingPNG() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let set = try Repo.appIconSet(in: root, contents: Repo.contentsJSON([
            ("icon_512@2x.png", "512x512", "2x"),   // 1024 — REFERENCED BUT ABSENT
            ("icon_256.png", "256x256", "1x"),      // 256  — present, the winner
            ("icon_32.png", "32x32", "1x"),
        ]))
        try Repo.png(at: set.appendingPathComponent("icon_256.png"), side: 256)
        try Repo.png(at: set.appendingPathComponent("icon_32.png"), side: 32)

        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        #expect(candidates.first?.kind == .appIcon)
        #expect(candidates.first?.url.lastPathComponent == "icon_256.png")
    }

    @Test("Finds a catalog nested a few levels down")
    func findsNestedCatalog() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let set = try Repo.appIconSet(
            in: root, path: "apps/mac/Sources/Resources/Media.xcassets/AppIcon.appiconset",
            contents: Repo.contentsJSON([("icon.png", "128x128", "1x")])
        )
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 128)
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).first?.kind == .appIcon)
    }

    @Test("Build output, dependency trees and hidden directories are never entered")
    func respectsSkipDirectories() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        for skipped in ["node_modules", "DerivedData", "build", ".git", "Pods"] {
            let set = try Repo.appIconSet(
                in: root, path: "\(skipped)/Assets.xcassets/AppIcon.appiconset",
                contents: Repo.contentsJSON([("icon.png", "512x512", "1x")])
            )
            try Repo.png(at: set.appendingPathComponent("icon.png"), side: 64)
        }
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).isEmpty)
    }

    @Test("A catalog past the depth cap is not found; raising the cap finds it")
    func honoursDepthCap() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let deep = try Repo.chain(from: root, depth: 9)
        let set = try Repo.appIconSet(
            in: deep, path: "Assets.xcassets/AppIcon.appiconset",
            contents: Repo.contentsJSON([("icon.png", "128x128", "1x")])
        )
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 128)

        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root).isEmpty)

        var generous = ProjectIconDiscovery.Limits.default
        generous.maxDepth = 20
        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root, limits: generous).count == 1)
    }

    @Test("The entry budget stops the walk even inside the depth cap")
    func honoursEntryCap() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let deep = try Repo.chain(from: root, depth: 4)
        let set = try Repo.appIconSet(
            in: deep, path: "Assets.xcassets/AppIcon.appiconset",
            contents: Repo.contentsJSON([("icon.png", "128x128", "1x")])
        )
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 128)

        // Reachable with the normal budget…
        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root).count == 1)
        // …and abandoned once the walk has looked at three entries.
        var tight = ProjectIconDiscovery.Limits.default
        tight.maxEntries = 3
        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root, limits: tight).isEmpty)
    }

    @Test("Two catalogs: the bigger icon wins")
    func largestCatalogWins() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let small = try Repo.appIconSet(
            in: root, path: "Sample/Assets.xcassets/AppIcon.appiconset",
            contents: Repo.contentsJSON([("icon.png", "64x64", "1x")])
        )
        try Repo.png(at: small.appendingPathComponent("icon.png"), side: 64)
        let big = try Repo.appIconSet(
            in: root, path: "App/Assets.xcassets/AppIcon.appiconset",
            contents: Repo.contentsJSON([("icon.png", "512x512", "1x")])
        )
        try Repo.png(at: big.appendingPathComponent("icon.png"), side: 512)

        let first = try #require(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root).first)
        #expect(first.url.path.contains("/App/"))
    }

    @Test("Unreadable or malformed Contents.json yields no icon, no throw")
    func malformedContentsFailsClosed() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let set = try Repo.appIconSet(in: root, contents: "{ this is not json")
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 256)
        // The PNG is RIGHT THERE, but nothing references it — a catalog whose
        // manifest we can't read is a catalog we don't guess about.
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).isEmpty)
    }

    @Test("A Contents.json filename that climbs out of the set is refused")
    func refusesPathTraversal() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("outside.png"), side: 256)
        try Repo.appIconSet(in: root, contents: Repo.contentsJSON([
            ("../../../outside.png", "512x512", "1x"),
        ]))
        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root).isEmpty)
    }
}

// MARK: - .icns and web icons

@Suite("icns and favicon discovery")
struct LooseIconDiscoveryTests {

    @Test("An .icns at the repo root is found")
    func findsRootICNS() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        // Content doesn't have to be a real icns for DISCOVERY — the loader is
        // what decides whether it decodes. Discovery's job is candidacy.
        try Data(repeating: 0x69, count: 4_096)
            .write(to: root.appendingPathComponent("App.icns"))
        let candidates = ProjectIconDiscovery.icnsCandidates(inRepoRoot: root)
        #expect(candidates.map(\.url.lastPathComponent) == ["App.icns"])
        #expect(candidates.first?.kind == .icns)
    }

    @Test("Resources/ is searched too, and the larger .icns wins")
    func findsResourcesICNSLargestFirst() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Data(repeating: 0x1, count: 1_024)
            .write(to: root.appendingPathComponent("Small.icns"))
        try Repo.directory(root.appendingPathComponent("Resources"))
        try Data(repeating: 0x1, count: 64_000)
            .write(to: root.appendingPathComponent("Resources/Big.icns"))
        let candidates = ProjectIconDiscovery.icnsCandidates(inRepoRoot: root)
        #expect(candidates.map(\.url.lastPathComponent) == ["Big.icns", "Small.icns"])
    }

    @Test("Web icons come back in priority order, apple-touch-icon first")
    func webPriorityOrder() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)
        try Repo.png(at: root.appendingPathComponent("favicon.ico"), side: 16)
        try Repo.png(at: root.appendingPathComponent("public/apple-touch-icon.png"), side: 180)

        let names = ProjectIconDiscovery.webCandidates(inRepoRoot: root)
            .map { $0.url.lastPathComponent }
        // apple-touch-icon in public/ outranks a favicon at the ROOT: the name
        // is the priority, the directory only breaks ties within a name.
        #expect(names.first == "apple-touch-icon.png")
        #expect(names.last == "favicon.ico")
    }

    @Test("static/ and src/ are searched as well as public/")
    func searchesConventionalWebDirectories() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("static/favicon.png"), side: 48)
        #expect(ProjectIconDiscovery.webCandidates(inRepoRoot: root).count == 1)
    }

    @Test("An app icon beats an .icns beats a favicon")
    func overallPriority() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)
        try Data(repeating: 0x1, count: 2_048).write(to: root.appendingPathComponent("A.icns"))
        let set = try Repo.appIconSet(in: root, contents: Repo.contentsJSON([
            ("icon.png", "512x512", "1x"),
        ]))
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 512)

        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).map(\.kind)
                == [.appIcon, .icns, .web])
    }

    @Test("A repo with no icon at all yields nothing (the letter tile stands)")
    func emptyRepoYieldsNothing() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("Sources/screenshot.png"), side: 64)
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).isEmpty)
    }

    @Test("A path that isn't a directory at all is not an error")
    func missingRepoIsNotAnError() {
        let root = URL(fileURLWithPath: "/nope/does/not/exist-\(UUID().uuidString)")
        #expect(ProjectIconDiscovery.candidates(inRepoRoot: root).isEmpty)
    }
}

// MARK: - Adversarial

@Suite("Adversarial repos")
struct AdversarialIconTests {

    @Test("A symlink loop does not hang the walk, and the real icon still lands")
    func symlinkLoopIsNotFollowed() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let set = try Repo.appIconSet(in: root, contents: Repo.contentsJSON([
            ("icon.png", "256x256", "1x"),
        ]))
        try Repo.png(at: set.appendingPathComponent("icon.png"), side: 256)
        // loop/back → the repo root; and root/self → the repo root.
        let loop = try Repo.directory(root.appendingPathComponent("loop"))
        try FileManager.default.createSymbolicLink(
            at: loop.appendingPathComponent("back"), withDestinationURL: root
        )
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("self"), withDestinationURL: root
        )

        let candidates = ProjectIconDiscovery.appIconCandidates(inRepoRoot: root)
        #expect(candidates.count == 1)
    }

    @Test("A symlinked appiconset is not a candidate")
    func symlinkedAppIconSetIgnored() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let other = try Repo.make("elsewhere")
        defer { Repo.remove(other) }
        let set = try Repo.appIconSet(in: other, path: "AppIcon.appiconset",
                                      contents: Repo.contentsJSON([("i.png", "64x64", "1x")]))
        try Repo.png(at: set.appendingPathComponent("i.png"), side: 64)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("AppIcon.appiconset"), withDestinationURL: set
        )
        #expect(ProjectIconDiscovery.appIconCandidates(inRepoRoot: root).isEmpty)
    }

    @Test("A 6 MB favicon.png is never opened")
    func oversizedFaviconIsSkipped() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Data(count: 6 * 1_024 * 1_024)
            .write(to: root.appendingPathComponent("favicon.png"))
        #expect(ProjectIconDiscovery.webCandidates(inRepoRoot: root).isEmpty)

        // The cap is a cap, not a ban: raise it and the file becomes a
        // candidate again (it still has to DECODE to be shown).
        var generous = ProjectIconDiscovery.Limits.default
        generous.maxBytes = 32 * 1_024 * 1_024
        #expect(ProjectIconDiscovery.webCandidates(inRepoRoot: root, limits: generous).count == 1)
    }

    @Test("An icon path that is actually a directory is not a candidate")
    func directoryWearingAnIconName() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.directory(root.appendingPathComponent("favicon.png"))
        try Repo.directory(root.appendingPathComponent("App.icns"))
        #expect(ProjectIconDiscovery.webCandidates(inRepoRoot: root).isEmpty)
        #expect(ProjectIconDiscovery.icnsCandidates(inRepoRoot: root).isEmpty)
    }

    @Test("A zero-byte icon is not a candidate")
    func emptyFileIsNotACandidate() throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Data().write(to: root.appendingPathComponent("favicon.png"))
        #expect(ProjectIconDiscovery.webCandidates(inRepoRoot: root).isEmpty)
    }
}

// MARK: - Decoding

@MainActor
@Suite("Icon decoding")
struct ProjectIconLoaderTests {

    @Test("An undecodable candidate falls through to the next one")
    func fallsThroughUndecodableCandidate() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        // favicon.svg outranks favicon.png in the candidate list, but this one
        // is not renderable — the tile must show the PNG, not nothing.
        try Data("<svg>this is not actually parseable".utf8)
            .write(to: root.appendingPathComponent("favicon.svg"))
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 96)

        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        #expect(candidates.first?.url.lastPathComponent == "favicon.svg")
        let resolved = try #require(await ProjectIconLoader.resolve(candidates))
        #expect(resolved.loaded.url.lastPathComponent == "favicon.png")
        #expect(resolved.image.size.width == 96)
    }

    /// The audit case the FILE-BYTE cap could not catch. A well-compressed PNG
    /// of absurd dimensions sits far under 5 MB on disk and costs gigabytes the
    /// moment it is decompressed, so the ceiling has to be enforced on PIXELS,
    /// by a decoder that reads the header first.
    @Test("A decompression bomb is refused on its pixel count, not its file size")
    func decompressionBombIsRefused() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        // The fixture DECLARES 20000×20000 (400M pixels, ~1.6 GB decoded) in a
        // few hundred bytes. It is hand-built rather than rendered for the same
        // reason the cap exists: allocating the bomb to prove we refuse the
        // bomb would be the bug.
        let bomb = Repo.pngDeclaring(width: 20_000, height: 20_000)
        #expect(bomb.count < ProjectIconDiscovery.Limits.default.maxBytes,
                "the fixture must pass the byte cap, or it proves nothing")
        let url = root.appendingPathComponent("favicon.png")
        try bomb.write(to: url)

        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        #expect(!candidates.isEmpty, "discovery still offers it; the DECODER is the gate")
        #expect(await ProjectIconLoader.resolve(candidates)?.image == nil)
    }

    @Test("A large but sane icon still decodes, capped to the cached edge")
    func largeButSaneIconDecodes() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 1_024)

        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        let resolved = try #require(await ProjectIconLoader.resolve(candidates))
        #expect(max(resolved.image.size.width, resolved.image.size.height)
                <= CGFloat(ProjectIconLoader.maxCachedEdge))
    }

    @Test("Every candidate failing to decode means no icon, not a crash")
    func allUndecodableYieldsNil() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Data(repeating: 0x7, count: 2_048)
            .write(to: root.appendingPathComponent("favicon.png"))
        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        #expect(!candidates.isEmpty)
        #expect(await ProjectIconLoader.resolve(candidates)?.image == nil)
    }

    @Test("A multi-representation file decodes at its LARGEST size, not its first")
    func multiRepresentationPicksLargest() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        // A .ico is a container of several sizes and NSImage reports the FIRST
        // one as its size — drawing that at 28pt is the blurry-upscale bug.
        // A multi-page TIFF is the same shape of container and is one AppKit
        // can be asked to WRITE, so it is what the fixture uses; the
        // normalisation under test is format-independent.
        let small = NSBitmapImageRep(data: try Repo.pngData(width: 16, height: 16))!
        let large = NSBitmapImageRep(data: try Repo.pngData(width: 256, height: 256))!
        let data = try #require(NSBitmapImageRep.representationOfImageReps(
            in: [small, large], using: .tiff, properties: [:]
        ))
        let url = root.appendingPathComponent("favicon.ico")
        try data.write(to: url)

        let image = try #require(ProjectIconLoader.decode(contentsOf: url))
        #expect(image.size.width == 256)
        #expect(image.size.height == 256)
    }

    @Test("An enormous icon is cached at a sane size, not at 1024px")
    func downsamplesHugeIcons() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 1_024)
        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        let resolved = try #require(await ProjectIconLoader.resolve(candidates))
        #expect(resolved.image.size.width == CGFloat(ProjectIconLoader.maxCachedEdge))
    }

    @Test("A non-square icon keeps its aspect ratio through downsampling")
    func downsamplingPreservesAspect() throws {
        let source = NSImage(data: try Repo.pngData(width: 1_024, height: 512))!
        let scaled = ProjectIconLoader.downsampledIfHuge(source)
        #expect(scaled.size.width == 256)
        #expect(scaled.size.height == 128)
    }

    @Test("A candidate that became a directory between walk and decode is skipped")
    func candidateReplacedByDirectory() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let faviconURL = root.appendingPathComponent("favicon.png")
        try Repo.png(at: faviconURL, side: 64)
        let candidates = ProjectIconDiscovery.candidates(inRepoRoot: root)
        #expect(candidates.count == 1)

        try FileManager.default.removeItem(at: faviconURL)
        try Repo.directory(faviconURL)
        #expect(await ProjectIconLoader.resolve(candidates)?.image == nil)
    }
}

// MARK: - Cache lifecycle

@MainActor
@Suite("Icon cache lifecycle")
struct ProjectIconStoreTests {

    private func store(for root: URL?) -> ProjectIconStore {
        let store = ProjectIconStore()
        store.repoURLProvider = { _ in root }
        return store
    }

    @Test("Discovery lands the icon in the cache")
    func discoversAndCaches() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)

        let store = store(for: root)
        let id = UUID()
        await store.refresh(projectID: id)
        #expect(store.icon(for: id)?.size.width == 64)
    }

    @Test("A repo with no icon caches the absence and keeps the letter tile")
    func cachesAbsence() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let store = store(for: root)
        let id = UUID()
        await store.refresh(projectID: id)
        #expect(store.icon(for: id) == nil)
    }

    @Test("A changed source file (new mtime) is picked up on re-check")
    func invalidatesOnModificationDate() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        let faviconURL = root.appendingPathComponent("favicon.png")
        try Repo.png(at: faviconURL, side: 64)

        let store = store(for: root)
        let id = UUID()
        await store.refresh(projectID: id)
        #expect(store.icon(for: id)?.size.width == 64)

        // Same path, different picture, later mtime — the repo redesigned.
        try Repo.pngData(width: 256, height: 256).write(to: faviconURL)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: faviconURL.path
        )
        await store.recheck(projectID: id)
        #expect(store.icon(for: id)?.size.width == 256)
    }

    @Test("An unchanged source file survives a re-check untouched")
    func unchangedSourceSurvivesRecheck() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)
        let store = store(for: root)
        let id = UUID()
        await store.refresh(projectID: id)
        let first = try #require(store.icon(for: id))
        await store.recheck(projectID: id)
        #expect(store.icon(for: id) === first)
    }

    @Test("A repo deleted under a cached icon drops the icon")
    func repoDeletedWhileCached() async throws {
        let root = try Repo.make()
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)
        let store = ProjectIconStore()
        let id = UUID()
        // The provider answers only while the folder is there — exactly what
        // ProjectStore.existingRepoURL does.
        nonisolated(unsafe) var folderExists = true
        store.repoURLProvider = { _ in folderExists ? root : nil }
        await store.refresh(projectID: id)
        #expect(store.icon(for: id) != nil)

        Repo.remove(root)
        folderExists = false
        await store.recheck(projectID: id)
        #expect(store.icon(for: id) == nil)
    }

    @Test("Pruning drops icons for projects that no longer exist")
    func prunesDeletedProjects() async throws {
        let root = try Repo.make()
        defer { Repo.remove(root) }
        try Repo.png(at: root.appendingPathComponent("favicon.png"), side: 64)
        let store = store(for: root)
        let kept = UUID()
        let deleted = UUID()
        await store.refresh(projectID: kept)
        await store.refresh(projectID: deleted)
        #expect(store.icon(for: deleted) != nil)

        store.prune(knownProjectIDs: [kept])
        #expect(store.icon(for: kept) != nil)
        #expect(store.icon(for: deleted) == nil)
    }

    @Test("With no repo-URL provider wired, seeded mock icons are left alone")
    func seededIconsSurviveRefresh() async {
        let store = ProjectIconStore()
        let id = UUID()
        store.seed(NSImage(size: NSSize(width: 32, height: 32)), for: id)
        await store.refresh(projectID: id)
        await store.recheck(projectID: id)
        #expect(store.icon(for: id) != nil)
    }
}

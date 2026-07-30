// WindowFrameClampTests.swift
// Off-screen-restore safety for the persisted window frame:
// a frame restored onto a now-disconnected display must be re-centered on a
// visible screen; a frame still on-screen must pass through untouched. Pure
// geometry — no NSWindow, no I/O.

import CoreGraphics
import Foundation
import Testing
@testable import DispatchApp

@Suite("Window frame clamp")
struct WindowFrameClampTests {
    // A typical single 1440-wide display's visible frame (menu bar excluded).
    private let mainScreen = CGRect(x: 0, y: 0, width: 1440, height: 875)
    private let defaultFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)

    @Test("fully on-screen frame passes through unchanged")
    func onScreenUnchanged() {
        let frame = CGRect(x: 100, y: 80, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen],
            fallbackScreen: mainScreen,
            defaultFrame: defaultFrame
        )
        #expect(result == frame)
    }

    @Test("frame on a disconnected display is re-centered on the fallback")
    func offScreenRecenters() {
        // Saved on a second monitor to the right that is now gone.
        let frame = CGRect(x: 3000, y: 200, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen],
            fallbackScreen: mainScreen,
            defaultFrame: defaultFrame
        )
        // Same size, centered on the visible screen.
        #expect(result.size == frame.size)
        #expect(abs(result.midX - mainScreen.midX) < 0.5)
        #expect(abs(result.midY - mainScreen.midY) < 0.5)
    }

    @Test("frame overlapping a screen by only a sliver is treated as off-screen")
    func slverIsOffScreen() {
        // Only ~10pt pokes back onto the main screen — below minVisible.
        let frame = CGRect(x: 1430, y: 200, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen],
            fallbackScreen: mainScreen,
            defaultFrame: defaultFrame
        )
        #expect(result != frame)
        #expect(abs(result.midX - mainScreen.midX) < 0.5)
    }

    @Test("frame reachable on a secondary screen passes through")
    func reachableOnSecondary() {
        let secondary = CGRect(x: 1440, y: 0, width: 1920, height: 1055)
        let frame = CGRect(x: 1600, y: 100, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen, secondary],
            fallbackScreen: mainScreen,
            defaultFrame: defaultFrame
        )
        #expect(result == frame)
    }

    @Test("no screens at all falls back to the default frame")
    func noScreensUsesDefault() {
        let frame = CGRect(x: 3000, y: 200, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [],
            fallbackScreen: nil,
            defaultFrame: defaultFrame
        )
        #expect(result == defaultFrame)
    }

    @Test("off-screen with no fallback screen uses the default frame")
    func offScreenNoFallbackUsesDefault() {
        let frame = CGRect(x: 3000, y: 200, width: 1000, height: 700)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen],
            fallbackScreen: nil,
            defaultFrame: defaultFrame
        )
        #expect(result == defaultFrame)
    }

    @Test("an oversized restored frame is shrunk to fit the fallback screen")
    func oversizedShrinksToFit() {
        // Saved huge on a gone 4K display; fallback is the smaller main screen.
        let frame = CGRect(x: 5000, y: 0, width: 3000, height: 1600)
        let result = WindowFrameClamp.clamp(
            frame: frame,
            toScreens: [mainScreen],
            fallbackScreen: mainScreen,
            defaultFrame: defaultFrame
        )
        #expect(result.width <= mainScreen.width)
        #expect(result.height <= mainScreen.height)
    }
}

/// The self-owned frame persistence (second attempt): we stop
/// fighting SwiftUI for `frameAutosaveName` and persist under a UserDefaults key
/// we control. Codec + read/write are pure/headless — no NSWindow needed.
@Suite("Window frame persistence")
struct WindowFramePersistenceTests {

    /// A throwaway defaults suite so tests never touch the app's real domain.
    private func makeDefaults() -> UserDefaults {
        let suite = "WindowFramePersistenceTests.\(UUID().uuidString)"
        return UserDefaults(suiteName: suite)!
    }

    @Test("encode → decode round-trips a frame exactly")
    func roundTrips() {
        let frame = CGRect(x: 137, y: 42, width: 1600, height: 1024)
        let decoded = WindowFramePersistence.decode(WindowFramePersistence.encode(frame))
        #expect(decoded == frame)
    }

    @Test("malformed stored string decodes to nil, not a zero frame")
    func malformedIsNil() {
        #expect(WindowFramePersistence.decode("not a rect") == nil)
        #expect(WindowFramePersistence.decode("") == nil)
    }

    @Test("a zero-area frame is treated as nothing stored")
    func zeroAreaIsNil() {
        // NSZeroRect and degenerate frames must not restore a 0-size window.
        #expect(WindowFramePersistence.decode(WindowFramePersistence.encode(.zero)) == nil)
        let flat = CGRect(x: 10, y: 10, width: 800, height: 0)
        #expect(WindowFramePersistence.decode(WindowFramePersistence.encode(flat)) == nil)
    }

    @Test("save then load returns the same frame")
    func saveLoadRoundTrips() {
        let defaults = makeDefaults()
        let frame = CGRect(x: 200, y: 150, width: 1440, height: 900)
        WindowFramePersistence.save(frame, name: "DispatchMain", to: defaults)
        #expect(WindowFramePersistence.load(name: "DispatchMain", from: defaults) == frame)
    }

    @Test("load with nothing stored is nil (first launch)")
    func loadEmptyIsNil() {
        let defaults = makeDefaults()
        #expect(WindowFramePersistence.load(name: "DispatchMain", from: defaults) == nil)
    }

    @Test("keys are namespaced per window name")
    func keysAreNamespaced() {
        #expect(WindowFramePersistence.defaultsKey(for: "DispatchMain")
                != WindowFramePersistence.defaultsKey(for: "Other"))
        // Our namespace, not Cocoa's `NSWindow Frame …` autosave namespace.
        #expect(WindowFramePersistence.defaultsKey(for: "DispatchMain")
                .hasPrefix("DispatchWindowFrame."))
    }
}

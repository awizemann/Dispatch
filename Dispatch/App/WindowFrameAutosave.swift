// WindowFrameAutosave.swift
// Persists + restores the main window's frame across launches.
//
// Two failed prior attempts and why this one is different:
//
//  1. SwiftUI's built-in scene autosave keys the saved frame off the root
//     view's GENERIC TYPE SIGNATURE, which changes across builds/launches (the
//     boot Group renders loading-color → ContentView through different modifier
//     generics), so it never finds its own stored key and reverts to
//     `.defaultSize`.
//  2. The AppKit bridge (Phase 10, e3dbd56): set the NSWindow's
//     `frameAutosaveName` to a STABLE "DispatchMain" and re-assert it on scene
//     updates so Cocoa would persist/restore under it. This ALSO did not hold —
//     evidence from Alan's live defaults domain after real detached-build runs:
//     ZERO `NSWindow Frame DispatchMain` keys ever landed, while dozens of
//     `NSWindow Frame SwiftUI.WindowGroup<…>` keys did, EVERY ONE at size
//     1440×900 (the `.defaultSize`) with only the origin varying. SwiftUI
//     reclaims `frameAutosaveName` during steady state (a plain resize/move
//     fires NO scene update, so our `reassert` never runs at the moment Cocoa
//     autosaves) — so every save went to a SwiftUI generic key and our
//     `setFrameUsingName("DispatchMain")` on launch always found nothing,
//     dropping the window back to `.defaultSize`.
//
// This version stops fighting SwiftUI for the autosave NAME. We persist the
// frame OURSELVES under a stable UserDefaults key on the window's own move/
// resize notifications, and restore it explicitly on launch (overriding
// `.defaultSize`). SwiftUI can own `frameAutosaveName` all it likes — we never
// use it, so the war is moot. Serialization + the UserDefaults read/write live
// in `WindowFramePersistence` and the off-screen correction in
// `WindowFrameClamp`, both pure/headless-testable without a window.

import AppKit
import SwiftUI

/// Pure geometry: keep a restored window frame usable on the current display
/// arrangement. Extracted from the view bridge so it can be tested headless.
enum WindowFrameClamp {
    /// Returns a frame guaranteed to be reachable on one of `screens`:
    /// - If `frame` meaningfully intersects the union of the visible frames,
    ///   it is returned unchanged (the common case: same display layout).
    /// - Otherwise (the window was saved on a display that is gone, or drifted
    ///   fully off every screen), it is re-centered on `fallbackScreen` — or,
    ///   if that is nil, returned as `defaultFrame`.
    ///
    /// - Parameters:
    ///   - frame: the candidate (restored) window frame, in screen coordinates.
    ///   - screens: the visible frames of the currently connected screens
    ///     (`NSScreen.visibleFrame` for each). Empty → `defaultFrame`.
    ///   - fallbackScreen: the visible frame to center on when `frame` is
    ///     unreachable (typically the main screen's `visibleFrame`).
    ///   - defaultFrame: last-resort frame when there is no screen to fall back
    ///     to (e.g. a headless run with no screens).
    ///   - minVisible: how much of the window (in points, each axis) must lie
    ///     inside some screen for the frame to count as reachable. Guards the
    ///     "one-pixel sliver on screen" degenerate case.
    static func clamp(
        frame: CGRect,
        toScreens screens: [CGRect],
        fallbackScreen: CGRect?,
        defaultFrame: CGRect,
        minVisible: CGFloat = 80
    ) -> CGRect {
        guard !screens.isEmpty else { return defaultFrame }

        // Reachable if the window overlaps ANY screen by at least `minVisible`
        // on both axes — enough of the titlebar/drag region to grab.
        let reachable = screens.contains { screen in
            let overlap = screen.intersection(frame)
            return !overlap.isNull
                && overlap.width >= min(minVisible, frame.width)
                && overlap.height >= min(minVisible, frame.height)
        }
        if reachable { return frame }

        // Unreachable: center the SAME size on the fallback screen (clamped to
        // fit), or fall back to the default frame if there is no screen.
        guard let fallbackScreen else { return defaultFrame }
        let size = CGSize(
            width: min(frame.width, fallbackScreen.width),
            height: min(frame.height, fallbackScreen.height)
        )
        let origin = CGPoint(
            x: fallbackScreen.midX - size.width / 2,
            y: fallbackScreen.midY - size.height / 2
        )
        return CGRect(origin: origin, size: size)
    }
}

/// Pure serialization + the UserDefaults read/write for the persisted window
/// frame. Extracted from the view bridge so the codec is unit-testable without
/// a window (the clamp's headless-testability precedent).
enum WindowFramePersistence {
    /// The UserDefaults key for a given logical window name. Distinct from
    /// Cocoa's `NSWindow Frame …` autosave namespace on purpose — we own this
    /// key outright, so nothing (SwiftUI included) competes for it.
    static func defaultsKey(for name: String) -> String { "DispatchWindowFrame.\(name)" }

    /// Encode a frame to Cocoa's own `{{x, y}, {w, h}}` string form.
    static func encode(_ frame: CGRect) -> String { NSStringFromRect(frame) }

    /// Decode a stored frame. `NSRectFromString` yields `NSZeroRect` for
    /// malformed input; a genuinely saved window frame is never zero-area, so a
    /// zero-area (or empty) result reads as "nothing usable stored" → nil.
    static func decode(_ string: String) -> CGRect? {
        let rect = NSRectFromString(string)
        guard rect.width > 0, rect.height > 0 else { return nil }
        return rect
    }

    static func load(name: String, from defaults: UserDefaults = .standard) -> CGRect? {
        guard let string = defaults.string(forKey: defaultsKey(for: name)) else { return nil }
        return decode(string)
    }

    static func save(_ frame: CGRect, name: String, to defaults: UserDefaults = .standard) {
        defaults.set(encode(frame), forKey: defaultsKey(for: name))
    }
}

/// Restores the host window's saved frame on launch (clamped to a visible
/// screen) and persists it on every move/resize under a UserDefaults key we own
/// — sidestepping the SwiftUI `frameAutosaveName` war entirely. Drop into a
/// SwiftUI hierarchy as a hidden background; it wires up once the window
/// attaches. Persistence lives on the `Coordinator` so it survives scene
/// updates (the boot nil→stores content swap does not tear the NSView down).
struct WindowFrameAutosaveInstaller: NSViewRepresentable {
    /// Logical window name; the UserDefaults key base (see WindowFramePersistence).
    let autosaveName: String
    /// Default frame used only when there is no screen to fall back to during
    /// off-screen clamping.
    let defaultFrame: CGRect

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // The window is not attached synchronously in makeNSView; defer.
        let coordinator = context.coordinator
        let name = autosaveName
        let def = defaultFrame
        DispatchQueue.main.async { [weak view, weak coordinator] in
            guard let window = view?.window, let coordinator else { return }
            coordinator.install(on: window, name: name, defaultFrame: def)
        }
        return view
    }

    // The window can attach after the first async (boot-group timing). Retry on
    // scene updates until it exists; install() is idempotent (once-only).
    func updateNSView(_ nsView: NSView, context: Context) {
        let coordinator = context.coordinator
        let name = autosaveName
        let def = defaultFrame
        DispatchQueue.main.async { [weak nsView, weak coordinator] in
            guard let window = nsView?.window, let coordinator else { return }
            coordinator.install(on: window, name: name, defaultFrame: def)
        }
    }

    /// Owns the once-only restore and the move/resize observers for one window.
    /// An NSObject so it can be a selector target; @MainActor because it only
    /// ever runs on the main thread (window notifications post there, and the
    /// SwiftUI representable is main-isolated).
    @MainActor
    final class Coordinator: NSObject {
        private var installed = false
        private var name = ""

        /// Restore the saved frame (once), then observe move/resize to persist.
        func install(on window: NSWindow, name: String, defaultFrame: CGRect) {
            guard !installed else { return }
            installed = true
            self.name = name

            // RESTORE: apply our own saved frame, clamped to a currently-visible
            // screen (a frame saved on a now-disconnected display must not
            // restore off-screen). This overrides SwiftUI's `.defaultSize`. On
            // first launch there is nothing stored — leave SwiftUI's default
            // size + centering untouched.
            if let saved = WindowFramePersistence.load(name: name) {
                let clamped = WindowFrameClamp.clamp(
                    frame: saved,
                    toScreens: NSScreen.screens.map(\.visibleFrame),
                    fallbackScreen: (NSScreen.main ?? NSScreen.screens.first)?.visibleFrame,
                    defaultFrame: defaultFrame
                )
                window.setFrame(clamped, display: true)
            }

            // PERSIST: we write the frame ourselves on move/resize, so it no
            // longer matters that SwiftUI owns `frameAutosaveName`.
            let center = NotificationCenter.default
            center.addObserver(
                self, selector: #selector(frameDidChange(_:)),
                name: NSWindow.didMoveNotification, object: window
            )
            center.addObserver(
                self, selector: #selector(frameDidChange(_:)),
                name: NSWindow.didResizeNotification, object: window
            )
        }

        @objc private func frameDidChange(_ notification: Notification) {
            guard let window = notification.object as? NSWindow else { return }
            WindowFramePersistence.save(window.frame, name: name)
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }
    }
}

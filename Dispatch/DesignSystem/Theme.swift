// Theme.swift
// Dispatch DesignSystem — the app theme.
//
// v3 Obsidian (Alan's design call): the outer-chrome and canvas colors
// are LOCKED to spec constants (#181A21 / #E7E8EC) — their swatch/lightness
// tunability and the HSL shading path were removed. The ACCENT color stays
// user-tunable (a curated 5-swatch picker in Settings → Theme). The public
// surface every view consumes — `accent`, `accentHover`, `accentTint(_:)`,
// `outerChrome`, `canvas` — is UNCHANGED.
//
// Also tunable: the rail widths (projectsRailWidth / rightRailWidth). Both the
// accent index and the rail widths persist via App/ThemePersistence.swift.
//
// Injection: one instance created at app launch, `.environment(theme)` at the
// root, read via `@Environment(Theme.self)`. @Observable gives property-level
// tracking, so an accent pick / rail drag only invalidates the views that read
// it. Implicitly @MainActor (project default isolation), which is correct: it
// is UI state.

import SwiftUI

@Observable
final class Theme {

    // MARK: Accent (system color — buttons, pills, focus rings, bars, badges)

    /// Curated accent choices (green, blue, indigo, amber, rose) — base + hover
    /// pairs (handoff DesignTokens). Green (index 0) is the default.
    static let accentOptions: [(base: UInt32, hover: UInt32)] = [
        (0x2E946A, 0x237854), (0x2A6FDB, 0x1F55AC), (0x5A5DC8, 0x44479E),
        (0xC77B41, 0x9A5A22), (0xC2607C, 0x9E4763),
    ]

    /// Index into `accentOptions`. Default: green. Persisted (ThemePersistence).
    var accentIndex: Int = 0

    var accent: Color {
        Color(hex: Self.accentOptions[accentClamped].base)
    }

    var accentHover: Color {
        Color(hex: Self.accentOptions[accentClamped].hover)
    }

    /// Accent tint at a given opacity (chips 10–14%, borders 25–45%, focus ring 28%).
    func accentTint(_ opacity: Double) -> Color {
        accent.opacity(opacity)
    }

    private var accentClamped: Int {
        Self.accentOptions.indices.contains(accentIndex) ? accentIndex : 0
    }

    // MARK: Fixed Obsidian spec colors

    /// Outer chrome — window backdrop + both rails, the top of the graphite
    /// gradient (handoff: `#181A21`; gradient to `Chrome.backdropDeep` stays in
    /// the backdrop view). Locked to spec (no longer tunable).
    let outerChrome = Color(hex: 0x181A21)

    /// Canvas — the floating light sheet behind every white work surface
    /// (handoff: `#E7E8EC`). Locked to spec (no longer tunable).
    let canvas = Color(hex: 0xE7E8EC)

    // MARK: Rail widths (user-adjustable preferences — v3 Obsidian)

    /// The projects rail (left) and right (review/notes) rail widths are user
    /// preferences, not fixed constants: Defaults-persisted, adjustable, clamped
    /// to `Metrics.railWidthRange`. RailResizeHandle drives these; the public
    /// accessors clamp on set (via a private backing store — clamping in a
    /// `didSet` on an @Observable property recurses infinitely, so the store
    /// pattern is required) so an out-of-range value can never be read or
    /// persisted.
    private var _projectsRailWidth: CGFloat = Metrics.projectsRailWidthDefault
    private var _rightRailWidth: CGFloat = Metrics.rightRailWidthDefault

    var projectsRailWidth: CGFloat {
        get { _projectsRailWidth }
        set { _projectsRailWidth = Self.clampRailWidth(newValue) }
    }
    var rightRailWidth: CGFloat {
        get { _rightRailWidth }
        set { _rightRailWidth = Self.clampRailWidth(newValue) }
    }

    static func clampRailWidth(_ width: CGFloat) -> CGFloat {
        min(max(width, Metrics.railWidthRange.lowerBound), Metrics.railWidthRange.upperBound)
    }
}

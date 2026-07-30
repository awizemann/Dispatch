// ColorHex.swift
// Dispatch DesignSystem — hex color helper.
// Ported from design/design_handoff_dispatch/swift/DesignTokens.swift.
// All colors are defined in sRGB. Pure value helper: nonisolated so any
// context (previews, actors, tests) can use it synchronously.
//
// The HSL / shade / ownLightnessPercent helpers were removed with the theme
// color-tunability path: v3 Obsidian locks the theme colors to
// spec constants, so nothing re-shades a swatch by lightness anymore.

import SwiftUI

// MARK: - Hex

nonisolated extension Color {
    /// sRGB color from a 0xRRGGBB literal (as used throughout the design handoff).
    init(hex: UInt32, alpha: Double = 1.0) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

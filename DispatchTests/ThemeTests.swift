// ThemeTests.swift
// v3 Obsidian theme: outer-chrome + canvas are LOCKED to spec
// constants (their swatch/lightness tunability + the HSL shading path were
// removed); the ACCENT stays user-tunable (a curated 5-swatch index). These
// tests cover what remains:
//   1. accent index selects / clamps across accentOptions,
//   2. the locked chrome/canvas colors resolve to their documented hex verbatim,
//   3. the rail-width preferences clamp to Metrics.railWidthRange on set.
// Pure over the @Observable Theme; no view needed.

import Foundation
import SwiftUI
import Testing
@testable import DispatchApp

@Suite("Theme — accent picker + locked chrome/canvas + rail-width clamp")
@MainActor
struct ThemeTests {

    /// Sample a Color's sRGB bytes for exact comparison against a spec hex.
    private func rgb(_ color: Color) -> (r: Int, g: Int, b: Int) {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? NSColor(color)
        return (
            Int((ns.redComponent * 255).rounded()),
            Int((ns.greenComponent * 255).rounded()),
            Int((ns.blueComponent * 255).rounded())
        )
    }

    private func hexRGB(_ hex: UInt32) -> (r: Int, g: Int, b: Int) {
        (Int((hex >> 16) & 0xFF), Int((hex >> 8) & 0xFF), Int(hex & 0xFF))
    }

    // MARK: - Accent (tunable)

    @Test("Default accent + hover render the Obsidian spec greens verbatim")
    func defaultAccentIsSpecGreen() {
        let theme = Theme()
        #expect(theme.accentIndex == 0)
        #expect(rgb(theme.accent) == hexRGB(0x2E946A))
        #expect(rgb(theme.accentHover) == hexRGB(0x237854))
    }

    @Test("Picking an accent index selects that swatch's base + hover pair")
    func accentIndexSelectsSwatch() {
        let theme = Theme()
        theme.accentIndex = 2  // indigo
        #expect(rgb(theme.accent) == hexRGB(Theme.accentOptions[2].base))
        #expect(rgb(theme.accentHover) == hexRGB(Theme.accentOptions[2].hover))
    }

    @Test("Accent index out of bounds falls back to the first swatch")
    func accentIndexClamps() {
        let theme = Theme()
        theme.accentIndex = 999
        #expect(rgb(theme.accent) == hexRGB(Theme.accentOptions[0].base))
        theme.accentIndex = -1
        #expect(rgb(theme.accent) == hexRGB(Theme.accentOptions[0].base))
    }

    // MARK: - Locked chrome/canvas (verbatim)

    @Test("Outer chrome renders #181A21 verbatim")
    func outerChromeIsSpecVerbatim() {
        #expect(rgb(Theme().outerChrome) == hexRGB(0x181A21))
    }

    @Test("Canvas renders #E7E8EC verbatim")
    func canvasIsSpecVerbatim() {
        #expect(rgb(Theme().canvas) == hexRGB(0xE7E8EC))
    }

    @Test("accentTint applies the requested opacity to the spec accent")
    func accentTintOpacity() {
        let theme = Theme()
        // Same hue as accent; opacity carried on the Color (compared via NSColor
        // alpha to avoid asserting on composited RGB).
        let tint = theme.accentTint(0.35)
        let alpha = (NSColor(tint).usingColorSpace(.sRGB) ?? NSColor(tint)).alphaComponent
        #expect(abs(alpha - 0.35) < 0.01)
    }

    // MARK: - Rail-width clamp

    @Test("Rail widths clamp below the range floor")
    func railWidthClampsBelowFloor() {
        let theme = Theme()
        theme.projectsRailWidth = 0
        theme.rightRailWidth = -100
        #expect(theme.projectsRailWidth == Metrics.railWidthRange.lowerBound)
        #expect(theme.rightRailWidth == Metrics.railWidthRange.lowerBound)
    }

    @Test("Rail widths clamp above the range ceiling")
    func railWidthClampsAboveCeiling() {
        let theme = Theme()
        theme.projectsRailWidth = 10_000
        theme.rightRailWidth = 5_000
        #expect(theme.projectsRailWidth == Metrics.railWidthRange.upperBound)
        #expect(theme.rightRailWidth == Metrics.railWidthRange.upperBound)
    }

    @Test("An in-range rail width is stored unchanged")
    func railWidthInRangeUnchanged() {
        let theme = Theme()
        let target: CGFloat = 300
        #expect(Metrics.railWidthRange.contains(target))
        theme.projectsRailWidth = target
        #expect(theme.projectsRailWidth == target)
    }

    @Test("Rail widths default to the handoff spec values")
    func railWidthDefaults() {
        let theme = Theme()
        #expect(theme.projectsRailWidth == Metrics.projectsRailWidthDefault)
        #expect(theme.rightRailWidth == Metrics.rightRailWidthDefault)
    }
}

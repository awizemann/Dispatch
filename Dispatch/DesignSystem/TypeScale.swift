// TypeScale.swift
// Dispatch DesignSystem — typography.
// UI: SF Pro Text (system). Data (IDs, paths, statuses, timestamps): SF Mono.
//
// Deviation from the handoff scaffold (approved 2026-07-05):
// - Renamed `Type` → `TypeScale` (`Type` collides with Swift metatype syntax).
// - Scale entries are `TextStyle` (font + point tracking) applied via
//   `.textStyle(_:)`, because Font cannot carry the handoff's tracking values
//   (docH1 −0.3, panelTitle −0.2, sectionLabel +0.6).

import SwiftUI

/// A font plus point-based tracking, applied together via `.textStyle(_:)`.
struct TextStyle: Hashable {
    let font: Font
    let tracking: CGFloat

    init(_ font: Font, tracking: CGFloat = 0) {
        self.font = font
        self.tracking = tracking
    }
}

enum TypeScale {
    static func ui(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight)
    }

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    // Scale (sizes/weights/tracking verbatim from the handoff)
    /// Doc viewer H1.
    static let docH1 = TextStyle(ui(22, .bold), tracking: -0.3)
    /// Modal titles.
    static let panelTitle = TextStyle(ui(16, .bold), tracking: -0.2)
    /// Chat header agent name.
    static let chatName = TextStyle(ui(15, .bold))
    /// Chat bubbles.
    static let bodyChat = TextStyle(ui(14))
    /// Doc body, subjects.
    static let body = TextStyle(ui(13.5))
    /// Project rows.
    static let cardTitle = TextStyle(ui(13, .semibold))
    /// Buttons, list rows.
    static let control = TextStyle(ui(12.5, .medium))
    /// Spec lines, hints.
    static let caption = TextStyle(ui(11.5))
    /// ALL-CAPS rail section labels.
    static let sectionLabel = TextStyle(ui(10, .semibold), tracking: 0.6)
    /// Code chips, paths.
    static let monoMeta = TextStyle(mono(9.5))
    /// Timestamps, footers.
    static let monoTiny = TextStyle(mono(9))
}

extension View {
    /// Applies a TypeScale entry (font + tracking).
    func textStyle(_ style: TextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }
}

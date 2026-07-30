// ProjectIconTile.swift
// The square that stands for a project — its repo's real icon when Dispatch
// found one, the letter tile when it didn't.
//
// ONE component for both surfaces (rail card, bus-map station) because the two
// must never disagree about what a project looks like; the only differences
// between them are size and corner radius, which are parameters.
//
// DECORATIVE, ALWAYS. The tile is hidden from assistive tech in both callers —
// the project's NAME is right next to it and is what gets spoken. An icon that
// announced itself would make every card say its name twice.

import AppKit
import SwiftUI

struct ProjectIconTile: View {

    /// The discovered icon, or nil for the letter fallback.
    let icon: NSImage?
    /// Drives the letter and the fallback tint.
    let name: String
    let size: CGFloat
    let cornerRadius: CGFloat
    /// Point size of the fallback letter.
    let letterSize: CGFloat

    init(
        icon: NSImage?, name: String, size: CGFloat,
        cornerRadius: CGFloat, letterSize: CGFloat
    ) {
        self.icon = icon
        self.name = name
        self.size = size
        self.cornerRadius = cornerRadius
        self.letterSize = letterSize
    }

    var body: some View {
        Group {
            if let icon {
                // ASPECT-FILL + CLIP: favicons are routinely not square (a
                // wordmark, a 32×16 strip), and letting one stretch to fill a
                // square is the difference between "their logo" and "their logo,
                // wrong". Fill crops the long edge instead of distorting.
                Image(nsImage: icon)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    .frame(width: size, height: size)
                    .clipShape(shape)
                    // A hairline keeps a white-background favicon from
                    // dissolving into a light surface.
                    .overlay(shape.strokeBorder(Ink.faint.opacity(0.5), lineWidth: 0.5))
            } else {
                shape
                    .fill(tint.tint)
                    .frame(width: size, height: size)
                    .overlay(
                        Text(name.prefix(1))
                            .textStyle(TextStyle(TypeScale.ui(letterSize, .semibold)))
                            .foregroundStyle(tint.tintInk)
                    )
            }
        }
        .frame(width: size, height: size)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
    }

    /// The Project DTO carries no tint; the palette entry is derived from the
    /// name's first scalar so a project's fallback colour is stable across
    /// launches and identical on both surfaces.
    private var tint: AgentPalette.Entry {
        let scalar = Int(name.unicodeScalars.first?.value ?? 0)
        return AgentPalette.entry(forColorIndex: scalar)
    }
}

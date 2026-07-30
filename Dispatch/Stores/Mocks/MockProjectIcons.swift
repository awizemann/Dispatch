// MockProjectIcons.swift
// Sample project icons for the scripted `--mock-scenario`, DRAWN IN CODE.
//
// The scenario's repos don't exist on any disk — `~/Developer/Ledgerline` is a
// fixture string, not a folder — so real discovery correctly finds nothing for
// all five. That would show five letter tiles and hide the whole feature from
// the screenshot pass, so two projects get a seeded icon instead.
//
// Drawn rather than bundled on purpose: a PNG committed as a resource is a
// binary blob to review and a path to get wrong, while these are deterministic,
// theme-independent, and impossible to load from the wrong machine. They are
// also deliberately AWKWARD — one square app-icon-alike, one WIDE wordmark —
// because the two failure modes worth seeing on screen are a blurry upscale and
// a non-square favicon stretched into a square tile.

import AppKit

@MainActor
enum MockProjectIcons {

    /// A square, rounded, gradient "app icon" with a glyph — what an
    /// `AppIcon.appiconset` resolves to for a real Mac app repo.
    static func appIcon(glyph: String, top: NSColor, bottom: NSColor) -> NSImage {
        let side: CGFloat = 256
        let image = NSImage(size: NSSize(width: side, height: side))
        image.lockFocus()
        let bounds = NSRect(x: 0, y: 0, width: side, height: side)
        NSGradient(starting: top, ending: bottom)?.draw(in: bounds, angle: -90)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: side * 0.56, weight: .bold),
            .foregroundColor: NSColor.white,
        ]
        let text = glyph as NSString
        let size = text.size(withAttributes: attributes)
        text.draw(
            at: NSPoint(x: (side - size.width) / 2, y: (side - size.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    /// A WIDE favicon — the 2:1 wordmark strip a web repo actually ships. Its
    /// job in the mock is to prove the tile crops (aspect-fill) instead of
    /// squashing: the background is what gets cropped away, the mark in the
    /// middle survives, and nothing is stretched. (A mark WIDER than the centre
    /// square would be clipped — which is the correct, and the only honest,
    /// answer for a square tile.)
    static func wideFavicon(text: String, background: NSColor) -> NSImage {
        let size = NSSize(width: 256, height: 128)
        let image = NSImage(size: size)
        image.lockFocus()
        background.setFill()
        NSRect(origin: .zero, size: size).fill()
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 64, weight: .heavy),
            .foregroundColor: NSColor.white,
        ]
        let string = text as NSString
        let textSize = string.size(withAttributes: attributes)
        string.draw(
            at: NSPoint(x: (size.width - textSize.width) / 2,
                        y: (size.height - textSize.height) / 2),
            withAttributes: attributes
        )
        image.unlockFocus()
        return image
    }

    /// Seeds the scenario: Ledgerline has a real app icon, Driftwood a wide web
    /// favicon, and Halyard / Beacon / Kestrel keep the letter tile — the mixed
    /// state the rail and the map both have to render side by side.
    static func seed(into store: ProjectIconStore) {
        store.seed(
            appIcon(
                glyph: "L",
                top: NSColor(calibratedRed: 0.38, green: 0.45, blue: 0.92, alpha: 1),
                bottom: NSColor(calibratedRed: 0.21, green: 0.24, blue: 0.62, alpha: 1)
            ),
            for: MockData.ID.ledgerline
        )
        store.seed(
            wideFavicon(
                text: "DW",
                background: NSColor(calibratedRed: 0.13, green: 0.55, blue: 0.47, alpha: 1)
            ),
            for: MockData.ID.driftwood
        )
    }
}

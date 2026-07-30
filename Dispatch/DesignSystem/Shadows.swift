// Shadows.swift
// Dispatch DesignSystem — the four elevation shadows.
//
// Deviation from the handoff scaffold (approved 2026-07-05): expressed as View
// extension modifiers instead of static functions taking a view, and the modal +
// activity-sheet shadows (only comments in the scaffold) are implemented.

import SwiftUI

/// All shadows use the design's warm shadow ink.
private let shadowInk = Color(hex: 0x26241E)
/// v3 Obsidian layered shadows use the cool ink (handoff `Shadows` ink 0x14161E).
private let obsidianInk = Color(hex: 0x14161E)

extension View {
    /// Work surfaces & cards: y1 blur2 @5%.
    func cardShadow() -> some View {
        shadow(color: shadowInk.opacity(0.05), radius: 1, y: 1)
    }

    /// Agent-side chat bubbles: a whisper lift (design §4: `0 1px 2px
    /// rgba(20,22,30,.05)`). The cool obsidian ink, unlike `cardShadow`'s warm
    /// ink, so the bubble reads as a floating light surface on the panel.
    func bubbleShadow() -> some View {
        shadow(color: obsidianInk.opacity(0.05), radius: 1, y: 1)
    }

    /// Major panels (chat, work queue, doc viewer): 0 2 6 @5% + 0 16 40 @9%
    /// (v3 Obsidian, handoff `Shadows.panel`).
    func panelShadow() -> some View {
        self
            .shadow(color: obsidianInk.opacity(0.05), radius: 3, y: 2)
            .shadow(color: obsidianInk.opacity(0.09), radius: 20, y: 16)
    }

    /// Popovers/menus: y2 blur4 @6% + y10 blur28 @10%.
    func popoverShadow() -> some View {
        self
            .shadow(color: shadowInk.opacity(0.06), radius: 2, y: 2)
            .shadow(color: shadowInk.opacity(0.10), radius: 14, y: 10)
    }

    /// Dark chrome popovers (MCP health, dark menus): 0 12 40 black@55%
    /// (v3 Obsidian).
    func darkPopoverShadow() -> some View {
        shadow(color: Color.black.opacity(0.55), radius: 20, y: 12)
    }

    /// Selected cards on the dark chrome rails (v3 Obsidian): a soft black lift
    /// (`0 3 6 black@25%`). The warm `cardShadow` vanishes on dark, so selected
    /// rail cards use this instead. `on: false` draws no shadow (unselected
    /// cards stay flat), keeping the call site branch-free.
    func darkCardShadow(_ on: Bool = true) -> some View {
        shadow(color: on ? Color.black.opacity(0.25) : .clear, radius: 6, y: 3)
    }

    /// Modals: y4 blur8 @8% + y20 blur48 @12%.
    func modalShadow() -> some View {
        self
            .shadow(color: shadowInk.opacity(0.08), radius: 4, y: 4)
            .shadow(color: shadowInk.opacity(0.12), radius: 24, y: 20)
    }

    /// The floating center sheet: 1px white@8% ring + 0 30 80 black@45%
    /// (v3 Obsidian). Apply to the sheet's rounded container so the ring hugs
    /// its `Metrics.sheetRadius` corners.
    func sheetChrome() -> some View {
        self
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.sheetRadius, style: .continuous)
                    .strokeBorder(Chrome.sheetRing, lineWidth: 1)
            )
            .shadow(color: Color.black.opacity(0.45), radius: 40, y: 30)
    }

    /// Activity sheet: upward y−6 blur24 @10%.
    func sheetShadow() -> some View {
        shadow(color: shadowInk.opacity(0.10), radius: 12, y: -6)
    }

    /// The slide-in inspector chrome (Tasks TaskInspectorView + Queue
    /// BatchTimelineView, v3 Obsidian): a white floating panel with a
    /// `hairlineStrong` border and the two-layer left-throw shadow
    /// (`0 2 4 @6%` + a soft `-7 0 36 @12%` throw). One idiom, one home — both
    /// slide-ins read identically. Corners use `Metrics.radiusPanel`.
    func inspectorChrome() -> some View {
        self
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Surface.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(Surface.hairlineStrong)
            )
            .shadow(color: shadowInk.opacity(0.06), radius: 2, x: 0, y: 2)
            .shadow(color: shadowInk.opacity(0.12), radius: 18, x: -7, y: 0)
    }

    /// Working status-dot glow: 0 0 8 accent@85% (v3 Obsidian). Pass the
    /// resolved accent so it tracks the user's theme.
    func workingDotGlow(_ accent: Color) -> some View {
        shadow(color: accent.opacity(0.85), radius: 4)
    }

    /// Chat search drawer: the header-drawer's drop shadow —
    /// `0 12 32 @14%` cool ink (prototype `box-shadow:0 12px 32px rgba(20,22,30,.14)`;
    /// SwiftUI radius = blur/2). Distinct from `popoverShadow` (warm ink, two
    /// layers) — this is one soft cool throw hugging the drawer's rounded bottom.
    func searchDrawerShadow() -> some View {
        shadow(color: obsidianInk.opacity(0.14), radius: 16, y: 12)
    }
}

/// Non-modifier v3 depth idioms expressed as reusable inset overlays — these
/// are strokes rather than SwiftUI shadows (SwiftUI has no true inset shadow),
/// matching the handoff comments (primary-button highlight, kanban recessed
/// well). Kept here so the depth language has one home.
enum ObsidianDepth {
    /// Primary (accent) buttons: inset 0 1 0 white@25% top highlight.
    static let primaryButtonHighlight = Color.white.opacity(0.25)
}

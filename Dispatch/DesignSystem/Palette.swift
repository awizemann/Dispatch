// Palette.swift
// Dispatch DesignSystem — static color palette.
// Ported verbatim from design/design_handoff_dispatch/swift/DesignTokens.swift
// (hex values are the contract; do not retune without a design ruling).
//
// Conventions (memory: dispatch/conventions/design-system-and-accessibility-rules):
// - Single source for status→color: `StatusKind` below. No per-view status colors.
// - No raw Color(hex:) in views where a token exists here.

import SwiftUI

// MARK: - Ink (text)

enum Ink {
    static let primary = Color(hex: 0x1A1916)
    static let secondary = Color(hex: 0x696760)
    static let tertiary = Color(hex: 0x8A867B)
    static let faint = Color(hex: 0xABADB5)
    /// Mono metadata on light backgrounds (IDs, paths, timestamps).
    static let mutedMono = Color(hex: 0x62646B)
}

// MARK: - Surfaces

enum Surface {
    static let white = Color.white
    /// Unselected agent cards floating on the canvas (v3 Obsidian).
    static let cardTranslucent = Color.white.opacity(0.75)
    /// In-panel headers, composer, kanban cards.
    static let panel = Color(hex: 0xF7F8FA)
    /// Work-queue item rows / recessed wells on light surfaces (v3 Obsidian).
    static let well = Color(hex: 0xF6F7F9)
    /// Recessed kanban columns (ink @ 4.5%) — cards float in these with an
    /// inset shadow (v3 Obsidian).
    static let kanbanWell = Color(hex: 0x14161E).opacity(0.045)
    /// Segmented-control container fill (ink @ 6%) — recessed track behind the
    /// active white segment (v3 Obsidian).
    static let segmented = Color(hex: 0x14161E).opacity(0.06)
    /// The top bar's white@55% wash inside the light sheet (v3 Obsidian) — a
    /// faint frost over the canvas so the segmented control + clusters read as a
    /// distinct band without a hard divider.
    static let topBarWash = Color.white.opacity(0.55)
    /// The active segment's drop under the segmented track (ink @ 16%,
    /// `0 1 3` — v3 Obsidian).
    static let segmentActiveShadow = Color(hex: 0x14161E).opacity(0.16)
    /// Neutral chips, toggle wells.
    static let chipNeutral = Color(hex: 0xEFF0F3)
    /// Tool calls, code blocks.
    static let codeBlock = Color(hex: 0x2A2B30)
    static let codeInk = Color(hex: 0xD2D4DA)
    static let hairline = Color(hex: 0x26241E).opacity(0.08)
    static let hairlineStrong = Color(hex: 0x26241E).opacity(0.12)
    static let controlBorder = Color(hex: 0xD2D4DA)
    static let scrim = Color(hex: 0x18191D).opacity(0.35)
    /// The lighter dim behind a slide-in inspector (Tasks + Queue) — a click-
    /// outside-closes veil over the canvas, NOT the full modal scrim. Same ink
    /// as `scrim`, softer alpha (prototype rgba(24,25,29,.12)).
    static let inspectorScrim = Color(hex: 0x18191D).opacity(0.12)
}

// MARK: - Chrome (dark rails, dark popovers/menus — v3 Obsidian)

/// The dark-graphite chrome palette: the window backdrop + both rails + dark
/// popovers/menus. Text is a light-on-dark ramp; surfaces are white-alpha tints
/// (so they inherit whatever the user's tuned outer-chrome grey is beneath
/// them); status colors are the dark-variant chips sitting on a 14%-alpha
/// self-tint. Hex values are the contract (handoff DesignTokens.swift → Chrome);
/// do not retune without a design ruling.
///
/// Conventions: no raw Color(hex:)/Color.white.opacity in views where one of
/// these tokens applies — resolve chrome idioms through Chrome, exactly as light
/// surfaces resolve through Ink/Surface/Status.
enum Chrome {
    /// Backdrop gradient bottom stop (top stop = the resolved Theme.outerChrome).
    static let backdropDeep = Color(hex: 0x101116)

    // Text ramp on dark
    /// Wordmark, headers, hover states.
    static let textPrimary = Color(hex: 0xF2F1ED)
    /// Card titles, menu items.
    static let text = Color(hex: 0xECEBE7)
    /// Note text / body copy on dark.
    static let textBody = Color(hex: 0xDFDFE5)
    /// Secondary labels, ghost buttons.
    static let textMuted = Color(hex: 0x9DA0AB)
    /// Mono metadata (repo paths) on dark.
    static let textMeta = Color(hex: 0x84868F)
    /// ALL-CAPS section labels, MCP footer.
    static let sectionLabel = Color(hex: 0x767986)
    /// Empty states.
    static let textDisabled = Color(hex: 0x6C6E78)

    // Surfaces on dark (white-alpha tints)
    /// Rail cards (notes, review, health rows).
    static let card = Color.white.opacity(0.06)
    static let cardBorder = Color.white.opacity(0.08)
    /// Selected project fill.
    static let selected = Color.white.opacity(0.08)
    static let selectedBorder = Color.white.opacity(0.12)
    static let hover = Color.white.opacity(0.07)
    /// Review/Notes pill tabs (active).
    static let railTabActive = Color.white.opacity(0.10)
    static let railTabBorder = Color.white.opacity(0.14)
    /// Note textarea / dark input field.
    static let field = Color.white.opacity(0.07)
    static let fieldBorder = Color.white.opacity(0.12)
    /// MCP health popover, dark context menus (solid).
    static let popover = Color(hex: 0x1F2027)
    static let popoverBorder = Color.white.opacity(0.09)
    /// 1px ring around the light center sheet.
    static let sheetRing = Color.white.opacity(0.08)

    // Detail drawer (v3.1 §8c) — the slide-out panel that carries oversized rail
    // content (diffs, long notes). A dark #1B1C23 surface, rounded on the LEFT,
    // deep left-throw shadow; the source card in the rail lifts above it on an
    // opaque #23252D fill so it reads as the drawer's origin.
    /// Drawer surface fill (#1B1C23 — one shade off the popover, deliberately
    /// darker than the white-alpha rail cards so the panel reads as its own plane).
    static let drawer = Color(hex: 0x1B1C23)
    /// Drawer 1px border (white@9%; the panel omits its right border — it butts
    /// against the rail's inner edge).
    static let drawerBorder = Color.white.opacity(0.09)
    /// The scrim over the center area while the drawer is open (a cool near-black
    /// veil; the right rail is NOT scrimmed — the drawer originates from it).
    static let drawerScrim = Color(hex: 0x0A0B0F).opacity(0.4)
    /// Header/footer hairline dividers inside the drawer (white@7%).
    static let drawerDivider = Color.white.opacity(0.07)
    /// One file card's surface inside the diff drawer body (white@3%).
    static let drawerFileCard = Color.white.opacity(0.03)
    /// The source card's opaque lift fill when it is the open drawer's origin
    /// (#23252D — brighter than the rail's white@6% card so it pops).
    static let sourceCardLift = Color(hex: 0x23252D)
    /// The lifted source card's brighter border (white@20%).
    static let sourceCardLiftBorder = Color.white.opacity(0.20)

    // Syntax-colored diff hunks on the dark drawer (v3.1 §8c). Add/del reuse the
    // dark status greens/reds on an 8% self-tint (`diffLineTint`); the hunk
    // header is the checking blue; context is a quiet slate.
    /// Hunk `@@ … @@` header line color (#7FB3E8 — the checking blue).
    static let diffHunkHeader = checking
    /// Diff context (unchanged) line text (#8A8D99).
    static let diffContext = Color(hex: 0x8A8D99)

    /// A diff add/del line's row tint — the status color on an 8% self-tint
    /// (deliberately lighter than the 14% chip tint so dense hunks stay legible).
    static func diffLineTint(_ color: Color) -> Color { color.opacity(0.08) }

    // Status on dark (health chips, MCP dots) — each is the foreground
    // on a 14%-alpha tint of itself (`Chrome.statusTint(_:)`).
    static let success = Color(hex: 0x6FC898)
    static let successDot = Color(hex: 0x5BC48C)
    static let warning = Color(hex: 0xE3B23F)
    /// "↥ N unpushed" pill — on a 16%-alpha self-tint (per handoff).
    static let amberPill = Color(hex: 0xE8B368)
    static let danger = Color(hex: 0xE5736A)
    /// In-flight "checking" blue (blinks).
    static let checking = Color(hex: 0x7FB3E8)

    /// A dark status color on its own 14%-alpha tint — the standard status- /
    /// MCP-popover chip treatment (foreground `color`, background
    /// `color.opacity(0.14)`). Exception: the `amberPill` ("↥ N unpushed") sits
    /// on a 16% self-tint per the handoff — pass `amberPillTint` for that.
    static func statusTint(_ color: Color) -> Color { color.opacity(0.14) }

    /// The on-dark dot color for a `StatusKind` (MCP health dots on the dark
    /// rail / popover). The light `StatusKind.dot` is the light-surface mapping;
    /// this is its Obsidian counterpart so dots stay legible on dark chrome.
    static func dot(for kind: StatusKind) -> Color {
        switch kind {
        case .success: successDot
        case .warning: warning
        case .danger: danger
        }
    }

    /// The `amberPill` background — a 16%-alpha self-tint (handoff exception to
    /// the 14% chip rule).
    static let amberPillTint = amberPill.opacity(0.16)
}

// MARK: - Status

/// Raw status color values. Prefer `StatusKind` in views — it is the single
/// semantic status→color mapping.
enum Status {
    static let successDot = Color(hex: 0x4E9E76)
    static let successInk = Color(hex: 0x2F7052)
    static let successTint = Color(hex: 0x4E9E76).opacity(0.16)
    static let warningDot = Color(hex: 0xD9A21B)
    static let warningInk = Color(hex: 0x9A5A22)
    /// Deliberately identical to AgentPalette.amber.tint — amber = pending/issue
    /// is one family in this design language (design ruling 2026-07-05).
    static let warningTint = Color(hex: 0xF4E6D4)
    static let dangerDot = Color(hex: 0xCF5A52)
    static let dangerInk = Color(hex: 0xB04A43)
    static let dangerTint = Color(hex: 0xF9E3E1)
    /// Ghost danger controls' resting BORDER (v3 handoff:
    /// `border:1px solid #E4C7C4`) — `dangerTint` is its hover FILL,
    /// not its border.
    static let dangerBorder = Color(hex: 0xE4C7C4)
    /// wk/5h limit bars > 80%.
    static let overLimit = Color(hex: 0xA05A1A)
    /// The "checking" pill — deliberately the slate-blue identity family's
    /// tint/tintInk: checking = in-flight work, one blue family in this
    /// design language.
    static let checkingInk = Color(hex: 0x305F95)
    static let checkingTint = Color(hex: 0xDEE9F4)
}


/// THE status→color mapping. Every status-colored UI element (chips, dots,
/// banners) resolves through this — never through ad-hoc colors.
enum StatusKind: CaseIterable {
    case success, warning, danger

    var dot: Color {
        switch self {
        case .success: Status.successDot
        case .warning: Status.warningDot
        case .danger: Status.dangerDot
        }
    }

    var ink: Color {
        switch self {
        case .success: Status.successInk
        case .warning: Status.warningInk
        case .danger: Status.dangerInk
        }
    }

    var tint: Color {
        switch self {
        case .success: Status.successTint
        case .warning: Status.warningTint
        case .danger: Status.dangerTint
        }
    }
}

// MARK: - Identity palette

/// Per-entity identity colors: base (dots/accents), tint (chip bg), tintInk
/// (chip fg). Used by the project chips and the design-system gallery.
enum AgentPalette {
    struct Entry: Hashable {
        let base: Color
        let tint: Color
        let tintInk: Color

        init(base: UInt32, tint: UInt32, tintInk: UInt32) {
            self.base = Color(hex: base)
            self.tint = Color(hex: tint)
            self.tintInk = Color(hex: tintInk)
        }
    }

    static let slateBlue = Entry(base: 0x4A7BB5, tint: 0xDEE9F4, tintInk: 0x305F95)
    static let amber     = Entry(base: 0xC77B41, tint: 0xF4E6D4, tintInk: 0x9A5A22)
    static let plum      = Entry(base: 0x9B5FB0, tint: 0xECDDF1, tintInk: 0x774189)
    static let rose      = Entry(base: 0xC2607C, tint: 0xF4E0E8, tintInk: 0x9E4763)
    static let indigo    = Entry(base: 0x5A5DC8, tint: 0xE0E0F7, tintInk: 0x3B3B8E)

    /// The colorIndex contract: a persisted `colorIndex` maps into THIS
    /// ordering (indigo first — deliberately different from declaration order;
    /// design ruling 2026-07-05). Never reorder.
    static let all: [Entry] = [indigo, slateBlue, amber, plum, rose]

    /// The single resolution point from a persisted colorIndex to the
    /// (base, tint, tintInk) triple. Wraps out-of-range indices.
    static func entry(forColorIndex index: Int) -> Entry {
        let count = all.count
        let wrapped = ((index % count) + count) % count
        return all[wrapped]
    }

}

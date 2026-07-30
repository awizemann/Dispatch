// Chip.swift
// Dispatch Components — THE chip. One component for status, agent, doc-type,
// neutral, and accent chips (convention: no per-domain chip structs; memory
// note dispatch/conventions/design-system-and-accessibility-rules).
//
// Colors always come through ChipStyle, whose factories resolve from the
// DesignSystem palette — never pass raw colors from views.

import SwiftUI

// MARK: - ChipStyle (the single chip color contract)

struct ChipStyle {
    var tint: Color
    var ink: Color
    /// Leading status/identity dot; nil = no dot.
    var dot: Color?

    /// Neutral chip (toggle wells, fallbacks).
    static let neutral = ChipStyle(tint: Surface.chipNeutral, ink: Ink.mutedMono, dot: nil)

    /// Status chip — text + dot + tint, all from the one StatusKind mapping.
    /// Pairs text with color per the accessibility convention.
    /// `dot: false` for status pills the design draws without a dot (e.g. the
    /// project card's "↥ 3 unpushed" pill — its ↥ glyph carries the state).
    static func status(_ kind: StatusKind, dot: Bool = true) -> ChipStyle {
        ChipStyle(tint: kind.tint, ink: kind.ink, dot: dot ? kind.dot : nil)
    }

    /// Agent identity chip (agent code, mentions). Resolve the entry via
    /// `AgentPalette.entry(forColorIndex:)`.
    static func agent(_ entry: AgentPalette.Entry, dot: Bool = false) -> ChipStyle {
        ChipStyle(tint: entry.tint, ink: entry.tintInk, dot: dot ? entry.base : nil)
    }

    /// Accent-tinted chip (armed skills, selected filters) from the live theme.
    static func accent(_ theme: Theme) -> ChipStyle {
        ChipStyle(tint: theme.accentTint(0.12), ink: theme.accent, dot: nil)
    }

    /// The "checking" pill (blinking blue, design §4): work in flight.
    /// Settled states use neutral / status(.success) / status(.danger).
    static let checking = ChipStyle(tint: Status.checkingTint, ink: Status.checkingInk, dot: nil)

    // MARK: On-dark chips (v3 Obsidian — chrome rails / dark popovers)

    /// The project card's "↥ N unpushed" pill on the DARK projects rail: the
    /// on-dark amber (`Chrome.amberPill`) on its 16%-alpha self-tint. No dot —
    /// the ↥ glyph carries the state (mirrors the light `.status(.warning,
    /// dot: false)` this replaces on dark chrome).
    static let amberPillDark = ChipStyle(
        tint: Chrome.amberPillTint, ink: Chrome.amberPill, dot: nil
    )

    /// The neutral on-dark chip (project-card link chips): a faint white well
    /// with muted on-dark ink — the dark-chrome twin of `.neutral`.
    static let neutralDark = ChipStyle(
        tint: Chrome.field, ink: Chrome.textMuted, dot: nil
    )

    /// A dark-variant status chip (the bus health popover): the
    /// on-dark status color on its 14%-alpha self-tint. Pass the resolved
    /// `Chrome` status color (`.success` / `.warning` / `.danger` / `.checking`).
    static func statusDark(_ color: Color, dot: Bool = false) -> ChipStyle {
        ChipStyle(tint: Chrome.statusTint(color), ink: color, dot: dot ? color : nil)
    }
}

// MARK: - Chip

struct Chip: View {
    enum Shape {
        /// Pill — status chips, badges (design: "Pills: use Capsule()").
        case capsule
        /// Radius-6 tag — code/type chips (Metrics.radiusChip).
        case tag
    }

    private let text: String
    private let style: ChipStyle
    private let mono: Bool
    private let shape: Shape
    private let fontOverride: TextStyle?
    private let systemImage: String?

    /// - Parameters:
    ///   - mono: SF Mono at TypeScale.monoMeta (IDs, codes, statuses);
    ///     false = SF Pro at TypeScale.caption.
    ///   - shape: capsule (default) or radius-6 tag.
    ///   - font: optional TextStyle override for context-specific sizes.
    ///   - systemImage: optional leading SF Symbol at meta scale (e.g. the
    ///     task card's brief/reference hints). Empty `text` renders an
    ///     icon-only chip.
    init(
        _ text: String,
        style: ChipStyle,
        mono: Bool = false,
        shape: Shape = .capsule,
        font: TextStyle? = nil,
        systemImage: String? = nil
    ) {
        self.text = text
        self.style = style
        self.mono = mono
        self.shape = shape
        self.fontOverride = font
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: 5) {
            if let dot = style.dot {
                Circle()
                    .fill(dot)
                    .frame(width: Metrics.statusDot, height: Metrics.statusDot)
                    .accessibilityHidden(true) // the chip text carries the meaning
            }
            if let systemImage {
                Image(systemName: systemImage)
                    .textStyle(TextStyle(TypeScale.ui(9, .medium)))
                    .accessibilityHidden(true) // the chip's label carries the meaning
            }
            if !text.isEmpty {
                Text(text)
                    .textStyle(fontOverride ?? (mono ? TypeScale.monoMeta : TypeScale.caption))
                    // A chip is a single-line pill by contract: NEVER wrap to a
                    // second line (the rail-width squeeze that turned "checking…"
                    // into two lines, dogfood-2 item 6). lineLimit(1) enforces
                    // no-wrap for every chip everywhere; tail truncation is the
                    // graceful degradation at extreme widths — we deliberately do
                    // NOT bake in `.fixedSize(horizontal:)`, which would force the
                    // intrinsic width and blow out a narrow rail instead of
                    // shrinking. Call sites that must hold full width add their own
                    // `.fixedSize()` (e.g. the task inspector's status pills).
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
        }
        .foregroundStyle(style.ink)
        .padding(.horizontal, 8)
        .padding(.vertical, mono ? 2 : 3)
        .background(background)
    }

    @ViewBuilder
    private var background: some View {
        switch shape {
        case .capsule:
            Capsule().fill(style.tint)
        case .tag:
            RoundedRectangle(cornerRadius: Metrics.radiusChip, style: .continuous)
                .fill(style.tint)
        }
    }
}

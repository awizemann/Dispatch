// Motion.swift
// Dispatch DesignSystem — animation constants + working-dots blink.
// Curves/durations verbatim from design/design_handoff_dispatch/swift/DesignTokens.swift.

import SwiftUI

enum Motion {
    /// State changes (hover, selection, fills): 120ms.
    static let state = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.12)
    /// Popover/menu rise-in: 220ms.
    static let rise = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
    /// Modal/sheet rise-in: 320ms.
    static let riseModal = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.32)
    /// Limit-bar width changes: 600ms.
    static let barFill = Animation.timingCurve(0.32, 0.72, 0, 1, duration: 0.6)

    // MARK: - Bus map

    /// The bus map's travelling pulse: LINEAR over `BusPulseStore.travel`.
    /// Deliberately not an ease — a message crossing the bus has no reason to
    /// accelerate, and an eased dot reads as a UI flourish rather than traffic.
    static let busPulseTravel = Animation.linear(duration: BusPulseStore.travel)
    /// Reduce Motion's stand-in: the line lights and fades, nothing moves.
    static let busPulseHighlight = Animation.easeOut(duration: 0.5)
}

// MARK: - Working dots blink

/// The agent "working" blink: opacity 1 → 0.2 → 1 over 1.2s, forever.
/// Honors Reduce Motion by holding a static mid opacity instead of blinking
/// (deviation from scaffold, approved 2026-07-05 — the scaffold only documents
/// the blink in a comment).
///
/// PERF: deliberately NOT a `.repeatForever` animation. A repeat-forever
/// SwiftUI animation keeps NSHostingView committing a display-list update
/// every display frame (120/s on ProMotion) for as long as the node is
/// visible — the always-on ticker dot alone held the whole app at ~25% idle
/// CPU (idle-CPU investigation, 2026-07-30). Instead a periodic TimelineView
/// toggles the dim state on the blink's half-period and a SHORT one-shot ease
/// smooths each toggle, so the render loop only runs during the brief ease
/// and sleeps the rest of the cycle.
private struct WorkingDotsModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half-period of the blink (dim ↔ bright), matching the old 1.2s cycle.
    private static let halfPeriod: TimeInterval = 0.6

    func body(content: Content) -> some View {
        blinking(content)
            // PERF (dogfood-2 item 3 — the review-rail stall). When the animated
            // node is a LIVE, independent accessibility element, every animation
            // commit runs AccessibilityNode.updateFocusResponder, an O(view-tree)
            // walk over the WHOLE window — a blinking `.checking` chip in a rail
            // pegged the main thread for as long as it blinked. Collapsing the
            // animated subtree into ONE combined element (its label derives from
            // the static child text, not the opacity) drops the per-child
            // participating nodes and keeps the blink off that walk. Callers
            // still layer their own `.accessibilityLabel` /
            // `.accessibilityHidden` on top — those override this element.
            .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func blinking(_ content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.6)
        } else {
            TimelineView(.periodic(from: .now, by: Self.halfPeriod)) { context in
                let dimmed = Int(
                    context.date.timeIntervalSinceReferenceDate / Self.halfPeriod
                ) % 2 == 0
                content
                    .opacity(dimmed ? 0.2 : 1)
                    .animation(.easeInOut(duration: 0.2), value: dimmed)
            }
        }
    }
}

extension View {
    /// Apply to a working-status dot (or dot cluster) to get the 1.2s blink.
    func workingDotsBlink() -> some View {
        modifier(WorkingDotsModifier())
    }
}

// MARK: - Skeleton pulse (pending-reply placeholder)

/// A calm placeholder pulse for skeleton content — the pending-reply bubble's
/// bar (killing the dead air before the agent's first token). Opacity gently
/// oscillates 1.0 → 0.45 over ~1.1s, ease-in-out, autoreversing, forever —
/// slower and softer than the 0.6s working-dots blink. Honors Reduce Motion by
/// holding a static ~0.7 opacity (WorkingDotsModifier precedent).
///
/// A skeleton bar carries no information, so the animated node is
/// accessibility-hidden. Beyond being semantically correct, that keeps the
/// pulse OFF the per-frame accessibility walk that a live, independent
/// animating a11y element would force (see WorkingDotsModifier's PERF note) —
/// a hidden node doesn't participate.
///
/// PERF: same discrete-tick pattern as WorkingDotsModifier — a periodic
/// TimelineView with a short one-shot ease per toggle, never `.repeatForever`,
/// which would hold the main-thread render loop hot every display frame for
/// as long as the skeleton is visible.
private struct SkeletonPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Half-period of the pulse (dim ↔ bright), matching the old ~2.2s cycle.
    private static let halfPeriod: TimeInterval = 1.1

    func body(content: Content) -> some View {
        pulsing(content)
            .accessibilityHidden(true)
    }

    @ViewBuilder
    private func pulsing(_ content: Content) -> some View {
        if reduceMotion {
            content.opacity(0.7)
        } else {
            TimelineView(.periodic(from: .now, by: Self.halfPeriod)) { context in
                let dimmed = Int(
                    context.date.timeIntervalSinceReferenceDate / Self.halfPeriod
                ) % 2 == 0
                content
                    .opacity(dimmed ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.35), value: dimmed)
            }
        }
    }
}

extension View {
    /// Apply to a skeleton placeholder (e.g. the pending-reply bar) for the
    /// ~1.1s opacity pulse. Reduce Motion → static 0.7 opacity. Animates opacity
    /// ONLY — never height/frame — and is accessibility-hidden.
    func skeletonPulse() -> some View {
        modifier(SkeletonPulseModifier())
    }
}

// MARK: - Arrival pulse

/// A calm, one-shot "this just arrived" pulse for a card:
/// a single decaying ring in the card's edge tint over ~1.2s, then gone. Honors
/// Reduce Motion by holding a brief static low-opacity fill instead of the
/// expanding ring (WorkingDotsModifier precedent). The pulse is decorative —
/// the sibling card text carries the meaning — so the whole layer is hidden
/// from accessibility.
private struct ArrivalPulseModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Driven by the store's recentlyArrivedIDs membership; flips true when the
    /// card arrives and false when the store's decay Task clears it.
    let isArriving: Bool
    /// The card's edge tint (amber = proposed, red = blocked) — same token the
    /// leading edge uses, so the pulse reads as "that card lit up".
    let tint: Color

    @State private var expanded = false

    func body(content: Content) -> some View {
        content.overlay {
            if isArriving {
                pulseLayer
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                    .onAppear { expanded = true }
            }
        }
    }

    @ViewBuilder
    private var pulseLayer: some View {
        let shape = RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
        if reduceMotion {
            // No expanding ring — a soft static tint wash the store's decay
            // Task fades out after the same ~1.2s window.
            shape.fill(tint.opacity(0.18))
        } else {
            // A single decaying ring: a tinted border that expands slightly and
            // fades over 1.2s, one-shot.
            shape
                .strokeBorder(tint, lineWidth: 1.5)
                .background(shape.fill(tint.opacity(0.35)))
                .opacity(expanded ? 0 : 0.55)
                .scaleEffect(expanded ? 1.06 : 1)
                .animation(.easeOut(duration: 1.2), value: expanded)
        }
    }
}

extension View {
    /// One-shot arrival pulse in `tint` while `isArriving`. Decorative — layer
    /// is accessibilityHidden. Reduce Motion → static low-opacity fade.
    func arrivalPulse(isArriving: Bool, tint: Color) -> some View {
        modifier(ArrivalPulseModifier(isArriving: isArriving, tint: tint))
    }
}

// MARK: - Arrival glow (work-queue items)

/// A one-shot "this just arrived" GLOW for a work-queue well:
/// an accent-tinted shadow that fades out over ~2.5s, matching the selected-
/// card / working-dot glow language (an accent-tinted `.shadow`, not the Review
/// rail's expanding ring — the queue wells recess into a white card, so a soft
/// glow reads better than a ring). Honors Reduce Motion by holding a brief
/// static glow (no animation) that the store's decay Task removes after the same
/// window. Decorative — hidden from accessibility (the row text carries meaning).
///
/// The animated layer lives in its OWN view so it gets fresh @State each time
/// `isArriving` flips true (a new item re-inserts it), so the fade restarts
/// cleanly per arrival with no timer to leak or retrigger.
private struct ArrivalGlowLayer: View {
    let tint: Color
    let cornerRadius: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var settled = false

    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
            // A tint fill both washes the well edge and casts the glow shadow;
            // it sits BEHIND the well's own (opaque) fill so only the soft bleed
            // and shadow read.
            .fill(tint.opacity(fillOpacity))
            .shadow(color: tint.opacity(shadowOpacity), radius: 10)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
            .onAppear {
                guard !reduceMotion else { return }
                withAnimation(.easeOut(duration: 2.5)) { settled = true }
            }
    }

    private var fillOpacity: Double {
        if reduceMotion { return 0.16 }        // static; store decay clears it
        return settled ? 0 : 0.22
    }
    private var shadowOpacity: Double {
        if reduceMotion { return 0.30 }
        return settled ? 0 : 0.55
    }
}

private struct ArrivalGlowModifier: ViewModifier {
    let isArriving: Bool
    let tint: Color
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content.background {
            if isArriving {
                ArrivalGlowLayer(tint: tint, cornerRadius: cornerRadius)
            }
        }
    }
}

extension View {
    /// One-shot accent-tinted arrival glow while `isArriving` (work-queue wells).
    /// Reduce Motion → static glow (no animation), removed by the store's decay.
    func arrivalGlow(isArriving: Bool, tint: Color, cornerRadius: CGFloat) -> some View {
        modifier(ArrivalGlowModifier(isArriving: isArriving, tint: tint, cornerRadius: cornerRadius))
    }
}

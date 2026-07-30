// RailResizeHandle.swift
// Dispatch Components — the thin invisible drag handle on a rail's INNER edge
// (v3 Obsidian, Phase 2). Dragging adjusts the bound rail width live; the width
// binding clamps + persists on its own (Theme.projectsRailWidth /
// Theme.rightRailWidth → Metrics.railWidthRange, Defaults-backed). Hovering
// shows the horizontal-resize cursor; a double-click resets to the default.
//
// The handle is visually invisible (a clear fill) but carries a generous
// contentShape hit area so it's easy to grab without stealing clicks from the
// rail's content, which sits to its side — the handle occupies only its own
// narrow strip.

import AppKit
import SwiftUI

struct RailResizeHandle: View {
    /// Which rail edge the handle lives on. `.trailing` = the projects (left)
    /// rail's inner edge (drag right → wider). `.leading` = the right rail's
    /// inner edge (drag left → wider).
    enum Edge { case trailing, leading }

    let edge: Edge
    /// The live rail-width binding (clamps + persists on set).
    @Binding var width: CGFloat
    /// Double-click reset target (the rail's default width).
    let defaultWidth: CGFloat

    /// Visible/hit width of the grab strip. Narrow enough to stay out of the
    /// content's way, wide enough (via contentShape) to be an easy target.
    private let hitWidth: CGFloat = 8

    /// Width at drag start, captured on the first change so the whole gesture is
    /// relative to a stable base (avoids compounding rounding drift).
    @State private var dragStartWidth: CGFloat?
    @State private var isHovering = false

    var body: some View {
        Rectangle()
            .fill(Color.clear)
            .frame(width: hitWidth)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .onHover { hovering in
                isHovering = hovering
                // Push/pop the resize cursor so it survives while the pointer is
                // over the (otherwise invisible) strip.
                if hovering {
                    NSCursor.resizeLeftRight.push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        let base = dragStartWidth ?? width
                        if dragStartWidth == nil { dragStartWidth = base }
                        // Leading rail widens as the pointer moves right;
                        // trailing rail widens as it moves left.
                        let delta = edge == .trailing
                            ? value.translation.width
                            : -value.translation.width
                        width = base + delta
                    }
                    .onEnded { _ in
                        dragStartWidth = nil
                    }
            )
            // Double-click resets to the rail's default width. Placed after the
            // drag so a genuine drag isn't intercepted as a click.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    width = defaultWidth
                }
            )
            .accessibilityHidden(true) // pointer-only affordance; no VO target
    }
}

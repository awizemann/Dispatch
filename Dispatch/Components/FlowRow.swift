// FlowRow.swift
// A left-aligned wrapping row — chips that flow onto a second line instead of
// truncating. Written as a `Layout` (not nested HStacks) because the number of
// items is data-driven: a project can be linked to one peer or six, and the
// rail's width is user-resizable, so the wrap point can only be decided at
// layout time.
//
// Deliberately minimal: no alignment options, no per-row justification. The one
// caller is the project card's link chips, and a general-purpose flow layout
// nobody asked for is a maintenance liability.

import SwiftUI

struct FlowRow: Layout {
    /// Gap between items on a line AND between lines (chips are small; one
    /// number reads as one rhythm).
    var spacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        // An unspecified width means "how big do you want to be" — a flow row
        // with no bound is just one line.
        let maxWidth = proposal.width ?? .infinity
        let lines = layout(subviews: subviews, maxWidth: maxWidth)
        let height = lines.reduce(0) { $0 + $1.height } +
            spacing * CGFloat(max(lines.count - 1, 0))
        let width = lines.map(\.width).max() ?? 0
        return CGSize(width: min(width, maxWidth), height: height)
    }

    func placeSubviews(
        in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()
    ) {
        let lines = layout(subviews: subviews, maxWidth: bounds.width)
        var y = bounds.minY
        for line in lines {
            var x = bounds.minX
            for index in line.indices {
                let size = subviews[index].sizeThatFits(.unspecified)
                subviews[index].place(
                    at: CGPoint(x: x, y: y + (line.height - size.height) / 2),
                    proposal: ProposedViewSize(size)
                )
                x += size.width + spacing
            }
            y += line.height + spacing
        }
    }

    /// One wrapped line: which subviews it holds and how big it is.
    private struct Line {
        var indices: [Int] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    /// Greedy wrap — an item that does not fit the remaining width starts a new
    /// line. An item WIDER than the whole row still gets its own line (it
    /// overflows rather than vanishing; chips truncate themselves).
    private func layout(subviews: Subviews, maxWidth: CGFloat) -> [Line] {
        var lines: [Line] = []
        var current = Line()
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(.unspecified)
            let needed = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            if !current.indices.isEmpty, needed > maxWidth {
                lines.append(current)
                current = Line()
            }
            current.width = current.indices.isEmpty ? size.width : current.width + spacing + size.width
            current.height = max(current.height, size.height)
            current.indices.append(index)
        }
        if !current.indices.isEmpty { lines.append(current) }
        return lines
    }
}

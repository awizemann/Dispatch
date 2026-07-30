// Metrics.swift
// Dispatch DesignSystem — layout metrics, radii, fixed sizes.
// Ported verbatim from the original design handoff's DesignTokens.swift.

import SwiftUI

enum Metrics {
    static let minWindowWidth: CGFloat = 1240
    /// Not in the handoff; Alan's design call for the shell phase.
    static let minWindowHeight: CGFloat = 720
    // The projects rail and right (notes/review) rail widths are NO LONGER fixed
    // constants: they are user-adjustable, Defaults-persisted preferences on
    // Theme (`Theme.projectsRailWidth` / `Theme.rightRailWidth`), defaults
    // 320 / 252, clamped to `railWidthRange`. Phase 2 adds the drag UI; Phase 1
    // only routes the existing width usages through the tunable state. The
    // spec-default values live here so Theme/Defaults share one source.
    static let projectsRailWidthDefault: CGFloat = 320
    static let rightRailWidthDefault: CGFloat = 252
    /// Sane clamp for the user-adjustable rail width. Lower bound must fit the
    /// widest project-card row: git chip + "restart Claude Code" chip, or the
    /// link-state line with the hover "Links…" button. Persisted widths from
    /// older builds are lifted to the floor on load.
    static let railWidthRange: ClosedRange<CGFloat> = 280...420
    /// The center column's top band (tabs + usage clusters) and the matching
    /// top label bands on the notes rail ("NOTES") and the documents list
    /// ("REPO DOCUMENTS"). Sized to snugly fit the account-limit clusters
    /// (the tallest occupants, ~36pt) with no dead space, so content rises to
    /// meet the compact titlebar strip instead of being pushed down by the
    /// legacy full-height (52pt) header. The projects rail uses
    /// the shorter `titleBarHeight` (title beside the stoplights);
    /// this band is a touch taller only because the clusters need the room.
    /// v3 Obsidian: bumped 40→54 — the top bar becomes a true segmented control
    /// (Phase 2) and needs the taller band; label bands read the same token so
    /// they stay aligned.
    static let topBarHeight: CGFloat = 54
    /// The compact titlebar strip in the projects rail that hosts the app title
    /// beside the traffic lights. Sized to the stoplight cluster's
    /// vertical band (centered ~y14 in a `.hiddenTitleBar` window) so the title
    /// aligns with the lights instead of sitting in a full-height header row that
    /// pushes the projects list down. Its empty area stays draggable.
    static let titleBarHeight: CGFloat = 30
    static let tickerHeight: CGFloat = 34
    /// Brand-row app-icon tile (radius 7, accent gradient) — v3 Obsidian.
    static let appIconTile: CGFloat = 26

    // Center sheet — the floating light surface holding everything between the
    // rails (v3 Obsidian). Rounded, clipped, ring + deep shadow (Shadows.sheet).
    static let sheetRadius: CGFloat = 16
    static let sheetMarginV: CGFloat = 10
    static let sheetMarginH: CGFloat = 14

    /// Major panels: chat, work queue, messages, docs, columns (v3: was 9).
    static let radiusPanel: CGFloat = 14
    /// Agent/rail/note cards (v3 Obsidian).
    static let radiusCard: CGFloat = 11
    /// Buttons, small controls, fields (v3: was 7).
    static let radiusControl: CGFloat = 8
    /// Segmented-control container (segments use radiusControl) — v3 Obsidian.
    static let radiusSegment: CGFloat = 10
    /// Code/type chips.
    static let radiusChip: CGFloat = 6
    /// Brand-row app-icon tile corner (pairs with `appIconTile`) — v3 Obsidian.
    static let radiusAppIcon: CGFloat = 7
    /// Inputs. Kept distinct from `radiusControl` for existing call sites; both
    /// resolve to 8 in v3 (handoff folds fields into `radiusControl`).
    static let radiusField: CGFloat = 8
    static let radiusModal: CGFloat = 18
    // Pills: use Capsule().

    /// Canvas gutter right/bottom of work surfaces.
    static let surfacePadding: CGFloat = 16
    static let limitBarSize = CGSize(width: 44, height: 4)

    // MARK: - Bus map
    // The collapsible band above the Messages inbox. Geometry INSIDE the map
    // (cell pitch, tile size, group gap) lives on `BusMapLayout` so the layout
    // math stays testable without SwiftUI; only the band's own chrome is here.

    /// The map band's drawn height with one row of stations (header excluded).
    static let busMapBandHeight: CGFloat = 118
    /// With two rows (5+ stations in one network).
    static let busMapBandHeightTall: CGFloat = 198
    /// The disclosure header strip above the map panel.
    static let busMapHeaderHeight: CGFloat = 24
    /// Station tile corner — one step tighter than `radiusCard`, so a station
    /// reads as a mark on a map rather than a miniature project card.
    static let busMapStationRadius: CGFloat = 9
    /// The subway line's stroke width.
    static let busMapLineWidth: CGFloat = 3
    /// The travelling pulse dot.
    static let busMapPulseDot: CGFloat = 8
    /// The station's live/offline dot (matches the rail card's 6pt).
    static let busMapLiveDot: CGFloat = 6
    /// A station that is off the network, or outside the selected project's
    /// cluster, renders at this opacity. ONE value for both so "not in scope"
    /// reads the same whichever reason put it there.
    static let busMapOutOfScope: Double = 0.5
    /// The same idea for a LINE outside the selected cluster. A touch stronger
    /// than the station dim: the lines are already thin, and at 0.5 a dimmed
    /// line all but vanishes on the light canvas, which reads as "unlinked"
    /// rather than "out of scope".
    static let busMapLineOutOfScope: Double = 0.35
    static let agentDot: CGFloat = 8
    static let healthDot: CGFloat = 7
    static let statusDot: CGFloat = 7
}

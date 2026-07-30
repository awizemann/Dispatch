// ThemePersistence.swift
// Dispatch App layer — persists the tunable parts of Theme via
// sindresorhus/Defaults.
//
// v3 Obsidian LOCKS the outer-chrome and canvas colors to spec
// constants, so their former Defaults keys (swatch + lightness) and the one-time
// Obsidian outer-chrome migration are gone. What still persists: the ACCENT
// swatch index (Settings → Theme) and the two rail widths. Any stale chrome/
// canvas Defaults left on disk are harmless orphans (never read).
//
// This is the ONLY place that knows Theme is persisted; DesignSystem/Theme.swift
// has no storage dependency. Loads saved selections at init, then re-arms a
// withObservationTracking loop to write changes back as the user tunes them.

import Defaults
import Foundation

extension Defaults.Keys {
    static let themeAccentIndex = Key<Int>("themeAccentIndex", default: 0)
    // Rail widths — user-adjustable preferences (v3 Obsidian). Defaults match
    // the handoff (238 / 252); Theme clamps to Metrics.railWidthRange on set.
    static let projectsRailWidth = Key<Double>("projectsRailWidth", default: 320)
    static let rightRailWidth = Key<Double>("rightRailWidth", default: 252)
}

@MainActor
final class ThemePersistence {
    private let theme: Theme

    init(theme: Theme) {
        self.theme = theme
        load()
        observe()
    }

    private func load() {
        theme.accentIndex = Defaults[.themeAccentIndex]
        theme.projectsRailWidth = CGFloat(Defaults[.projectsRailWidth])
        theme.rightRailWidth = CGFloat(Defaults[.rightRailWidth])
    }

    private func save() {
        Defaults[.themeAccentIndex] = theme.accentIndex
        Defaults[.projectsRailWidth] = Double(theme.projectsRailWidth)
        Defaults[.rightRailWidth] = Double(theme.rightRailWidth)
    }

    /// Re-arming observation: fires once per change batch, saves, re-arms.
    private func observe() {
        withObservationTracking {
            _ = theme.accentIndex
            _ = theme.projectsRailWidth
            _ = theme.rightRailWidth
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.save()
                self.observe()
            }
        }
    }
}

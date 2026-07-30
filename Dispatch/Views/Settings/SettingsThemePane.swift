// SettingsThemePane.swift
// Settings → Theme: just the accent (system color) picker.
// v3 Obsidian LOCKS outer-chrome and canvas to spec
// constants, so their swatch rows + lightness sliders were removed; only the
// 5-swatch accent row remains. Picking a swatch mutates Theme.accentIndex in
// place, so the app repaints live; ThemePersistence's observation loop writes
// the change to Defaults. Nothing here persists directly — the pane is pure UI
// over state. Layout mirrors the other Settings panes.

import SwiftUI

struct SettingsThemePane: View {
    @Environment(Theme.self) private var theme

    var body: some View {
        @Bindable var theme = theme
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    accentSection(Bindable(theme))
                }
                .padding(.vertical, 2)
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Theme")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
            Text("Pick the app's highlight color. Changes apply live and are saved automatically.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Accent

    private func accentSection(_ theme: Bindable<Theme>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionLabel("SYSTEM COLOR", caption: "Buttons, pills, badges, focus rings, sliders.")
            HStack(spacing: 10) {
                ForEach(Theme.accentOptions.indices, id: \.self) { index in
                    accentSwatch(index, theme: theme)
                }
                Spacer(minLength: 0)
            }
        }
    }

    private func accentSwatch(_ index: Int, theme: Bindable<Theme>) -> some View {
        let isSelected = theme.wrappedValue.accentIndex == index
        let color = Color(hex: Theme.accentOptions[index].base)
        return Button {
            theme.wrappedValue.accentIndex = index
        } label: {
            Circle()
                .fill(color)
                .frame(width: 24, height: 24)
                .overlay(
                    Circle()
                        .strokeBorder(Ink.primary.opacity(0.85), lineWidth: isSelected ? 2 : 0)
                        .padding(-3)
                )
                .overlay(
                    Circle().strokeBorder(Surface.hairline, lineWidth: 0.5)
                )
                .frame(width: 30, height: 30)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(Self.accentNames[index])
        .accessibilityLabel("\(Self.accentNames[index]) accent\(isSelected ? ", selected" : "")")
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
    }

    static let accentNames = ["Green", "Blue", "Indigo", "Amber", "Rose"]

    // MARK: - Helpers

    private func sectionLabel(_ title: String, caption: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            Text(caption)
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.faint)
        }
    }
}

#Preview("Settings — theme (mock)") {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        SettingsModalView()
    }
    .environment(Theme())
    .environment({ () -> AppStores in
        let stores = AppStores.mock()
        stores.settingsRoute = .theme
        return stores
    }())
    .frame(width: 900, height: 640)
}

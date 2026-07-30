// SettingsModalView.swift
// The Settings modal (design §Modals→Settings, screenshot 11): 640px card, left
// tab rail (General / Theme / Notifications — P2 pruned the rest, and every
// remaining pane is live), white content pane, Done bottom-right. The Theme tab
// carries only the accent-color picker — v3 Obsidian locks outer-chrome +
// canvas to spec.
//
// SettingsModalPresenter is the scrim host WorkbenchView overlays — same
// chrome as the Project modal presenter (rgba scrim, white 16px-radius
// card, rise). Route lives on AppStores.settingsRoute; ⌘, opens .general.

import SwiftUI

// MARK: - Presenter (scrim + rise)

struct SettingsModalPresenter: View {
    @Environment(AppStores.self) private var stores

    var body: some View {
        ZStack {
            if stores.settingsRoute != nil {
                Surface.scrim
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .onTapGesture { dismiss() }
                SettingsModalView()
                    .transition(.scale(scale: 0.97).combined(with: .opacity))
            }
        }
        .animation(Motion.riseModal, value: stores.settingsRoute)
    }

    private func dismiss() {
        stores.settingsRoute = nil
    }
}

// MARK: - Modal card

struct SettingsModalView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    private let railWidth: CGFloat = 150

    var body: some View {
        let selected = stores.settingsRoute ?? .general
        HStack(alignment: .top, spacing: 0) {
            rail(selected: selected)
            VStack(alignment: .leading, spacing: 0) {
                Group {
                    switch selected {
                    case .theme:
                        SettingsThemePane()
                    case .notifications:
                        SettingsNotificationsPane()
                    case .general:
                        SettingsGeneralPane()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                doneRow
            }
            .padding(20)
        }
        // 540, not the original 460: the Notifications pane grew a row per bus
        // event, and at 460 the last one sat below the fold with no visible
        // scroll cue — a toggle nobody can see is a toggle nobody has.
        .frame(width: 640, height: 540, alignment: .topLeading)
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusModal, style: .continuous)
                .fill(Surface.white)
        )
        .modalShadow()
        .onExitCommand { stores.settingsRoute = nil }
    }

    // MARK: - Tab rail

    private func rail(selected: SettingsTab) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Settings")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 12)
            ForEach(SettingsTab.allCases) { tab in
                railItem(tab, isSelected: tab == selected)
            }
            Spacer()
        }
        .padding(12)
        .frame(width: railWidth, alignment: .topLeading)
        .frame(maxHeight: .infinity)
        .background(
            UnevenRoundedRectangle(
                topLeadingRadius: Metrics.radiusModal, bottomLeadingRadius: Metrics.radiusModal,
                bottomTrailingRadius: 0, topTrailingRadius: 0, style: .continuous
            )
            .fill(Surface.panel)
        )
    }

    private func railItem(_ tab: SettingsTab, isSelected: Bool) -> some View {
        Button {
            stores.settingsRoute = tab
        } label: {
            Text(tab.rawValue)
                .textStyle(TextStyle(TypeScale.ui(13, isSelected ? .semibold : .medium)))
                .foregroundStyle(isSelected ? theme.accent : Ink.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    if isSelected {
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(theme.accentTint(0.12))
                    }
                }
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(tab.rawValue)\(isSelected ? ", selected" : "")")
    }

    // MARK: - Done

    private var doneRow: some View {
        HStack {
            Spacer()
            Button {
                stores.settingsRoute = nil
            } label: {
                Text("Done")
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Surface.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    .background(
                        RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                            .fill(theme.accent)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}

#Preview("Settings — general (mock)") {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        SettingsModalView()
    }
    .environment(Theme())
    .environment({ () -> AppStores in
        let stores = AppStores.mock()
        stores.settingsRoute = .general
        return stores
    }())
    .frame(width: 900, height: 640)
}

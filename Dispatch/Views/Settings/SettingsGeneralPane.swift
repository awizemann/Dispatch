// SettingsGeneralPane.swift
// Settings → General: how the inbox is scoped, plus a read-only statement of
// where the bus is listening.
//
// P5 retired the "auto-answer bus questions" toggle with the agent runtime it
// described (see BusSettings.swift) — Dispatch does not decide whether an agent
// answers; the user's own sessions do.

import Defaults
import SwiftUI

struct SettingsGeneralPane: View {
    @Environment(AppStores.self) private var stores
    @Default(.messagesShowAllProjects) private var showAllProjects

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    inboxSection
                    busSection
                }
                .padding(.vertical, 2)
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("General")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
            Text("App-wide behavior. Changes apply immediately.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Inbox

    private var inboxSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("MESSAGE CENTRE")
            SettingsToggleRow(
                title: "One inbox for every project",
                caption: "Show all questions together. Off → the Messages tab shows only the "
                    + "project selected in the rail.",
                isOn: $showAllProjects
            )
        }
    }

    // MARK: - Bus (read-only status)

    /// Not a setting — a fact. The port is chosen by the kernel and written
    /// into every linked repo's `.mcp.json`, so the human can neither pick it
    /// nor needs to; what they occasionally DO need is to see it, when a repo's
    /// session says it can't connect.
    private var busSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            SettingsSectionLabel("BUS")
            Text(statusLine)
                .textStyle(TypeScale.cardTitle)
                .foregroundStyle(Ink.primary)
            Text("Each linked repo's .mcp.json points at this address with its own token. "
                 + "Rotate a project's token from its card in the rail.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusLine: String {
        let status = stores.busStatus
        guard let port = status.port else {
            return "Listener not running — no repo can reach Dispatch"
        }
        return "Listening on 127.0.0.1:\(port) · \(status.installedCount) of "
            + "\(status.projectCount) repos installed"
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

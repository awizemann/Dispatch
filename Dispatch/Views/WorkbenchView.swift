// WorkbenchView.swift
// The three-pane app shell (design §App Architecture, min 1240×720) — v3
// Obsidian: dark chrome outside, a floating light sheet inside.
//
// Depth model (inverted at the edges vs. v2): the window backdrop + both rails
// are ONE continuous dark graphite shell (a vertical gradient from the resolved
// `theme.outerChrome` down to `Chrome.backdropDeep`) with NO dividers/borders
// between the rails and the backdrop. The center column (top bar + tab content
// + ticker) floats as a rounded, clipped LIGHT sheet (canvas fill,
// `Metrics.sheetRadius`, `sheetMarginV/H`, `sheetChrome()` ring + deep shadow);
// the ticker sits INSIDE the sheet's clipped bottom edge. White work surfaces
// float on the canvas inside the sheet as before.

import AppKit
import SwiftUI

enum WorkbenchTab: String, CaseIterable, Identifiable {
    case messages = "Messages"

    var id: String { rawValue }

    /// User-facing tab name (top bar + placeholder). Decoupled from `rawValue`
    /// so the DEBUG `--tab=` key and the tab's stable identity survive a
    /// display rename.
    var title: String { rawValue }
}

struct WorkbenchView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores
    @State private var selectedTab: WorkbenchTab = WorkbenchView.initialTab()

    /// DEBUG `--tab=Messages` (with --mock-scenario): headless pixel
    /// verification opens directly on a tab — ui-verification-policy allows
    /// no synthetic clicks. Messages is the only tab today, and the boot default.
    private static func initialTab() -> WorkbenchTab {
        #if DEBUG
        if let arg = CommandLine.arguments.first(where: { $0.hasPrefix("--tab=") }),
           let tab = WorkbenchTab.allCases.first(where: {
               $0.rawValue.caseInsensitiveCompare(String(arg.dropFirst("--tab=".count))) == .orderedSame
           }) {
            return tab
        }
        #endif
        return .messages
    }

    var body: some View {
        HStack(spacing: 0) {
            ProjectsRailView()
            centerSheet
        }
        .frame(minWidth: Metrics.minWindowWidth, minHeight: Metrics.minWindowHeight)
        // The window backdrop IS the dark chrome: a vertical gradient from the
        // resolved outer-chrome grey down to the deep stop. Both rails are
        // transparent and sit directly on this gradient (no own fill, no
        // dividers) — one continuous dark shell, no seams.
        .background(
            LinearGradient(
                colors: [theme.outerChrome, Chrome.backdropDeep],
                startPoint: .top, endPoint: .bottom
            )
            .ignoresSafeArea()
        )
        .foregroundStyle(Ink.primary)
        // First-run onboarding: shown over the empty workbench
        // while the projects registry is empty. Sits BELOW the modal presenters
        // so its "Add project" step action surfaces on top.
        .overlay { OnboardingPresenter() }
        // Modals float over the whole workbench (design §9 scrim).
        .overlay { ProjectModalPresenter() }
        .overlay { DeleteProjectPresenter() }
        .overlay { SettingsModalPresenter() }
        .task {
            await stores.activate()
            #if DEBUG
            // Selection scoping is driven by the rail selection, so
            // the screenshot pass sets it the same way a click does.
            if let wanted = LaunchState.selection() {
                stores.projects.selectedProjectID = stores.projects.projects
                    .first { $0.name.caseInsensitiveCompare(wanted) == .orderedSame }?
                    .id
            }
            // The registry only exists after activation, so the editor flag is
            // applied here rather than at composition.
            if LaunchState.wantsProjectEditor,
               let project = stores.projects.selectedProjectID
                   .flatMap({ stores.projects.project(id: $0) })
                   ?? stores.projects.projects.first {
                stores.projects.modalRoute = .edit(project)
            }
            #endif
        }
        // Failures of the human's OWN gesture (a rotation, a link that didn't
        // persist) get said out loud here — everything quieter lands in the
        // ticker (audit S3).
        .alert(
            "Dispatch",
            isPresented: Binding(
                get: { stores.problemAlert != nil },
                set: { if !$0 { stores.problemAlert = nil } }
            )
        ) {
            Button("OK", role: .cancel) { stores.problemAlert = nil }
        } message: {
            Text(stores.problemAlert ?? "")
        }
        // Cross-tab routing (bus chip → Messages): switch the project if the
        // route crosses one, then the tab; the target tab consumes the rest.
        .onChange(of: stores.routeRequest) { _, request in
            switch request {
            case .message(let projectID, _):
                if stores.projects.selectedProjectID != projectID {
                    stores.projects.select(projectID)
                }
                selectedTab = .messages
            case nil:
                break
            }
        }
        // Refresh git rows when the app comes back to the foreground (the
        // 60s periodic loop covers the frontmost case).
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification
        )) { _ in
            Task { await stores.projects.refreshAllGitStatus() }
        }
    }

    /// The floating light sheet: the whole center column (top bar + tab content
    /// + ticker) on the resolved canvas, rounded to
    /// `Metrics.sheetRadius`, clipped so the ticker tucks into its bottom edge,
    /// with `sheetChrome()` (white@8% ring + deep shadow) and the v3 margins.
    private var centerSheet: some View {
        VStack(spacing: 0) {
            TopBarView(selectedTab: $selectedTab)
            // The switchboard, drawn: a collapsible band above the
            // tab content. It lives on the project side of the workbench —
            // above the inbox, not beside it — because "who can talk to whom"
            // is context for the messages, not a destination of its own. Hides
            // itself entirely below two projects.
            BusMapSection()
            // One tab today (Messages); the switch is the seam a second one
            // would slot into. Each tab owns its full center area.
            switch selectedTab {
            case .messages:
                MessagesTabView()
            }
            ActivityTickerView()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(theme.canvas)
        // Clip FIRST so the ticker (and any tab content) is contained by the
        // rounded corners, THEN apply the ring+shadow around the clipped sheet.
        .clipShape(RoundedRectangle(cornerRadius: Metrics.sheetRadius, style: .continuous))
        .sheetChrome()
        .padding(.vertical, Metrics.sheetMarginV)
        .padding(.horizontal, Metrics.sheetMarginH)
    }
}

#Preview("Workbench — mock scenario") {
    WorkbenchView()
        .environment(Theme())
        .environment(AppStores.mock())
        .frame(width: 1440, height: 900)
}

import os
import SwiftUI

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "app")

@main
struct DispatchApp: App {
    /// The live-tunable theme, injected app-wide via .environment(theme).
    /// Views read it with @Environment(Theme.self); @Observable property-level
    /// tracking keeps re-theming cheap (only readers of a property invalidate).
    @State private var theme: Theme
    /// Loads persisted theme selections and writes changes back to Defaults.
    @State private var themePersistence: ThemePersistence
    /// Domain stores over the REAL persistence + git layers. nil until the
    /// launch task finishes bootstrap (cold-start rule: no blocking work in
    /// the synchronous App init — AppStores.live() opens the DB off-main).
    @State private var stores: AppStores?
    @State private var bootError: String?

    init() {
        let theme = Theme()
        _theme = State(initialValue: theme)
        _themePersistence = State(initialValue: ThemePersistence(theme: theme))
    }

    var body: some Scene {
        WindowGroup {
            Group {
                if let stores {
                    ContentView()
                        .environment(stores)
                } else if let bootError {
                    BootFailureView(message: bootError)
                } else {
                    // One theme-colored frame while bootstrap runs (fast:
                    // local DB open + migrate).
                    theme.canvas.ignoresSafeArea()
                }
            }
            .environment(theme)
            // Persist + restore the window frame across launches.
            // SwiftUI's scene autosave doesn't cooperate with .hiddenTitleBar,
            // so bridge to AppKit's setFrameAutosaveName and clamp a restored
            // frame to a currently-visible screen (off-screen-restore safety).
            .background(
                WindowFrameAutosaveInstaller(
                    autosaveName: "DispatchMain",
                    defaultFrame: CGRect(x: 0, y: 0, width: 1440, height: 900)
                )
            )
            .task {
                guard stores == nil else { return }
                // Unit tests run inside this app as their host: NEVER boot the
                // live composition there — it would probe the claude CLI and
                // write the developer's real database on every test run
                // (audit find, 2026-07-05). Tests build their own stores.
                if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
                    return
                }
                // --mock-scenario: boot the scripted switchboard (three
                // projects, every message state) instead of the live DB. For
                // click-passes and pixel verification; never persists anything.
                // `live: true` also runs the scripted long-poll answer a few
                // seconds in — previews and tests get the still version.
                if CommandLine.arguments.contains("--mock-scenario") {
                    #if DEBUG
                    let mock = LaunchState.wantsEmptyRegistry
                        ? MockData.makeEmptyStores()
                        : MockData.makeStores(live: true)
                    mock.settingsRoute = LaunchState.settingsTab()
                    stores = mock
                    #else
                    stores = MockData.makeStores(live: true)
                    #endif
                    return
                }
                do {
                    stores = try await AppStores.live()
                } catch {
                    logger.error("bootstrap failed: \(String(describing: error), privacy: .public)")
                    bootError = error.localizedDescription
                }
            }
        }
        .defaultSize(width: 1440, height: 900)
        .windowResizability(.contentMinSize)
        // The design has no separate title bar — the rails run to the window's
        // top edge; the projects-rail header clears the traffic lights.
        .windowStyle(.hiddenTitleBar)
        // v3 Obsidian (Phase 2): Settings is an in-window modal, not a separate
        // SwiftUI `Settings` scene. The projects-rail gear is retired, so the
        // standard macOS Settings… menu item (⌘,) is now the entry point — it
        // opens the same in-window modal by setting the settings route. Replaces
        // AppKit's default (disabled) .appSettings item so ⌘, is live.
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings…") {
                    stores?.settingsRoute = .general
                }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(stores == nil)
            }
        }
    }

}

/// Database bootstrap failed (disk-level problem) — the app cannot run.
/// Deliberately plain: no stores exist at this point.
private struct BootFailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 8) {
            Text("Dispatch can't open its database")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
            Text(message)
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .frame(maxWidth: 420)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

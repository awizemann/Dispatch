// LaunchState.swift
// DEBUG-only launch arguments that put the app into a state a screenshot pass
// cannot otherwise reach.
//
// WHY THIS EXISTS: the verification policy forbids synthetic clicks (CGEvent
// and AppleScript no-op without Accessibility permission), so a headless pass
// can only photograph what the app shows on its own. Without these, whole
// surfaces — Settings, the first-run welcome, every non-default filter — would
// be unverifiable, which is how a broken empty state ships.
//
// Every flag is inert in Release (the whole enum is `#if DEBUG`) and every one
// of them only picks a state the user could reach by clicking. None of them
// fabricate data: `--mock-empty` composes the SAME mock with an empty registry,
// it does not fake an empty-looking full one.

#if DEBUG
import Foundation

enum LaunchState {

    private static func value(forFlag flag: String) -> String? {
        let prefix = "--\(flag)="
        return CommandLine.arguments
            .first { $0.hasPrefix(prefix) }
            .map { String($0.dropFirst(prefix.count)) }
    }

    /// `--settings=General|Theme|Notifications` — opens the Settings modal on
    /// that pane at launch (⌘, is a key event a headless pass cannot send).
    static func settingsTab() -> SettingsTab? {
        guard let raw = value(forFlag: "settings") else { return nil }
        return SettingsTab.allCases.first {
            $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
        }
    }

    /// `--status=Pending|Answered|Expired|Closed|All` — boots the inbox on that
    /// status pill, so each filter's result AND its empty state can be shot.
    static func statusFilter() -> MessageStatusFilter? {
        guard let raw = value(forFlag: "status") else { return nil }
        return MessageStatusFilter.allCases.first {
            $0.rawValue.caseInsensitiveCompare(raw) == .orderedSame
        }
    }

    /// `--select=<project name>|none` — boots with that project selected in the
    /// rail, or with NOTHING selected. Selection is the input to cluster
    /// scoping: which cluster the map highlights and which chip the inbox
    /// applies. A headless pass can only ever see the RESTORED selection, so
    /// without this the scoped-to-another-cluster and the cleared states — the
    /// two the feature is actually about — could not be photographed.
    ///
    /// Picks only a state a click already reaches: it selects by name through
    /// the same store the rail calls, and an unknown name selects nothing.
    static func selection() -> String? { value(forFlag: "select") }

    /// `--mock-empty` — the scripted composition with NO projects: the
    /// first-run welcome surface and the "nothing here yet" inbox.
    static var wantsEmptyRegistry: Bool {
        CommandLine.arguments.contains("--mock-empty")
    }

    /// `--edit-project` — opens the Edit project & links modal on the selected
    /// project at launch. The modal is reached by a click (the card's Links…
    /// button or its context menu), so the bus-entry section and the link editor
    /// are otherwise unphotographable.
    static var wantsProjectEditor: Bool {
        CommandLine.arguments.contains("--edit-project")
    }
}
#endif

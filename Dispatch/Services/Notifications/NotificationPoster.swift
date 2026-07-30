// NotificationPoster.swift
// macOS system notifications for BUS EVENTS. Dispatch's whole reason to
// interrupt a backgrounded human is the switchboard: a project asked another a
// question, an answer landed, or a question closed unanswered. One entry point
// (`post(_:name:)`) takes the same BusEvent the ticker gets, so a banner can
// never describe a fact the ticker does not — BusEventText owns the wording and
// decides which events are worth a banner at all.
//
// AUTHORIZATION (Alan's ruling 2026-07-17): EXPLICIT — one system dialog on
// first post (banners + sound thereafter), never provisional: these cards
// exist precisely to interrupt; provisional's silent Notification-Center-only
// delivery would defeat the point. A denial is remembered for the process and
// degrades to a silent no-op (never a crash, never a re-prompt loop — macOS
// only shows the dialog once anyway).
//
// SUPPRESSION: no post while the app is FRONTMOST — the activity ticker, the
// unanswered badge and the rail's live dots already cover an attentive human;
// a banner on top of the visible inbox is double noise. (Deliberately the
// simple NSApp.isActive proxy — the Messages tab is a fixed fixture of the
// workbench, so "is the inbox visible" adds nothing.)
//
// The UNUserNotificationCenter dependency rides a protocol seam
// (UserNotifying): the real adapter is constructed ONLY in live composition —
// UNUserNotificationCenter crashes under a bare xctest host (no bundle proxy),
// so tests inject a fake and the poster logic stays fully testable.

import AppKit
import Defaults
import Foundation
import UserNotifications
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "notifications")

extension Defaults.Keys {
    /// Banner when one project asks another a question. Default ON — an
    /// inbound question is the whole product, and the human is the fallback
    /// answerer when the asked session is not live.
    static let busQuestionNotificationsEnabled = Key<Bool>(
        "busQuestionNotificationsEnabled", default: true
    )
    /// Banner when an answer lands. Default ON, its own key so the two classes
    /// toggle independently (some humans want the ask, not the reply).
    static let busAnswerNotificationsEnabled = Key<Bool>(
        "busAnswerNotificationsEnabled", default: true
    )
    /// Banner when a question closes without an answer (lapse / unlink /
    /// human close). Default OFF — an expiry is a non-event for an attentive
    /// human and the card already dims itself; opting in is for people who
    /// treat an unanswered question as a failure worth chasing.
    static let busExpiryNotificationsEnabled = Key<Bool>(
        "busExpiryNotificationsEnabled", default: false
    )
}

/// The UNUserNotificationCenter seam. `currentAuthorization` reports the LIVE
/// system verdict (nil = never asked); `requestAuthorization` shows the
/// one-time dialog; `post` delivers a banner. The live adapter wraps the real
/// center; tests inject a recorder.
///
/// `nonisolated`: the project's default actor isolation is MainActor, which
/// would otherwise pin this protocol to the main actor and forbid a non-
/// MainActor `actor` (the test recorder) from conforming.
nonisolated protocol UserNotifying: Sendable {
    func currentAuthorization() async -> Bool?
    func requestAuthorization() async -> Bool
    func post(id: String, title: String, body: String) async
}

/// The real adapter — live composition only (see the header's xctest caveat).
struct SystemUserNotifying: UserNotifying {
    /// The system's CURRENT verdict, re-read every post (audit #7): a deny
    /// flipped back on in System Settings mid-run starts working immediately,
    /// and a granted-then-revoked stops — no process-lifetime cache to go stale.
    func currentAuthorization() async -> Bool? {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        switch settings.authorizationStatus {
        case .notDetermined: return nil
        case .authorized, .provisional: return true
        default: return false
        }
    }

    func requestAuthorization() async -> Bool {
        do {
            // EXPLICIT options (alert + sound) — the ruling; macOS shows the
            // dialog once and remembers, so repeated calls just report status.
            return try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
        } catch {
            logger.warning("notification authorization failed: \(String(describing: error), privacy: .public)")
            return false
        }
    }

    func post(id: String, title: String, body: String) async {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        do {
            try await UNUserNotificationCenter.current().add(request)
        } catch {
            logger.warning("notification post failed: \(String(describing: error), privacy: .public)")
        }
    }
}

@MainActor
@Observable
final class NotificationPoster {

    /// The last authorization verdict Dispatch actually observed: nil = never
    /// asked (or never checked), false = macOS is refusing banners. Settings
    /// reads it, because a pane full of toggles for banners the system will
    /// never show is a pane that lies (audit S4). Never a re-prompt — macOS
    /// shows its dialog once — just the truth and where to change it.
    private(set) var isAuthorized: Bool?

    /// Re-reads the live system verdict (Settings → Notifications on appear).
    func refreshAuthorizationState() async {
        isAuthorized = await center.currentAuthorization()
    }

    @ObservationIgnored private let center: UserNotifying
    /// Frontmost check — live: `NSApp.isActive`; tests script it.
    @ObservationIgnored private let isAppFrontmost: () -> Bool
    /// Per-class Settings gate, read at POST time so a Settings flip applies
    /// immediately (the SoundPlayer discipline) — never captured at init.
    @ObservationIgnored private let isEnabled: (BusEvent) -> Bool

    /// Single-flight for the first-post authorization ask: concurrent posts
    /// while the dialog is up wait for the one verdict instead of re-asking.
    /// The verdict itself is NOT cached (audit #7) — every post re-reads the
    /// live system status, so a System Settings flip applies immediately.
    @ObservationIgnored private var authorizationTask: Task<Bool, Never>?
    /// Delivery tasks in flight (fire-and-forget bookkeeping; test seam).
    @ObservationIgnored private var deliveries: Set<UUID> = []
    /// Test observability: awaits every in-flight delivery.
    func drainDeliveries() async {
        while !deliveries.isEmpty {
            try? await Task.sleep(for: .milliseconds(5))
        }
    }

    init(
        center: UserNotifying,
        // Default = the live NSApp check — kept HERE so the composition root
        // (AppStores) stays AppKit-free; tests script it.
        isAppFrontmost: @escaping () -> Bool = { NSApp?.isActive ?? false },
        isEnabled: @escaping (BusEvent) -> Bool = NotificationPoster.defaultsGate
    ) {
        self.center = center
        self.isAppFrontmost = isAppFrontmost
        self.isEnabled = isEnabled
    }

    /// The live Settings gate: one key per event class. MainActor-isolated
    /// because the Defaults keys are (project default isolation) — and so is
    /// every caller.
    static let defaultsGate: (BusEvent) -> Bool = { event in
        switch event {
        case .asked: Defaults[.busQuestionNotificationsEnabled]
        case .answered: Defaults[.busAnswerNotificationsEnabled]
        case .closed: Defaults[.busExpiryNotificationsEnabled]
        case .connected, .disconnected: false
        }
    }

    /// Post a banner for a bus event — FIRE-AND-FORGET (audit BLOCKER #1): the
    /// first-ever post can raise the macOS permission dialog, which does not
    /// return until the human answers — and the human is, by construction,
    /// AWAY (the frontmost guard). Awaiting that inside `ask_agent`'s tool path
    /// would hang the asking agent's whole turn. So delivery runs detached and
    /// callers return immediately.
    ///
    /// Silent no-op when: the event has no banner (connect/disconnect, or the
    /// human's own arbitration answer), its Settings toggle is off, the app is
    /// frontmost (the ticker and the badge already cover an attentive human),
    /// or authorization is denied. The id is the QUESTION's, so a later event
    /// about the same question replaces its banner rather than stacking.
    ///
    /// - Parameter name: resolves a participant project id to its display name.
    func post(_ event: BusEvent, name: (UUID) -> String?) {
        guard isEnabled(event) else { return }
        guard !isAppFrontmost() else { return }
        guard let content = BusEventText.notification(for: event, name: name) else { return }
        let deliveryID = UUID()
        deliveries.insert(deliveryID)
        Task { [weak self] in
            defer { self?.deliveries.remove(deliveryID) }
            guard let self, await self.ensureAuthorized() else { return }
            await self.center.post(id: content.id, title: content.title, body: content.body)
        }
    }

    private func ensureAuthorized() async -> Bool {
        // The LIVE system verdict rules (audit #7) — no process cache to stale.
        if let verdict = await center.currentAuthorization() {
            isAuthorized = verdict
            if !verdict {
                // Denied is a REAL outcome, not a silent nothing: the banner the
                // caller asked for will not appear, and Settings now says so.
                logger.info("notification suppressed — macOS authorization is denied")
            }
            return verdict
        }
        // Not determined → the one-time explicit dialog, single-flighted so
        // concurrent posts share the ask instead of stacking dialogs.
        if let authorizationTask { return await authorizationTask.value }
        let task = Task { [center] in await center.requestAuthorization() }
        authorizationTask = task
        let verdict = await task.value
        authorizationTask = nil
        isAuthorized = verdict
        return verdict
    }
}

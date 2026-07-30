// BusEventSurfacesTests.swift
// P5's fan-out: one bus event becomes a ticker line, a banner (or deliberately
// not), and the rail's live-dot vocabulary. All three are pure or store-level,
// so they are testable without a window — the UI-verification ladder's rule.

import Defaults
import Foundation
import Testing
@testable import DispatchApp

private nonisolated enum Fix {
    static let ledger = UUID(uuidString: "00000000-0000-0000-0000-00000000E001")!
    static let drift = UUID(uuidString: "00000000-0000-0000-0000-00000000E002")!

    static let names: @Sendable (UUID) -> String? = { id in
        switch id {
        case ledger: "Ledgerline"
        case drift: "Driftwood"
        default: nil
        }
    }

    static func message(
        id: String = "q-abc", from: UUID = drift, to: UUID = ledger,
        subject: String = "Is the cursor opaque?",
        status: BusStatus = .pending, answer: String? = nil,
        byHuman: Bool = false, closedReason: String? = nil
    ) -> BusMessage {
        BusMessage(id: id, from: from, to: to, subject: subject, body: "body…",
                   status: status, answer: answer, answeredByHuman: byHuman,
                   askedAt: Date(timeIntervalSince1970: 1_750_000_000),
                   expiresAt: Date(timeIntervalSince1970: 1_750_086_400),
                   closedReason: closedReason)
    }
}

// MARK: - Ticker vocabulary

@Suite("Bus event ticker vocabulary")
struct BusEventTickerTextTests {

    @Test("asked names both projects in ask order")
    func askedLine() {
        let line = BusEventText.tickerLine(for: .asked(Fix.message()), name: Fix.names)
        #expect(line == "Driftwood asks Ledgerline · “Is the cursor opaque?”")
    }

    @Test("an agent answer names the ANSWERING project; the human's names the human")
    func answeredLines() {
        let byAgent = Fix.message(status: .answered, answer: "Opaque.")
        #expect(BusEventText.tickerLine(for: .answered(byAgent), name: Fix.names)
                == "Ledgerline answered Driftwood · “Is the cursor opaque?”")

        let byHuman = Fix.message(status: .answered, answer: "Opaque.", byHuman: true)
        #expect(BusEventText.tickerLine(for: .answered(byHuman), name: Fix.names)
                == "You answered “Is the cursor opaque?” · arbitration")
    }

    @Test("a close states WHY, so a lapse never reads like an answer")
    func closedLine() {
        let lapsed = Fix.message(status: .expired,
                                 closedReason: "no answer before the question timed out")
        #expect(BusEventText.tickerLine(for: .closed(lapsed), name: Fix.names)
                == "“Is the cursor opaque?” closed — no answer before the question timed out")
    }

    @Test("connect and disconnect are project-level lines")
    func livenessLines() {
        #expect(BusEventText.tickerLine(for: .connected(projectID: Fix.drift), name: Fix.names)
                == "Driftwood connected to the bus")
        #expect(BusEventText.tickerLine(for: .disconnected(projectID: Fix.drift), name: Fix.names)
                == "Driftwood left the bus")
    }

    @Test("a deleted participant degrades to a phrase, never an empty gap or a raw UUID")
    func unknownParticipant() {
        let line = BusEventText.tickerLine(
            for: .asked(Fix.message(from: UUID())), name: Fix.names
        )
        #expect(line == "a removed project asks Ledgerline · “Is the cursor opaque?”")
    }

    @Test("a long subject is clipped, so one line stays one line")
    func subjectClipped() {
        let long = String(repeating: "verbose ", count: 30)
        let quoted = BusEventText.quoted(long)
        #expect(quoted.count < 70)
        #expect(quoted.hasSuffix("…”"))
    }
}

// MARK: - Which events are worth a banner

@Suite("Bus event notification content")
struct BusEventNotificationTests {

    @Test("an inbound question titles who asked whom, bodied by the subject")
    func askedBanner() {
        let content = BusEventText.notification(for: .asked(Fix.message()), name: Fix.names)
        #expect(content?.title == "Driftwood asked Ledgerline a question")
        #expect(content?.body == "Is the cursor opaque?")
        // The id is the QUESTION's, so a later banner about the same question
        // replaces its predecessor rather than stacking.
        #expect(content?.id == "bus-asked-q-abc")
    }

    @Test("an answer banner carries the answer text, not the question again")
    func answeredBanner() {
        let answered = Fix.message(status: .answered, answer: "Opaque — it's a token.")
        let content = BusEventText.notification(for: .answered(answered), name: Fix.names)
        #expect(content?.title == "Ledgerline answered Driftwood")
        #expect(content?.body == "Opaque — it's a token.")
    }

    @Test("the human's OWN answer never notifies them — they just typed it")
    func ownAnswerIsSilent() {
        let mine = Fix.message(status: .answered, answer: "Opaque.", byHuman: true)
        #expect(BusEventText.notification(for: .answered(mine), name: Fix.names) == nil)
    }

    @Test("connect and disconnect never raise a banner (ambient, not news)")
    func livenessIsSilent() {
        #expect(BusEventText.notification(
            for: .connected(projectID: Fix.drift), name: Fix.names) == nil)
        #expect(BusEventText.notification(
            for: .disconnected(projectID: Fix.drift), name: Fix.names) == nil)
    }

    @Test("the Settings gate maps one key per class, and expiry is opt-in")
    @MainActor
    func settingsGate() {
        let priorQuestion = Defaults[.busQuestionNotificationsEnabled]
        let priorExpiry = Defaults[.busExpiryNotificationsEnabled]
        defer {
            Defaults[.busQuestionNotificationsEnabled] = priorQuestion
            Defaults[.busExpiryNotificationsEnabled] = priorExpiry
        }
        // Expiry defaults OFF; the other two default ON.
        #expect(Defaults.Keys.busQuestionNotificationsEnabled.defaultValue)
        #expect(Defaults.Keys.busAnswerNotificationsEnabled.defaultValue)
        #expect(!Defaults.Keys.busExpiryNotificationsEnabled.defaultValue)

        Defaults[.busQuestionNotificationsEnabled] = false
        #expect(!NotificationPoster.defaultsGate(.asked(Fix.message())))
        Defaults[.busQuestionNotificationsEnabled] = true
        #expect(NotificationPoster.defaultsGate(.asked(Fix.message())))
        // Liveness is gated off unconditionally — no key can turn it on.
        #expect(!NotificationPoster.defaultsGate(.connected(projectID: Fix.drift)))
    }
}

// MARK: - Poster behavior (frontmost suppression, gating)

/// Records what actually reached the notification centre.
private actor RecordingNotifier: UserNotifying {
    private(set) var posted: [(id: String, title: String, body: String)] = []
    func currentAuthorization() async -> Bool? { true }
    func requestAuthorization() async -> Bool { true }
    func post(id: String, title: String, body: String) async {
        posted.append((id, title, body))
    }
}

@Suite("Notification poster gating")
@MainActor
struct NotificationPosterTests {

    @Test("a backgrounded app posts an inbound question")
    func postsWhenAway() async {
        let center = RecordingNotifier()
        let poster = NotificationPoster(
            center: center, isAppFrontmost: { false }, isEnabled: { _ in true }
        )
        poster.post(.asked(Fix.message()), name: Fix.names)
        await poster.drainDeliveries()
        #expect(await center.posted.count == 1)
        #expect(await center.posted.first?.title == "Driftwood asked Ledgerline a question")
    }

    @Test("a FRONTMOST app posts nothing — the ticker and badge already cover it")
    func suppressedWhenFrontmost() async {
        let center = RecordingNotifier()
        let poster = NotificationPoster(
            center: center, isAppFrontmost: { true }, isEnabled: { _ in true }
        )
        poster.post(.asked(Fix.message()), name: Fix.names)
        await poster.drainDeliveries()
        #expect(await center.posted.isEmpty)
    }

    @Test("a disabled class posts nothing, and an event with no banner never reaches the centre")
    func gatedAndSilentEvents() async {
        let center = RecordingNotifier()
        let off = NotificationPoster(
            center: center, isAppFrontmost: { false }, isEnabled: { _ in false }
        )
        off.post(.asked(Fix.message()), name: Fix.names)

        let on = NotificationPoster(
            center: center, isAppFrontmost: { false }, isEnabled: { _ in true }
        )
        on.post(.connected(projectID: Fix.drift), name: Fix.names)
        await off.drainDeliveries()
        await on.drainDeliveries()
        #expect(await center.posted.isEmpty)
    }
}

// MARK: - Ticker store

@Suite("Activity store bus recording")
@MainActor
struct ActivityStoreBusTests {

    @Test("one event lands in BOTH participants' tickers")
    func recordedForBothParticipants() {
        let store = ActivityStore()
        store.record(.asked(Fix.message()), name: Fix.names)
        #expect(store.events(in: Fix.ledger).count == 1)
        #expect(store.events(in: Fix.drift).count == 1)
        #expect(store.latest(for: Fix.ledger)?.text
                == "Driftwood asks Ledgerline · “Is the cursor opaque?”")
        #expect(store.latest(for: Fix.ledger)?.category == .bus)
    }

    @Test("a liveness event lands only on its own project")
    func livenessIsSingleProject() {
        let store = ActivityStore()
        store.record(.connected(projectID: Fix.drift), name: Fix.names)
        #expect(store.events(in: Fix.drift).count == 1)
        #expect(store.events(in: Fix.ledger).isEmpty)
    }

    @Test("the ticker is bounded — a long session cannot grow it without limit")
    func trimmedToFeedLimit() {
        let store = ActivityStore()
        for index in 0..<(ActivityStore.feedLimit + 25) {
            store.record(.connected(projectID: Fix.drift),
                         at: Date(timeIntervalSince1970: 1_750_000_000 + Double(index)),
                         name: Fix.names)
        }
        #expect(store.events(in: Fix.drift).count == ActivityStore.feedLimit)
        // The OLDEST are dropped: the newest stamp survives.
        #expect(store.latest(for: Fix.drift)?.time
                == Date(timeIntervalSince1970: 1_750_000_000 + Double(ActivityStore.feedLimit + 24)))
    }
}

// MARK: - Project card liveness vocabulary

@Suite("Project card connection vocabulary")
struct ProjectCardConnectionTests {

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test("each liveness state has words, never colour alone")
    func connectionLabels() {
        #expect(ProjectCardView.connectionLabel(
            .init(isConnected: true, lastSeenAt: Self.now), now: Self.now
        ) == "connected to the bus")

        #expect(ProjectCardView.connectionLabel(.never, now: Self.now)
                == "never connected to the bus")

        let stale = ProjectCardView.connectionLabel(
            .init(isConnected: false, lastSeenAt: Self.now.addingTimeInterval(-3_600)),
            now: Self.now
        )
        #expect(stale.hasPrefix("offline, last seen "))
        #expect(stale.contains("hour"))
    }

    @Test("the card's spoken summary carries liveness, links and the amber count")
    func accessibilitySummarySpeaksEverySignal() {
        let summary = ProjectCardView.accessibilitySummary(
            name: "Ledgerline", repoPath: "~/dev/ledger",
            attentionCount: 3, isSelected: false,
            connection: .init(isConnected: true, lastSeenAt: Self.now),
            linkedPeerNames: ["Driftwood"], now: Self.now
        )
        #expect(summary == "Ledgerline, ~/dev/ledger, connected to the bus, "
                + "linked to Driftwood, 3 questions awaiting an answer")
    }

    @Test("an unlinked project SAYS it is unlinked — the inert state must be audible")
    func unlinkedIsSpoken() {
        let summary = ProjectCardView.accessibilitySummary(
            name: "Halyard", repoPath: "~/dev/halyard",
            attentionCount: 0, isSelected: false, connection: .never, now: Self.now
        )
        #expect(summary.contains("not linked to any project"))
        #expect(summary.contains("never connected to the bus"))
    }
}

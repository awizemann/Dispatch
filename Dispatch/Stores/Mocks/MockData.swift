// MockData.swift
// The scripted `--mock-scenario` switchboard — the fixture the verify skill
// launches and screenshots, and the one every preview and store test composes.
//
// Shaped to show the product's whole state space on one screen:
//  • Ledgerline (pinned, selected, LIVE on the bus, linked to Driftwood)
//  • Driftwood  (linked to Ledgerline, last seen a few minutes ago)
//  • Halyard    (UNLINKED and never connected, `.mcp.json` not installed —
//                the "you haven't finished setting this one up" card)
// and bus traffic covering every card state: answered by a project, answered by
// the human, pending inbound, pending outbound, expired, and human-closed.
//
// The scenario NEVER persists: MockGlobalPersistence is an in-memory actor.

import Foundation

@MainActor
enum MockData {

    // Stable IDs so cross-references (projects ↔ links ↔ messages) hold.
    enum ID {
        static let ledgerline = UUID(uuidString: "00000000-0000-0000-0000-00000000A001")!
        static let driftwood = UUID(uuidString: "00000000-0000-0000-0000-00000000A002")!
        static let halyard = UUID(uuidString: "00000000-0000-0000-0000-00000000A003")!
        // A SECOND, separate network — the rail's cluster sections and the map's
        // "other cluster dims" only mean something with two of them on screen.
        static let beacon = UUID(uuidString: "00000000-0000-0000-0000-00000000A004")!
        static let kestrel = UUID(uuidString: "00000000-0000-0000-0000-00000000A005")!

        // Bus questions between the two linked projects.
        static let qAnswered = "q-00000000000000000000000000000a01"
        static let qAnsweredByHuman = "q-00000000000000000000000000000a02"
        static let qPending = "q-00000000000000000000000000000a03"
        static let qPendingOutbound = "q-00000000000000000000000000000a04"
        static let qExpired = "q-00000000000000000000000000000a05"
        static let qClosed = "q-00000000000000000000000000000a06"
        /// The one a live session answers a few seconds after launch — the
        /// sync-when-live long poll, made visible (see `startLivePoll`).
        static let qLivePoll = "q-00000000000000000000000000000a07"
        /// Traffic on the SECOND network, so its chip and cards exist too.
        static let qSecondNetwork = "q-00000000000000000000000000000a08"
    }

    /// The scripted composition.
    ///
    /// - Parameter live: run the scripted long-poll answer a few seconds in.
    ///   OFF by default — previews and store tests must be deterministic; only
    ///   the `--mock-scenario` app launch turns it on.
    static func makeStores(live: Bool = false) -> AppStores {
        let global = MockGlobalPersistence(
            projects: projects, projectLinks: projectLinks, busMessages: busMessages
        )
        let stores = AppStores(
            projects: ProjectStore(
                reader: global,
                writers: global.projectWriters(),
                // Scripted git values must stay exactly as authored, so no
                // periodic refresh; the add-project flow still refreshes new
                // rows through this fake.
                git: MockGitStatus(),
                gitRefreshInterval: nil
            ),
            messages: MessageStore(global: global),
            activity: ActivityStore(),
            // Links observed off the mock global actor; add/remove routes
            // through the same writers shape the live composition builds.
            crossProject: CrossProjectStore(global: global, writers: global.linkWriters())
        )
        // Human arbitration (Answer / Close) against the mock global — previews
        // and the click pass exercise the full flip without the bus.
        stores.arbitration = MockBusArbitrator(global: global)
        // No router in the mock composition, so liveness is scripted: one
        // project live, one seen recently, one never connected.
        stores.mockConnections = [
            ID.ledgerline: .init(isConnected: true, lastSeenAt: .now.addingTimeInterval(-20)),
            ID.driftwood: .init(isConnected: true, lastSeenAt: .now.addingTimeInterval(-260)),
            ID.halyard: .never,
            ID.beacon: .init(isConnected: true, lastSeenAt: .now.addingTimeInterval(-40)),
            ID.kestrel: .never,
        ]
        stores.repoInstallStates = [
            ID.ledgerline: .installed,
            ID.driftwood: .installed,
            ID.halyard: .missing,
            ID.beacon: .installed,
            ID.kestrel: .installed,
        ]
        // Session hooks: opt-in and off by default, so the mock
        // shows BOTH — Ledgerline has taken it, the other two have not.
        stores.repoHooksStates = [ID.ledgerline: .installed]
        // Bus-token exposure: Ledgerline brought its OWN
        // `.mcp.json`, so Dispatch never gitignored it and says so — quietly.
        // Every other repo's file is one we created and ignored, which is the
        // silent case, so the mock shows both.
        stores.repoTokenExposure = [ID.ledgerline: .committedFile]
        // Counts come from the FIXTURE, not the store: the project registry
        // only fills in on `activate()`, and the footer must read true from the
        // first frame the screenshot pass captures.
        // Project icons: two projects with a discovered-looking
        // icon, three on the letter tile — the mixed state both surfaces have
        // to render. Drawn in code; the scenario's repo paths are fixtures, so
        // real discovery would (correctly) find nothing at all.
        MockProjectIcons.seed(into: stores.icons)
        stores.seedMockBusStatus(port: 51_872, projectCount: projects.count)
        stores.seedMockActivity(activityEvents)
        if live { startLivePoll(stores: stores, global: global) }
        return stores
    }

    /// The sync-when-live path, on a timer: a few seconds after launch the
    /// Driftwood session "picks up the channel" and answers the outstanding
    /// question. The card flips through the SAME observation stream the live
    /// database drives, and the ticker/badge follow — which is exactly what a
    /// long poll returning an answer looks like from the human's side.
    private static func startLivePoll(stores: AppStores, global: MockGlobalPersistence) {
        Task { @MainActor [weak stores] in
            try? await Task.sleep(for: .seconds(6))
            guard let stores else { return }
            let answered = await global.answerBusMessage(
                id: ID.qLivePoll,
                text: "Yes — the worker retries 429s with exponential backoff up to 5 attempts. "
                    + "Don't back off on your side too or you'll double the delay.",
                byHuman: false
            )
            guard answered,
                  let message = await global.busMessage(id: ID.qLivePoll) else { return }
            stores.handle(busEvent: .answered(message))
        }
    }

    /// The same composition with an EMPTY registry — the first-run surfaces
    /// (welcome sheet, "add a project" inbox, empty rail, bus with nothing on
    /// it). Deliberately the real empty state, not a mocked-up picture of one.
    static func makeEmptyStores() -> AppStores {
        let global = MockGlobalPersistence(projects: [])
        let stores = AppStores(
            projects: ProjectStore(
                reader: global, writers: global.projectWriters(),
                git: MockGitStatus(), gitRefreshInterval: nil
            ),
            messages: MessageStore(global: global),
            activity: ActivityStore(),
            crossProject: CrossProjectStore(global: global, writers: global.linkWriters())
        )
        stores.arbitration = MockBusArbitrator(global: global)
        stores.seedMockBusStatus(port: 51_872, projectCount: 0)
        return stores
    }

    /// Display name for a scripted project id (question-card previews).
    static func projectName(_ projectID: UUID) -> String? {
        projects.first { $0.id == projectID }?.name
    }

    // MARK: - Projects

    static let projects: [Project] = [
        Project(
            id: ID.ledgerline, name: "Ledgerline", repoPath: "~/Developer/Ledgerline",
            pinned: true,
            git: GitStatus(openPRs: 0, openTickets: 0, unpushedCommits: 3, branch: "main"),
            lastOpenedAt: .now,
            sessionHooksEnabled: true
        ),
        Project(
            id: ID.driftwood, name: "Driftwood", repoPath: "~/Developer/Driftwood",
            pinned: false,
            git: GitStatus(openPRs: 0, openTickets: 0, unpushedCommits: 0,
                           branch: "feature/sync-worker"),
            lastOpenedAt: .now.addingTimeInterval(-3_600)
        ),
        Project(
            id: ID.halyard, name: "Halyard", repoPath: "~/Developer/Halyard",
            pinned: false,
            git: GitStatus(openPRs: 0, openTickets: 0, unpushedCommits: 0, branch: "main"),
            lastOpenedAt: nil
        ),
        Project(
            id: ID.beacon, name: "Beacon", repoPath: "~/Developer/Beacon",
            pinned: false,
            git: GitStatus(openPRs: 0, openTickets: 0, unpushedCommits: 1, branch: "main"),
            lastOpenedAt: .now.addingTimeInterval(-86_400)
        ),
        Project(
            id: ID.kestrel, name: "Kestrel", repoPath: "~/Developer/Kestrel",
            pinned: false,
            git: GitStatus(openPRs: 0, openTickets: 0, unpushedCommits: 0, branch: "main"),
            lastOpenedAt: .now.addingTimeInterval(-172_800)
        ),
    ]

    /// Halyard is deliberately UNLINKED — the rail must show what an unfinished
    /// project looks like, and `ask_agent` fails closed against it.
    /// Two SEPARATE networks plus one unlinked project — Ledgerline–Driftwood,
    /// Beacon–Kestrel, and Halyard on its own. That is the smallest scenario in
    /// which the rail's cluster sections, the map's cluster dimming and the
    /// "off the network" treatment are all visible at once.
    static let projectLinks: [ProjectLink] = [
        ProjectLink(ID.ledgerline, ID.driftwood,
                    createdAt: .now.addingTimeInterval(-200_000)),
        ProjectLink(ID.beacon, ID.kestrel,
                    createdAt: .now.addingTimeInterval(-120_000)),
    ]

    // MARK: - Bus traffic

    /// One row per state the Messages tab renders.
    static let busMessages: [BusMessage] = [
        BusMessage(id: ID.qAnswered, from: ID.driftwood, to: ID.ledgerline,
                   subject: "Is the ledger cursor opaque?",
                   body: "Is the ledger pagination cursor opaque, or a (date, id) tuple we can construct?",
                   status: .answered, answer: "Opaque — treat it as a token; the shape changes.",
                   answeredByHuman: false,
                   askedAt: .now.addingTimeInterval(-9_000),
                   answeredAt: .now.addingTimeInterval(-8_400),
                   deliveredAt: .now.addingTimeInterval(-8_800),
                   expiresAt: .now.addingTimeInterval(77_400)),
        BusMessage(id: ID.qAnsweredByHuman, from: ID.driftwood, to: ID.ledgerline,
                   subject: "Empty-state illustration style?",
                   body: "Line art or filled glyphs for the shared empty states?",
                   status: .answered, answer: "Line art — match the onboarding screens.",
                   answeredByHuman: true,
                   askedAt: .now.addingTimeInterval(-7_200),
                   answeredAt: .now.addingTimeInterval(-6_900),
                   deliveredAt: .now.addingTimeInterval(-7_100),
                   expiresAt: .now.addingTimeInterval(79_200)),
        BusMessage(id: ID.qPending, from: ID.driftwood, to: ID.ledgerline,
                   subject: "Migration strategy for the ledger table",
                   body: "Copy-and-swap or in-place ALTER for the ledger table? "
                       + "We mirror the schema and need to match.",
                   status: .pending,
                   askedAt: .now.addingTimeInterval(-3_600),
                   deliveredAt: .now.addingTimeInterval(-3_500),
                   expiresAt: .now.addingTimeInterval(82_800)),
        BusMessage(id: ID.qLivePoll, from: ID.ledgerline, to: ID.driftwood,
                   subject: "Does the sync worker retry 429s?",
                   body: "Does the Driftwood sync worker retry on 429, or should we back off ourselves? "
                       + "Asking with wait_seconds — your session is live.",
                   status: .pending,
                   askedAt: .now.addingTimeInterval(-40),
                   deliveredAt: .now.addingTimeInterval(-38),
                   expiresAt: .now.addingTimeInterval(86_360)),
        BusMessage(id: ID.qPendingOutbound, from: ID.ledgerline, to: ID.driftwood,
                   subject: "Which timezone do exported statements use?",
                   body: "Are exported statement timestamps UTC or the account's local zone?",
                   status: .pending,
                   askedAt: .now.addingTimeInterval(-1_200),
                   // Nearly lapsed — the countdown on this card is the one that
                   // shows what an expiry timer looks like when it matters.
                   expiresAt: .now.addingTimeInterval(2_700)),
        BusMessage(id: ID.qExpired, from: ID.ledgerline, to: ID.driftwood,
                   subject: "Any objection to renaming the export column?",
                   body: "Renaming `amount_cents` to `amount_minor` — any objection on your side?",
                   status: .expired,
                   askedAt: .now.addingTimeInterval(-180_000),
                   deliveredAt: .now.addingTimeInterval(-179_000),
                   expiresAt: .now.addingTimeInterval(-93_600),
                   closedReason: "no answer before the question timed out"),
        BusMessage(id: ID.qClosed, from: ID.driftwood, to: ID.ledgerline,
                   subject: "Should we mirror the audit log too?",
                   body: "Do you want Driftwood mirroring the ledger audit log, or is that yours alone?",
                   status: .closed,
                   askedAt: .now.addingTimeInterval(-260_000),
                   deliveredAt: .now.addingTimeInterval(-259_000),
                   expiresAt: .now.addingTimeInterval(-173_600),
                   closedReason: BusCloseReason.human),
        // The second network's own traffic — proves a cluster is a real, live
        // neighbourhood and gives its chips something to filter to.
        BusMessage(id: ID.qSecondNetwork, from: ID.beacon, to: ID.kestrel,
                   subject: "Which clock stamps a flight record?",
                   body: "Does Kestrel stamp flight records with the device clock or the server's?",
                   status: .pending,
                   askedAt: .now.addingTimeInterval(-5_400),
                   deliveredAt: .now.addingTimeInterval(-5_300),
                   expiresAt: .now.addingTimeInterval(81_000)),
    ]

    // MARK: - Ticker

    /// Scripted ticker history, in the live vocabulary (BusEventText). Seeded
    /// against both participants exactly as `ActivityStore.record` would.
    static let activityEvents: [(event: BusEvent, at: Date)] = [
        (.asked(busMessages[0]), .now.addingTimeInterval(-9_000)),
        (.answered(busMessages[0]), .now.addingTimeInterval(-8_400)),
        (.answered(busMessages[1]), .now.addingTimeInterval(-6_900)),
        (.asked(busMessages[2]), .now.addingTimeInterval(-3_600)),
        (.connected(projectID: ID.driftwood), .now.addingTimeInterval(-300)),
        (.asked(busMessages[3]), .now.addingTimeInterval(-40)),
    ]
}

// MARK: - Mock-composition seams

extension AppStores {
    /// Scripted listener status — the mock has no real listener, and a footer
    /// reading "bus down" would misrepresent the scenario.
    func seedMockBusStatus(port: Int, projectCount: Int) {
        busStatus = BusListenerStatus(
            port: port,
            installedCount: repoInstallStates.count { $0.value == .installed },
            projectCount: projectCount
        )
    }

    /// Replays scripted bus events into the ticker WITHOUT sounds or banners —
    /// this is history, not news.
    func seedMockActivity(_ scripted: [(event: BusEvent, at: Date)]) {
        for entry in scripted {
            activity.record(entry.event, at: entry.at,
                            name: { [weak self] id in self?.projects.project(id: id)?.name })
        }
    }
}

// MARK: - Mock arbitration seam

/// Mock-composition stand-in for DispatchRouter's arbitration API (the router is
/// live-only): records the answer/close on the mock global persistence, whose
/// broadcast drives MessageStore exactly like the real DB observation. The
/// pending-only guards match the live transactions, so a card that already
/// flipped refuses here too.
@MainActor
final class MockBusArbitrator: BusArbitrating {
    private let global: MockGlobalPersistence

    init(global: MockGlobalPersistence) {
        self.global = global
    }

    func answer(messageID: String, text: String, byHuman: Bool) async throws {
        guard await global.answerBusMessage(id: messageID, text: text, byHuman: byHuman) else {
            throw BusToolFailure.alreadyAnswered(messageID)
        }
    }

    func close(messageID: String, reason: String) async throws {
        guard await global.closeBusMessage(id: messageID, reason: reason) != nil else {
            throw BusToolFailure.alreadyAnswered(messageID)
        }
    }
}

// MessagesInboxTests.swift
// The Messages tab's logic, store-level per the UI-verification
// ladder: the pure filter/sort/count core, the inbox model's debounce +
// inline-answer state machine against a fake arbitration seam, the full
// arbitration flip through MockGlobalPersistence → MessageStore (what the
// badge and the card read), and the close/nudge moves beside it.

import Foundation
import Testing
@testable import DispatchApp

// MARK: - Fixtures

private nonisolated enum Fix {
    /// The project whose inbox is under test, and its two linked peers.
    static let project = UUID(uuidString: "00000000-0000-0000-0000-00000000F001")!
    static let alpha = UUID(uuidString: "00000000-0000-0000-0000-00000000F002")!
    static let beta = UUID(uuidString: "00000000-0000-0000-0000-00000000F003")!

    static func label(_ id: UUID) -> String {
        switch id {
        case project: "Ledgerline"
        case alpha: "Alpha"
        case beta: "Beta"
        default: ""
        }
    }

    static let noLabel: @Sendable (UUID) -> String = { _ in "" }

    /// `askedAt` is derived from the id's numeric suffix unless `seconds` says
    /// otherwise, so "MSG-010 is newer than MSG-002" stays legible in the
    /// ordering assertions even though P3's real ids are random correlation ids
    /// and `askedAt` is the actual sort key.
    static func message(
        _ id: String, seconds: TimeInterval? = nil,
        from: UUID = alpha, to: UUID = project,
        subject: String = "Cursor pagination?",
        body: String = "Offset paging janks past 2k rows.",
        status: BusStatus = .pending, answer: String? = nil, byHuman: Bool = false
    ) -> BusMessage {
        let offset = seconds ?? TimeInterval(Int(id.split(separator: "-").last ?? "") ?? 0)
        return BusMessage(id: id, from: from, to: to, subject: subject, body: body,
                          status: status, answer: answer, answeredByHuman: byHuman,
                          askedAt: Date(timeIntervalSince1970: 1_750_000_000 + offset),
                          expiresAt: Date(timeIntervalSince1970: 1_750_086_400 + offset))
    }
}

/// Records arbitration calls; optionally throws (the alreadyAnswered race).
@MainActor
private final class FakeArbitrator: BusArbitrating {
    var calls: [(messageID: String, text: String, byHuman: Bool)] = []
    var closes: [(messageID: String, reason: String)] = []
    var failure: Error?

    func answer(messageID: String, text: String, byHuman: Bool) async throws {
        if let failure { throw failure }
        calls.append((messageID, text, byHuman))
    }

    func close(messageID: String, reason: String) async throws {
        if let failure { throw failure }
        closes.append((messageID, reason))
    }
}

/// Polls until `condition` holds (observation streams deliver asynchronously).
@MainActor
private func eventually(
    _ condition: @MainActor () -> Bool, timeout: Duration = .seconds(2)
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: - Pure core

@Suite("Message inbox logic (pure)")
struct MessageInboxLogicTests {

    @Test("newest first by askedAt, with the id as the same-instant tiebreaker")
    func ordering() {
        let shuffled = [
            Fix.message("MSG-002"), Fix.message("MSG-010"), Fix.message("MSG-009"),
        ]
        let sorted = MessageInboxLogic.newestFirst(shuffled)
        #expect(sorted.map(\.id) == ["MSG-010", "MSG-009", "MSG-002"])
    }

    @Test("counts split all/pending/answered/expired/closed")
    func counts() {
        var lapsed = Fix.message("MSG-004")
        lapsed.status = .expired
        lapsed.closedReason = "work item “x” landed Done"
        let messages = [
            Fix.message("MSG-001", status: .answered, answer: "Yes."),
            Fix.message("MSG-002"), Fix.message("MSG-003"), lapsed,
            Fix.message("MSG-005", status: .closed),
        ]
        #expect(MessageInboxLogic.counts(of: messages)
                == MessageCounts(all: 5, pending: 2, answered: 1, expired: 1, closed: 1))
    }

    @Test("the Closed pill filters to closed rows only; a closed row never matches Pending/Answered/Expired")
    func notesFilter() {
        let note = Fix.message("MSG-006", status: .closed)
        let match = { (message: BusMessage, filter: MessageStatusFilter) in
            MessageInboxLogic.matches(message, query: "", status: filter,
                                      peerID: nil, projectLabel: { _ in "" })
        }
        #expect(match(note, .closed))
        #expect(match(note, .all))
        #expect(!match(note, .pending))
        #expect(!match(note, .answered))
        #expect(!match(note, .expired))
        #expect(!match(Fix.message("MSG-007"), .closed))
    }

    @Test("the Expired pill filters to expired only; expired never matches Pending or Answered")
    func lapsedFilter() {
        var lapsed = Fix.message("MSG-004")
        lapsed.status = .expired
        let match = { (message: BusMessage, filter: MessageStatusFilter) in
            MessageInboxLogic.matches(message, query: "", status: filter,
                                      peerID: nil, projectLabel: { _ in "" })
        }
        #expect(match(lapsed, .expired))
        #expect(match(lapsed, .all))
        #expect(!match(lapsed, .pending))
        #expect(!match(lapsed, .answered))
        #expect(!match(Fix.message("MSG-005"), .expired))
    }

    @Test("search matches subject, body, answer, and id, case-insensitively")
    func searchFields() {
        let message = Fix.message(
            "MSG-007", subject: "Deep link check",
            body: "Pricing page links to crew://upgrade.",
            status: .answered, answer: "Ships next milestone."
        )
        for query in ["deep LINK", "crew://upgrade", "next MILESTONE", "msg-007"] {
            #expect(MessageInboxLogic.matches(
                message, query: query, status: .all, peerID: nil,
                projectLabel: Fix.noLabel
            ), "query \(query) should match")
        }
        #expect(!MessageInboxLogic.matches(
            message, query: "kanban", status: .all, peerID: nil,
            projectLabel: Fix.noLabel
        ))
    }

    @Test("search matches participant project names via the label seam")
    func searchAgents() {
        let message = Fix.message("MSG-001")
        func matches(_ query: String) -> Bool {
            MessageInboxLogic.matches(
                message, query: query, status: .all, peerID: nil,
                projectLabel: Fix.label(_:)
            )
        }
        #expect(matches("alpha"), "the ASKING project's name matches, case-insensitively")
        #expect(matches("Ledgerline"), "the ASKED project's name matches")
        #expect(!matches("Beta"))  // not a participant in this question
    }

    @Test("status pills narrow to pending / answered")
    func statusFilter() {
        let open = Fix.message("MSG-001")
        let answered = Fix.message("MSG-002", status: .answered, answer: "Yes.")
        func matches(_ message: BusMessage, _ status: MessageStatusFilter) -> Bool {
            MessageInboxLogic.matches(
                message, query: "", status: status, peerID: nil,
                projectLabel: Fix.noLabel
            )
        }
        #expect(matches(open, .pending))
        #expect(!matches(open, .answered))
        #expect(matches(answered, .answered))
        #expect(!matches(answered, .pending))
    }

    @Test("peer chip matches asker OR addressee")
    func agentFilter() {
        let message = Fix.message("MSG-001")
        func matches(_ peerID: UUID) -> Bool {
            MessageInboxLogic.matches(
                message, query: "", status: .all, peerID: peerID,
                projectLabel: Fix.noLabel
            )
        }
        #expect(matches(Fix.alpha))
        #expect(matches(Fix.project))
        #expect(!matches(Fix.beta))
    }

    @Test("apply combines all filters and keeps newest-first order")
    func combined() {
        let messages = [
            Fix.message("MSG-001", status: .answered, answer: "Opaque token."),
            Fix.message("MSG-002", subject: "Dark mode snapshots"),
            Fix.message("MSG-003", from: Fix.beta, subject: "Dark mode baseline"),
        ]
        let result = MessageInboxLogic.apply(
            messages, query: "dark", status: .pending, peerID: Fix.alpha,
            projectLabel: Fix.noLabel
        )
        #expect(result.map(\.id) == ["MSG-002"])
    }
}

// MARK: - Compact-list expansion (pure)

@Suite("Message expansion logic (pure)")
struct MessageExpansionLogicTests {

    @Test("default (no global override) is collapsed; per-card set expands one")
    func defaultCollapsed() {
        #expect(!MessageInboxLogic.isExpanded(
            globalOverride: nil, overrides: [], messageID: "MSG-001"))
        #expect(MessageInboxLogic.isExpanded(
            globalOverride: nil, overrides: ["MSG-001"], messageID: "MSG-001"))
        #expect(!MessageInboxLogic.isExpanded(
            globalOverride: nil, overrides: ["MSG-001"], messageID: "MSG-002"))
    }

    @Test("expand-all base: overrides collapse the listed card back")
    func expandAllBase() {
        #expect(MessageInboxLogic.isExpanded(
            globalOverride: true, overrides: [], messageID: "MSG-001"))
        // Toggled AGAINST the expand-all base → collapsed.
        #expect(!MessageInboxLogic.isExpanded(
            globalOverride: true, overrides: ["MSG-001"], messageID: "MSG-001"))
    }

    @Test("collapse-all base: overrides expand the listed card")
    func collapseAllBase() {
        #expect(!MessageInboxLogic.isExpanded(
            globalOverride: false, overrides: [], messageID: "MSG-001"))
        #expect(MessageInboxLogic.isExpanded(
            globalOverride: false, overrides: ["MSG-001"], messageID: "MSG-001"))
    }
}

// MARK: - Windowed presentation (pure)

@Suite("Message window logic (pure)")
struct MessageWindowLogicTests {

    private func messages(_ count: Int) -> [BusMessage] {
        (1...count).map { Fix.message("MSG-\(String(format: "%03d", $0))") }
    }

    @Test("first page shows the newest N; older rows remain")
    func firstPage() {
        let all = MessageInboxLogic.newestFirst(messages(120))
        let page1 = MessageInboxLogic.window(all, pageCount: 1)
        #expect(page1.count == MessageInboxLogic.pageSize)
        #expect(page1.first?.id == "MSG-120")   // newest first
        #expect(page1.last?.id == "MSG-071")    // 50th newest
        #expect(MessageInboxLogic.hasMore(filteredCount: all.count, pageCount: 1))
    }

    @Test("growing the window reveals the next page")
    func secondPage() {
        let all = MessageInboxLogic.newestFirst(messages(120))
        let page2 = MessageInboxLogic.window(all, pageCount: 2)
        #expect(page2.count == 100)
        #expect(page2.last?.id == "MSG-021")
        #expect(MessageInboxLogic.hasMore(filteredCount: all.count, pageCount: 2))
    }

    @Test("boundary at exactly N: no 'load older', whole set shown")
    func exactBoundary() {
        let all = MessageInboxLogic.newestFirst(messages(MessageInboxLogic.pageSize))
        let page = MessageInboxLogic.window(all, pageCount: 1)
        #expect(page.count == MessageInboxLogic.pageSize)
        #expect(!MessageInboxLogic.hasMore(
            filteredCount: all.count, pageCount: 1))
    }

    @Test("window past the count clamps to the count")
    func overshoot() {
        let all = messages(10)
        #expect(MessageInboxLogic.window(all, pageCount: 5).count == 10)
        #expect(!MessageInboxLogic.hasMore(filteredCount: 10, pageCount: 1))
    }
}

// MARK: - Inbox model

@Suite("Messages inbox model")
@MainActor
struct MessagesInboxModelTests {

    @Test("zero debounce applies the query synchronously")
    func immediateSearch() {
        let model = MessagesInboxModel(debounce: .zero)
        model.setSearch("cursor")
        #expect(model.query == "cursor")
    }

    @Test("debounce trails the field and coalesces rapid keystrokes")
    func debouncedSearch() async {
        let model = MessagesInboxModel(debounce: .milliseconds(30))
        model.setSearch("c")
        model.setSearch("cu")
        model.setSearch("cur")
        // Deterministically safe: no await between the keystrokes and this
        // assertion, so the test holds the main actor and the debounce task
        // cannot interleave — the window genuinely hasn't elapsed here.
        #expect(model.query.isEmpty)
        // Drain the in-flight debounce via the seam instead of wall-clock
        // polling: at 895-test parallel scale the shared main actor starved
        // the 30ms timer past the old 2s eventually-deadline (two consecutive
        // full-run failures). Awaiting the task has no deadline to lose.
        await model.awaitPendingSearchForTesting()
        #expect(model.query == "cur")  // coalesced: only the last text applied
    }

    @Test("peer chip toggles on and off; clearFilters resets everything")
    func filterState() {
        let model = MessagesInboxModel(debounce: .zero)
        model.togglePeerFilter(Fix.alpha)
        #expect(model.peerFilter == Fix.alpha)
        model.togglePeerFilter(Fix.alpha)
        #expect(model.peerFilter == nil)

        model.togglePeerFilter(Fix.project)
        model.statusFilter = .answered
        model.setSearch("cursor")
        model.clearFilters()
        #expect(model.peerFilter == nil)
        #expect(model.statusFilter == .all)
        #expect(model.searchText.isEmpty && model.query.isEmpty)
    }

    @Test("submit trims, rejects empty drafts, and never calls the seam for them")
    func emptyDraftRejected() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        let message = Fix.message("MSG-001")

        model.beginAnswering("MSG-001")
        model.draft = "   \n  "
        let accepted = await model.submitAnswer(for: message, using: arbitrator)
        #expect(!accepted)
        #expect(arbitrator.calls.isEmpty)
        #expect(model.answeringID == "MSG-001")  // editor stays open
    }

    @Test("successful arbitration passes byHuman + trimmed text and closes the editor")
    func submitSuccess() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        let message = Fix.message("MSG-004")

        model.beginAnswering("MSG-004")
        model.draft = "  Copy-and-swap — safer rollback.  "
        let accepted = await model.submitAnswer(for: message, using: arbitrator)

        #expect(accepted)
        #expect(arbitrator.calls.count == 1)
        #expect(arbitrator.calls[0].messageID == "MSG-004")
        #expect(arbitrator.calls[0].text == "Copy-and-swap — safer rollback.")
        #expect(arbitrator.calls[0].byHuman)
        #expect(model.answeringID == nil)
        #expect(model.draft.isEmpty)
    }

    @Test("a failed submit (alreadyAnswered race) keeps the editor and draft")
    func submitFailure() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        arbitrator.failure = BusToolFailure.alreadyAnswered("MSG-004")
        let message = Fix.message("MSG-004")

        model.beginAnswering("MSG-004")
        model.draft = "Copy-and-swap."
        let accepted = await model.submitAnswer(for: message, using: arbitrator)

        #expect(!accepted)
        #expect(model.answeringID == "MSG-004")
        #expect(model.draft == "Copy-and-swap.")
    }

    @Test("revealIfHidden clears filters only when they hide the target")
    func revealIfHidden() {
        let model = MessagesInboxModel(debounce: .zero)
        let open = Fix.message("MSG-002")

        // Visible under current filters → untouched.
        model.statusFilter = .pending
        model.revealIfHidden(open, projectLabel: Fix.noLabel)
        #expect(model.statusFilter == .pending)

        // Hidden (answered filter vs open card) → cleared.
        model.statusFilter = .answered
        model.setSearch("unrelated")
        model.revealIfHidden(open, projectLabel: Fix.noLabel)
        #expect(model.statusFilter == .all)
        #expect(model.query.isEmpty)
    }

    @Test("revealIfHidden also clears a PENDING debounced query that would hide the card")
    func revealBeatsDebounce() async {
        let model = MessagesInboxModel(debounce: .milliseconds(30))
        let open = Fix.message("MSG-002")  // subject "Cursor pagination?"

        model.setSearch("unrelated")       // still inside the debounce window
        #expect(model.query.isEmpty)
        model.revealIfHidden(open, projectLabel: Fix.noLabel)

        // The pending query must have been cancelled, not just the applied one.
        try? await Task.sleep(for: .milliseconds(80))
        #expect(model.searchText.isEmpty)
        #expect(model.query.isEmpty)
    }

    // MARK: Compact list — expansion

    @Test("cards default collapsed; per-card toggle flips just that card")
    func perCardToggle() {
        let model = MessagesInboxModel(debounce: .zero)
        #expect(!model.isExpanded("MSG-001"))
        model.toggleExpansion("MSG-001")
        #expect(model.isExpanded("MSG-001"))
        #expect(!model.isExpanded("MSG-002"))
        model.toggleExpansion("MSG-001")
        #expect(!model.isExpanded("MSG-001"))
    }

    @Test("expand-all expands every card; a per-card toggle then collapses one")
    func expandAllThenToggle() {
        let model = MessagesInboxModel(debounce: .zero)
        model.setGlobalExpansion(true)
        #expect(model.allExpanded)
        #expect(model.isExpanded("MSG-001"))
        #expect(model.isExpanded("MSG-999"))
        // Toggle one against the expand-all base → collapsed, and the header no
        // longer reads fully-expanded.
        model.toggleExpansion("MSG-001")
        #expect(!model.isExpanded("MSG-001"))
        #expect(model.isExpanded("MSG-002"))
        #expect(!model.allExpanded)
    }

    @Test("a new global command clears per-card overrides so all cards obey")
    func globalCommandClearsOverrides() {
        let model = MessagesInboxModel(debounce: .zero)
        model.toggleExpansion("MSG-001")     // expanded via per-card
        model.setGlobalExpansion(false)      // collapse-all
        #expect(!model.isExpanded("MSG-001")) // override cleared
        model.setGlobalExpansion(true)        // expand-all
        #expect(model.isExpanded("MSG-001"))
    }

    // MARK: Compact list — pagination

    @Test("loadMore grows the window; filter change resets it to the newest page")
    func windowGrowsAndResets() {
        let model = MessagesInboxModel(debounce: .zero)
        #expect(model.visiblePageCount == 1)
        model.loadMore()
        model.loadMore()
        #expect(model.visiblePageCount == 3)

        // Any filter change returns to the first page.
        model.statusFilter = .pending
        #expect(model.visiblePageCount == 1)

        model.loadMore()
        model.togglePeerFilter(Fix.alpha)
        #expect(model.visiblePageCount == 1)

        model.loadMore()
        model.setSearch("cursor")            // zero-debounce applies immediately
        #expect(model.visiblePageCount == 1)

        model.loadMore()
        model.clearFilters()
        #expect(model.visiblePageCount == 1)
    }

    @Test("setting the same filter value does not reset the window")
    func noResetOnSameValue() {
        let model = MessagesInboxModel(debounce: .zero)
        model.statusFilter = .pending
        model.loadMore()
        #expect(model.visiblePageCount == 2)
        model.statusFilter = .pending           // unchanged
        #expect(model.visiblePageCount == 2)
    }

    @Test("focus grows the window to include an old card and expands it")
    func focusRevealsOldCard() {
        let model = MessagesInboxModel(debounce: .zero)
        #expect(model.visiblePageCount == 1)
        // Rank 120 sits on the 3rd page (pageSize 50).
        model.focus(rank: 120, messageID: "MSG-001")
        #expect(model.visiblePageCount == 3)
        #expect(model.isExpanded("MSG-001"))
        // A card already on the first page needs no window growth.
        let fresh = MessagesInboxModel(debounce: .zero)
        fresh.focus(rank: 3, messageID: "MSG-050")
        #expect(fresh.visiblePageCount == 1)
        #expect(fresh.isExpanded("MSG-050"))
    }
}

// MARK: - Age & expiry (pure — the pending card's clock)

@Suite("Pending-card age and expiry (pure)")
struct MessageTimingTests {

    private static let now = Date(timeIntervalSince1970: 1_750_000_000)

    private func pending(expiresIn seconds: TimeInterval, askedAgo: TimeInterval = 3_600)
        -> BusMessage {
        BusMessage(
            id: "MSG-001", from: Fix.alpha, to: Fix.project,
            subject: "s", body: "b", status: .pending,
            askedAt: Self.now.addingTimeInterval(-askedAgo),
            expiresAt: Self.now.addingTimeInterval(seconds)
        )
    }

    @Test("age reads from askedAt and is phrased as elapsed time")
    func ageReadsAskedAt() {
        let text = MessageInboxLogic.age(of: pending(expiresIn: 80_000), now: Self.now)
        #expect(text.hasPrefix("asked "))
        #expect(text.contains("hour"), "an hour-old question says hours: \(text)")
        #expect(text.contains("ago"))
    }

    @Test("expiry counts DOWN, and only for pending questions")
    func expiryPendingOnly() {
        let text = MessageInboxLogic.expiry(of: pending(expiresIn: 80_000), now: Self.now)
        #expect(text?.hasPrefix("expires ") == true)
        #expect(text?.contains("hour") == true, "22 hours left reads in hours: \(text ?? "nil")")

        var answered = pending(expiresIn: 80_000)
        answered.status = .answered
        #expect(MessageInboxLogic.expiry(of: answered, now: Self.now) == nil,
                "no countdown on a question nobody is waiting on")
        var lapsed = pending(expiresIn: -10)
        lapsed.status = .expired
        #expect(MessageInboxLogic.expiry(of: lapsed, now: Self.now) == nil)
    }

    @Test("a pending question already past its TTL reads as expiring now, never as the past")
    func pastDuePending() {
        // The sweep is lazy (traffic-driven), so a pending row CAN sit past its
        // expiry for a moment. "expires 2 minutes ago" would be nonsense.
        #expect(MessageInboxLogic.expiry(of: pending(expiresIn: -120), now: Self.now)
                == "expiring now")
    }

    @Test("the amber urgency window is the last hour, and terminal rows are never urgent")
    func urgencyWindow() {
        #expect(MessageInboxLogic.isExpiringSoon(pending(expiresIn: 60 * 59), now: Self.now))
        #expect(!MessageInboxLogic.isExpiringSoon(pending(expiresIn: 60 * 61), now: Self.now))
        var answered = pending(expiresIn: 60)
        answered.status = .answered
        #expect(!MessageInboxLogic.isExpiringSoon(answered, now: Self.now))
    }
}

// MARK: - Close & nudge (the other two human moves)

@Suite("Inbox close and nudge")
@MainActor
struct MessagesCloseAndNudgeTests {

    @Test("close passes the human reason through the arbitration seam")
    func closePassesReason() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        let accepted = await model.close(Fix.message("MSG-001"), using: arbitrator)

        #expect(accepted)
        #expect(arbitrator.closes.count == 1)
        #expect(arbitrator.closes[0].messageID == "MSG-001")
        #expect(arbitrator.closes[0].reason == BusCloseReason.human)
    }

    @Test("closing the card being answered drops the open editor")
    func closeDropsEditor() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        model.beginAnswering("MSG-001")
        model.draft = "half-written"
        _ = await model.close(Fix.message("MSG-001"), using: arbitrator)
        #expect(model.answeringID == nil)
        #expect(model.draft.isEmpty)
    }

    @Test("a lost close race (already answered) reports failure and changes nothing")
    func closeRace() async {
        let model = MessagesInboxModel(debounce: .zero)
        let arbitrator = FakeArbitrator()
        arbitrator.failure = BusToolFailure.alreadyAnswered("MSG-001")
        let accepted = await model.close(Fix.message("MSG-001"), using: arbitrator)
        #expect(!accepted)
    }

    @Test("nudge writes a paste-ready snippet naming the tool, the asker and the id")
    func nudgeSnippet() {
        let model = MessagesInboxModel(debounce: .zero)
        var written: String?
        let message = Fix.message("MSG-001", subject: "Cursor pagination?")
        model.nudge(message, askingProjectName: "Alpha", write: { written = $0 })

        let snippet = try! #require(written)
        #expect(snippet.contains("check_messages"), "it must name the tool to call")
        #expect(snippet.contains("Alpha"), "it must say who is waiting")
        #expect(snippet.contains("MSG-001"), "it must carry the question id")
        #expect(model.nudgedID == "MSG-001", "the card shows its Copied confirmation")
    }

    @Test("only one card shows the Copied confirmation at a time")
    func nudgeIsSingular() {
        let model = MessagesInboxModel(debounce: .zero)
        model.nudge(Fix.message("MSG-001"), askingProjectName: "Alpha", write: { _ in })
        model.nudge(Fix.message("MSG-002"), askingProjectName: "Alpha", write: { _ in })
        #expect(model.nudgedID == "MSG-002")
    }
}

// MARK: - Arbitration flow through the store (badge + card source of truth)

@Suite("Messages arbitration flow (mock persistence)")
@MainActor
struct MessagesArbitrationFlowTests {

    @Test("human answer flips the card and drops the pending count via observation")
    func arbitrationFlip() async {
        let global = MockGlobalPersistence(
            projects: [],
            busMessages: [
                Fix.message("MSG-001"),
                Fix.message("MSG-002", status: .answered, answer: "Yes."),
            ]
        )
        let store = MessageStore(global: global)
        await store.activate()
        #expect(store.openCount(for: Fix.project) == 1)

        let arbitrator = MockBusArbitrator(global: global)
        let model = MessagesInboxModel(debounce: .zero)
        model.beginAnswering("MSG-001")
        model.draft = "Ship it as line art."
        let base = store.observationCountForTesting()
        let accepted = await model.submitAnswer(
            for: Fix.message("MSG-001"), using: arbitrator
        )
        #expect(accepted)

        // The observation stream delivers the flip (no optimistic mutation) —
        // await the actual applied delivery rather than polling a wall clock.
        await store.awaitObservationForTesting(reaching: base + 1)
        let updated = store.messages(in: Fix.project).first { $0.id == "MSG-001" }
        #expect(updated?.status == .answered)
        #expect(updated?.answer == "Ship it as line art.")
        #expect(updated?.answeredByHuman == true)
        #expect(store.openCount(for: Fix.project) == 0)  // Messages badge
    }

    @Test("an already-answered question is refused, not clobbered")
    func alreadyAnsweredUntouched() async {
        let global = MockGlobalPersistence(
            projects: [],
            busMessages: [Fix.message("MSG-002", status: .answered, answer: "Original.")]
        )
        let arbitrator = MockBusArbitrator(global: global)
        await #expect(throws: BusToolFailure.alreadyAnswered("MSG-002")) {
            try await arbitrator.answer(messageID: "MSG-002", text: "Clobber?", byHuman: true)
        }
        let messages = (try? await global.fetchBusMessages()) ?? []
        #expect(messages.first?.answer == "Original.")
        #expect(messages.first?.answeredByHuman == false)
    }

    @Test("the pending badge counts only INBOUND questions — one this project asked is somebody else's to answer")
    func badgeCountsInboundOnly() async {
        let global = MockGlobalPersistence(
            projects: [],
            busMessages: [
                Fix.message("MSG-001", from: Fix.alpha, to: Fix.project),
                Fix.message("MSG-002", from: Fix.project, to: Fix.alpha),
            ]
        )
        let store = MessageStore(global: global)
        await store.activate()
        #expect(store.openCount(for: Fix.project) == 1)
        #expect(store.messages(in: Fix.project).count == 2,
                "the inbox still SHOWS both directions")
    }

    @Test("the all-projects badge counts EVERY pending question, whoever asked whom")
    func globalBadgeCountsBothDirections() async {
        let global = MockGlobalPersistence(
            projects: [],
            busMessages: [
                Fix.message("MSG-001", from: Fix.alpha, to: Fix.project),
                Fix.message("MSG-002", from: Fix.project, to: Fix.alpha),
                Fix.message("MSG-003", status: .answered, answer: "Yes."),
            ]
        )
        let store = MessageStore(global: global)
        await store.activate()
        // The scoped badge sees one; the global badge sees both pending rows —
        // in the all-projects inbox the human is the fallback answerer for all.
        #expect(store.openCount(for: Fix.project) == 1)
        #expect(store.pendingCount == 2)
    }

    @Test("a human close flips the card to closed with the human reason, and drops the badge")
    func closeFlowThroughStore() async {
        let global = MockGlobalPersistence(
            projects: [], busMessages: [Fix.message("MSG-001")]
        )
        let store = MessageStore(global: global)
        await store.activate()
        #expect(store.openCount(for: Fix.project) == 1)

        let arbitrator = MockBusArbitrator(global: global)
        let model = MessagesInboxModel(debounce: .zero)
        let base = store.observationCountForTesting()
        #expect(await model.close(Fix.message("MSG-001"), using: arbitrator))

        await store.awaitObservationForTesting(reaching: base + 1)
        let updated = store.messages(in: Fix.project).first { $0.id == "MSG-001" }
        #expect(updated?.status == .closed)
        #expect(updated?.closedReason == BusCloseReason.human)
        #expect(updated?.answer == nil, "a close is not an answer")
        #expect(store.openCount(for: Fix.project) == 0)
    }

    @Test("closing an already-answered question is refused, not clobbered")
    func closeRefusesSettledRow() async {
        let global = MockGlobalPersistence(
            projects: [],
            busMessages: [Fix.message("MSG-002", status: .answered, answer: "Original.")]
        )
        let arbitrator = MockBusArbitrator(global: global)
        await #expect(throws: BusToolFailure.alreadyAnswered("MSG-002")) {
            try await arbitrator.close(messageID: "MSG-002", reason: BusCloseReason.human)
        }
        let messages = (try? await global.fetchBusMessages()) ?? []
        #expect(messages.first?.status == .answered)
        #expect(messages.first?.answer == "Original.")
    }
}

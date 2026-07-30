// MessagesInboxModel.swift
// UI state + pure predicate logic for the Messages inbox (design §6).
//
// Split per the view-discipline note:
// - MessageInboxLogic: nonisolated, value-only filter/sort/count core —
//   unit-tested without views or stores.
// - MessagesInboxModel: @Observable per-tab state (debounced search, status
//   pill, single-select agent chip, the inline-answer editor). Held as @State
//   by MessagesTabView; the card list resolves from the UNFILTERED store
//   source and this model only narrows what is shown.

import Foundation
import Observation

// MARK: - Filters (design §6 toolbar)

nonisolated enum MessageStatusFilter: String, CaseIterable, Identifiable, Sendable {
    case all = "All"
    case pending = "Pending"
    case answered = "Answered"
    case expired = "Expired"
    case closed = "Closed"

    var id: String { rawValue }
}

nonisolated struct MessageCounts: Equatable, Sendable {
    var all: Int
    var pending: Int
    var answered: Int
    var expired: Int
    var closed: Int
}

// MARK: - Pure core

nonisolated enum MessageInboxLogic {

    /// Newest question first. P3's correlation ids are random (they carry no
    /// sequence), so the ordering key is the durable `askedAt` stamp, with the
    /// id as a stable tiebreaker for same-instant rows.
    static func newestFirst(_ messages: [BusMessage]) -> [BusMessage] {
        messages.sorted { lhs, rhs in
            lhs.askedAt == rhs.askedAt ? lhs.id > rhs.id : lhs.askedAt > rhs.askedAt
        }
    }

    /// Status-pill counts: project-scoped, deliberately BEFORE search/agent
    /// narrowing (prototype behavior — the pills describe the inbox, not the
    /// current result set).
    static func counts(of messages: [BusMessage]) -> MessageCounts {
        MessageCounts(all: messages.count,
                      pending: messages.count { $0.status == .pending },
                      answered: messages.count { $0.status == .answered },
                      expired: messages.count { $0.status == .expired },
                      closed: messages.count { $0.status == .closed })
    }

    /// One message against the full filter set. `projectLabel` supplies the
    /// searchable identity for a participant project id — injected so the core
    /// stays store-free.
    static func matches(
        _ message: BusMessage,
        query: String,
        status: MessageStatusFilter,
        peerID: UUID?,
        projectLabel: (UUID) -> String
    ) -> Bool {
        switch status {
        case .all: break
        case .pending: guard message.status == .pending else { return false }
        case .answered: guard message.status == .answered else { return false }
        case .expired: guard message.status == .expired else { return false }
        case .closed: guard message.status == .closed else { return false }
        }
        if let peerID {
            guard message.from == peerID || message.to == peerID else { return false }
        }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return true }
        // Search over subject/body/answer/id/project names.
        let haystack = [
            message.subject, message.body, message.answer ?? "", message.id,
            projectLabel(message.from), projectLabel(message.to),
        ].joined(separator: " ")
        return haystack.range(of: trimmed, options: [.caseInsensitive]) != nil
    }

    static func apply(
        _ messages: [BusMessage],
        query: String,
        status: MessageStatusFilter,
        peerID: UUID?,
        projectLabel: (UUID) -> String
    ) -> [BusMessage] {
        newestFirst(messages).filter {
            matches($0, query: query, status: status, peerID: peerID,
                    projectLabel: projectLabel)
        }
    }

    // MARK: - Age & expiry (pending cards)

    /// A pending question is racing a clock, and the human is the fallback
    /// answerer — so the card states both halves: how long the asker has been
    /// waiting, and how long is left before the question lapses.
    ///
    /// Both are rendered in whole units ("2 hours", not "1h 58m"): a question's
    /// TTL is a day, so minute precision would be false precision.
    static func age(of message: BusMessage, now: Date) -> String {
        "asked " + relative(message.askedAt, to: now)
    }

    /// Under a minute either way reads as "just now". RelativeDateTimeFormatter
    /// says "in 0 seconds" there — which is both ungrammatical for a PAST event
    /// and, on a card that just flipped, actively confusing.
    static let justNowWindow: TimeInterval = 60

    /// Elapsed-time phrase for any bus timestamp — the one definition the age
    /// line, the countdown and the answer block all share.
    static func relative(_ date: Date, to now: Date) -> String {
        guard abs(date.timeIntervalSince(now)) >= justNowWindow else { return "just now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: now)
    }

    /// nil once the question is terminal — an expiry countdown on an answered
    /// or closed card is noise about a clock nobody is racing any more.
    static func expiry(of message: BusMessage, now: Date) -> String? {
        guard message.status == .pending else { return nil }
        guard message.expiresAt > now else { return "expiring now" }
        guard message.expiresAt.timeIntervalSince(now) >= justNowWindow else {
            return "expires in under a minute"
        }
        return "expires " + relative(message.expiresAt, to: now)
    }

    /// The last hour before a question lapses — the card tints its countdown so
    /// "you are about to lose this one" reads at a glance.
    static let expirySoonWindow: TimeInterval = 60 * 60

    static func isExpiringSoon(_ message: BusMessage, now: Date) -> Bool {
        message.status == .pending
            && message.expiresAt.timeIntervalSince(now) < expirySoonWindow
    }

    // MARK: - Compact-list expansion

    /// Effective expansion for one card. `globalOverride` is the base state set
    /// by the header expand/collapse-all toggle: nil = the default (collapsed —
    /// the whole point, the list stays tight); true = expand-all; false =
    /// collapse-all. `overrides` holds the ids the user has toggled AGAINST that
    /// base — a card in the set shows the opposite of the base. A new global
    /// command clears the set (model side), so the two never drift out of sync.
    static func isExpanded(
        globalOverride: Bool?, overrides: Set<String>, messageID: String
    ) -> Bool {
        let base = globalOverride ?? false
        return overrides.contains(messageID) ? !base : base
    }

    // MARK: - Windowed presentation

    /// Rows per page — the newest N shown first; "Load older" grows the window
    /// by another page (approved N=50). Applied AFTER search/status/agent
    /// narrowing so filters always operate on the full set and the window rides
    /// on top of the result (ruling: search/filters see everything, present a
    /// growing window).
    static let pageSize = 50

    /// The visible slice: the first `pageCount × pageSize` of an
    /// already-filtered, newest-first list. pageCount ≥ 1; the slice never
    /// exceeds the input count. A window at or beyond the count shows all.
    static func window(_ filtered: [BusMessage], pageCount: Int) -> [BusMessage] {
        let limit = max(1, pageCount) * pageSize
        return limit >= filtered.count ? filtered : Array(filtered.prefix(limit))
    }

    /// True when older rows remain past the current window (drives the
    /// "Load older" affordance).
    static func hasMore(filteredCount: Int, pageCount: Int) -> Bool {
        max(1, pageCount) * pageSize < filteredCount
    }
}

// MARK: - Tab state

@MainActor
@Observable
final class MessagesInboxModel {

    /// Raw field text (bound to the search field).
    private(set) var searchText = ""
    /// The APPLIED query — trails `searchText` by the debounce interval
    /// (~250ms per the hot-text-field convention).
    private(set) var query = ""

    var statusFilter: MessageStatusFilter = .all {
        didSet { if statusFilter != oldValue { resetWindow() } }
    }
    /// Single-select peer-project chip; matches questions that project asked
    /// OR was asked.
    var peerFilter: UUID? {
        didSet { if peerFilter != oldValue { resetWindow() } }
    }

    // MARK: Selection scoping

    /// The rail selection this model has already mirrored into `peerFilter`.
    /// Double-optional on purpose: `nil` means "no selection has been applied
    /// yet" (so the first pass applies even when the selection is nil), while
    /// `.some(nil)` means "the applied selection was: nothing".
    @ObservationIgnored private var appliedSelection: UUID??

    /// True once the human has touched the chip row themselves. Purely a record
    /// of the ruling below — the guard in `applySelectionScope` is what enforces
    /// it — but it is what a test (and a future "scoped to X" caption) reads.
    private(set) var isFilterUserOwned = false

    /// Mirrors the rail's selection into the project chip.
    ///
    /// PRECEDENCE RULING — the CHIP wins, until the selection changes again:
    /// selecting a project in the rail is a coarse "show me this project's
    /// world" and sets the chip as a DEFAULT; clicking a chip afterwards is a
    /// finer, later, more specific instruction, so it stands. The guard below is
    /// the whole mechanism: this only writes when the selection actually
    /// CHANGED, so a re-render (or a map click re-selecting what is already
    /// selected) never stomps a chip the human just set. Re-selecting the same
    /// project in the rail is likewise a no-op at the store level, so the only
    /// way to reclaim the filter is to select a DIFFERENT project — which is
    /// exactly the moment the old scope stopped being what the human meant.
    ///
    /// The reverse direction does not exist: nothing here writes back to the
    /// rail selection, so rail → chip is a one-way edge and there is no cycle.
    func applySelectionScope(_ projectID: UUID?) {
        guard appliedSelection != .some(projectID) else { return }
        appliedSelection = .some(projectID)
        isFilterUserOwned = false
        peerFilter = projectID
    }

    // MARK: Compact list — expansion (session-only, per-message)

    /// Header expand/collapse-all base. nil = default (collapsed — the list
    /// stays tight); true = expand-all; false = collapse-all. See
    /// MessageInboxLogic.isExpanded for how it composes with `overrides`.
    private(set) var globalExpansion: Bool?
    /// Cards toggled against the current base (opposite of it). Cleared whenever
    /// a new global command lands so base + set never drift.
    private(set) var expansionOverrides: Set<String> = []

    // MARK: Compact list — pagination (windowed presentation)

    /// How many pages of the FILTERED, newest-first result are visible. Filters
    /// always see the full set; this only bounds how much is rendered. Reset to
    /// 1 whenever the result set changes (filter/search/agent) so a narrowed
    /// list starts at the top page again.
    private(set) var visiblePageCount = 1

    /// The card whose inline answer editor is open (one at a time, prototype).
    private(set) var answeringID: String?
    var draft = ""
    private(set) var isSubmitting = false

    @ObservationIgnored private let debounce: Duration
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    /// - Parameter debounce: search debounce interval. `.zero` applies
    ///   synchronously (tests).
    init(debounce: Duration = .milliseconds(250)) {
        self.debounce = debounce
    }

    // MARK: Search & filters

    func setSearch(_ text: String) {
        searchText = text
        searchTask?.cancel()
        guard debounce > .zero else {
            setQuery(text)
            return
        }
        searchTask = Task { [debounce] in
            try? await Task.sleep(for: debounce)
            guard !Task.isCancelled else { return }
            self.setQuery(text)
        }
    }

    #if DEBUG
    /// Deterministically drains the in-flight debounce for tests (the
    /// DocumentsStore.awaitPendingScanForTesting precedent): under a full
    /// parallel suite the shared main actor can starve a 30ms timer past any
    /// polling deadline, so tests await the task instead of wall-clock racing.
    func awaitPendingSearchForTesting() async {
        await searchTask?.value
    }
    #endif

    /// Applies the query and resets the window — the result set changed, so the
    /// visible page returns to the newest page.
    private func setQuery(_ text: String) {
        guard query != text else { return }
        query = text
        resetWindow()
    }

    func togglePeerFilter(_ projectID: UUID) {
        peerFilter = peerFilter == projectID ? nil : projectID
        // The human now owns the chip (see applySelectionScope's ruling).
        isFilterUserOwned = true
    }

    /// The empty-search-state "clear filters" action (design §6). Clearing is a
    /// deliberate "show me everything" — so it beats the selection scope too,
    /// and the inbox stays unscoped until a DIFFERENT project is selected.
    func clearFilters() {
        searchTask?.cancel()
        searchText = ""
        query = ""
        statusFilter = .all
        peerFilter = nil
        isFilterUserOwned = true
        resetWindow()
    }

    // MARK: Compact list — expansion

    /// Effective expansion for one card (pure decision, testable in isolation).
    func isExpanded(_ messageID: String) -> Bool {
        MessageInboxLogic.isExpanded(
            globalOverride: globalExpansion, overrides: expansionOverrides,
            messageID: messageID
        )
    }

    /// Per-card chevron: flips this card against the current base.
    func toggleExpansion(_ messageID: String) {
        if expansionOverrides.contains(messageID) {
            expansionOverrides.remove(messageID)
        } else {
            expansionOverrides.insert(messageID)
        }
    }

    /// Header expand-all / collapse-all. Sets the base and clears per-card
    /// overrides so every card follows the command. Idempotent.
    func setGlobalExpansion(_ expanded: Bool) {
        globalExpansion = expanded
        expansionOverrides = []
    }

    /// Whether the header toggle currently reads "expanded" — true once an
    /// expand-all is in effect with no cards toggled back to collapsed.
    var allExpanded: Bool { globalExpansion == true && expansionOverrides.isEmpty }

    // MARK: Compact list — pagination

    /// "Load older": reveal the next page of the filtered result.
    func loadMore() { visiblePageCount += 1 }

    /// Return to the newest page — the result set changed underneath the window.
    private func resetWindow() { visiblePageCount = 1 }

    /// Grow the window so a card at `rank` (0-based, in the filtered newest-first
    /// list) is inside it — a chip→card route may target an OLD question below
    /// the current window (the scroll would land on nothing otherwise). No-op if
    /// already visible; also expands the card so the pulse lands on content.
    func focus(rank: Int, messageID: String) {
        if rank >= 0 {
            let needed = rank / MessageInboxLogic.pageSize + 1
            if needed > visiblePageCount { visiblePageCount = needed }
        }
        if !isExpanded(messageID) { expansionOverrides.insert(messageID) }
    }

    /// Chip→card focus support: if the routed-to message is hidden by the
    /// current filters, clear them so the card can be scrolled to; visible
    /// cards leave the filters untouched. Checks the PENDING search text too —
    /// a chip clicked inside the debounce window must not have the focused
    /// card yanked away when the trailing query lands.
    func revealIfHidden(_ message: BusMessage, projectLabel: (UUID) -> String) {
        let visibleNow = MessageInboxLogic.matches(
            message, query: query, status: statusFilter, peerID: peerFilter,
            projectLabel: projectLabel
        )
        let visibleAfterDebounce = MessageInboxLogic.matches(
            message, query: searchText, status: statusFilter, peerID: peerFilter,
            projectLabel: projectLabel
        )
        if !(visibleNow && visibleAfterDebounce) { clearFilters() }
    }

    // MARK: Inline answer (human arbitration)

    func beginAnswering(_ messageID: String) {
        answeringID = messageID
        draft = ""
    }

    func cancelAnswering() {
        answeringID = nil
        draft = ""
    }

    // MARK: - Close & nudge (the other two human moves)

    /// The card whose "Nudge" was just copied — drives the transient "Copied"
    /// confirmation. Session-only and self-clearing.
    private(set) var nudgedID: String?
    @ObservationIgnored private var nudgeResetTask: Task<Void, Never>?

    /// Copies the paste-into-that-session nudge. Dispatch CANNOT push into
    /// somebody else's terminal — there is no channel to it — so the honest
    /// affordance is a line the human pastes, not a button that pretends to
    /// poke. `write` is injected so the pasteboard stays out of the model.
    func nudge(_ message: BusMessage, askingProjectName: String?, write: (String) -> Void) {
        write(BusEventText.nudgeSnippet(for: message, askingProjectName: askingProjectName))
        nudgedID = message.id
        nudgeResetTask?.cancel()
        nudgeResetTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
            guard !Task.isCancelled else { return }
            self?.nudgedID = nil
        }
    }

    /// Closes a thread the human has decided is done — the third outcome
    /// besides "answered" and "lapsed". Like `submitAnswer`, no optimistic
    /// mutation: the card flips when the store's observation stream delivers
    /// the closed row. Returns false when the question already settled.
    @discardableResult
    func close(_ message: BusMessage, using arbitrator: any BusArbitrating) async -> Bool {
        guard !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await arbitrator.close(messageID: message.id, reason: BusCloseReason.human)
            if answeringID == message.id { cancelAnswering() }
            return true
        } catch {
            return false
        }
    }

    /// Records the human's answer through the arbitration seam. No optimistic
    /// mutation — the card flips when the store's observation stream delivers
    /// the answered row. Returns false (editor open, draft intact) on empty
    /// input or failure; losing the race to an agent's answer surfaces as the
    /// card flipping on its own (the view then closes the editor).
    @discardableResult
    func submitAnswer(for message: BusMessage, using arbitrator: any BusArbitrating) async -> Bool {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return false }
        isSubmitting = true
        defer { isSubmitting = false }
        do {
            try await arbitrator.answer(messageID: message.id, text: text, byHuman: true)
            cancelAnswering()
            return true
        } catch {
            return false
        }
    }
}

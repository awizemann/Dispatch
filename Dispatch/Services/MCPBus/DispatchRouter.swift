// DispatchRouter.swift
// The bus core: four verbs between PROJECTS.
//
// Dispatch never spawns an agent. Each linked repo's own Claude Code session
// connects over the `dispatch` entry in that repo's .mcp.json, and the token in
// that URL IS the caller's identity — one endpoint identity per project. This
// router is what those endpoints call: it mints correlation-ID question rows,
// routes them over `projectLink` (fail closed — an unlinked or unresolvable
// peer is never reachable), tracks which projects are live, fulfills long-polls
// when an answer lands while the asker is still waiting, marks delivery, and
// lapses questions nobody answered.
//
// Deliberately small and @MainActor: it holds only in-memory liveness and the
// long-poll waiters. Every durable decision — mint, answer, expire — is one
// atomic GlobalDatabase transaction, so two concurrent answers (or an answer
// racing the expiry sweep) are serialized by the database, not by this class.

import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "bus")

/// What `ask_agent` resolved to.
nonisolated enum AskOutcome: Sendable, Equatable {
    /// The target answered while the caller was still waiting.
    case answered(BusMessage)
    /// The question is durable and waiting for the target to pick it up.
    case pending(BusMessage)
}

/// One peer as `list_projects` sees it.
nonisolated struct BusPeerStatus: Sendable, Equatable {
    let projectID: UUID
    let name: String
    let connected: Bool
    let lastSeenAt: Date?
    /// Open questions this peer has addressed to the CALLER.
    let openQuestionsForCaller: Int
}

/// Something the bus DID — the vocabulary the activity ticker and the system
/// notifications both speak. Emitted by the router as each fact becomes true;
/// the composition root is the only subscriber (it fans out to the stores).
nonisolated enum BusEvent: Sendable, Equatable {
    /// A question was minted (`from` asked `to`).
    case asked(BusMessage)
    /// A question was answered — by the addressed project's session, or by the
    /// human through the Messages tab (`message.answeredByHuman`).
    case answered(BusMessage)
    /// A question closed without an answer (TTL lapse, unlink, human close).
    case closed(BusMessage)
    /// A project's endpoint went live (first traffic, or traffic after the
    /// liveness window elapsed).
    case connected(projectID: UUID)
    /// A project's endpoint stopped resolving (token rotated, project deleted).
    case disconnected(projectID: UUID)

    /// The projects this event concerns — every one of them shows it in its
    /// ticker (a question is as much news to the asker as to the asked).
    var projectIDs: [UUID] {
        switch self {
        case .asked(let m), .answered(let m), .closed(let m): [m.from, m.to]
        case .connected(let id), .disconnected(let id): [id]
        }
    }
}

/// What `check_messages` hands back.
nonisolated struct BusInbox: Sendable, Equatable {
    /// Questions addressed to the caller and still awaiting an answer.
    let openQuestions: [BusMessage]
    /// Terminal outcomes of the caller's OWN questions it has not seen yet —
    /// answers and expiries alike. Reported exactly once.
    let outcomes: [BusMessage]
}

@MainActor
@Observable
final class DispatchRouter {

    /// Hard ceiling on a long poll. The CLI's own tool timeout sits above this
    /// (600s); staying under it means the caller gets a truthful `pending`
    /// result instead of a killed tool call.
    nonisolated static let maxWaitSeconds = 540

    /// How long an unanswered question stays askable before it lapses. Long
    /// enough that a peer whose session is offline overnight still sees the
    /// question in the morning; short enough that a dead question does not sit
    /// in an inbox forever pretending to be live.
    nonisolated static let questionTTL: TimeInterval = 24 * 60 * 60

    /// A project counts as CONNECTED when its endpoint has been used inside
    /// this window. There is no socket to watch — the transport is stateless
    /// HTTP — so recency of real traffic is the only honest liveness signal,
    /// and it is what decides whether `ask_agent` bothers to long-poll.
    nonisolated static let liveWindow: TimeInterval = 15 * 60

    /// NONISOLATED on purpose: `GlobalDatabase` is an actor and owns its own
    /// serialization, and the `/pending` probe (below) must be answerable
    /// WITHOUT the main actor. A probe that queued behind the UI would be
    /// starved by a busy main thread into its two-second ceiling, and a hook
    /// that times out is a nudge that silently never happens.
    @ObservationIgnored private nonisolated let global: GlobalDatabase

    /// Per-project liveness, rebuilt from traffic (a relaunch starts empty —
    /// no false recency).
    private(set) var sessions: [UUID: BusSessionState] = [:]

    /// Long-poll waiters, keyed by question id then by waiter id. A question
    /// can have at most one waiter in practice (its asker); the inner map keeps
    /// that an invariant of the data rather than an assumption.
    @ObservationIgnored private var waiters: [String: [UUID: AnswerWaiter]] = [:]

    /// Set by the composition root so the router can name projects and check
    /// links without reaching into a store.
    @ObservationIgnored private var projectNames: [UUID: String] = [:]

    /// The composition root's subscription to what the bus did (activity ticker
    /// + system notifications). Deliberately ONE closure, not a broadcast: the
    /// router must not grow a subscriber registry, and AppStores is the only
    /// thing that knows where an event should land.
    @ObservationIgnored var onEvent: ((BusEvent) -> Void)?

    private func emit(_ event: BusEvent) { onEvent?(event) }

    nonisolated struct BusSessionState: Sendable, Equatable {
        var connectedAt: Date
        var lastSeenAt: Date
    }

    init(global: GlobalDatabase) {
        self.global = global
    }

    // MARK: - Liveness

    /// Records that `projectID`'s endpoint just did something. Called on every
    /// authenticated request (including initialize/tools-list — reaching the
    /// endpoint at all required the token from the repo's .mcp.json), so
    /// "connected" means real traffic, never a guess.
    func noteActivity(projectID: UUID, now: Date = Date()) {
        if var existing = sessions[projectID], now.timeIntervalSince(existing.lastSeenAt) < Self.liveWindow {
            existing.lastSeenAt = now
            sessions[projectID] = existing
        } else {
            // Either the first traffic ever, or traffic after the liveness
            // window elapsed — both are a project coming (back) online, and
            // both are worth one ticker line. Refreshing an already-live
            // session emits nothing (it is not news).
            sessions[projectID] = BusSessionState(connectedAt: now, lastSeenAt: now)
            emit(.connected(projectID: projectID))
        }
    }

    /// Drops a project's liveness (its token was rotated or the project was
    /// unlinked/deleted).
    func forgetSession(projectID: UUID) {
        guard sessions.removeValue(forKey: projectID) != nil else { return }
        emit(.disconnected(projectID: projectID))
    }

    func isConnected(_ projectID: UUID, now: Date = Date()) -> Bool {
        guard let state = sessions[projectID] else { return false }
        return now.timeIntervalSince(state.lastSeenAt) < Self.liveWindow
    }

    func lastSeen(_ projectID: UUID) -> Date? { sessions[projectID]?.lastSeenAt }

    /// Refreshes the id → name map the router resolves peers against. Called by
    /// the composition root whenever the project registry changes.
    func setProjectNames(_ names: [UUID: String]) {
        projectNames = names
    }

    func projectName(_ projectID: UUID) -> String? { projectNames[projectID] }

    // MARK: - ask_agent

    /// Mints a question from `callerProjectID` to the named peer.
    ///
    /// Fails CLOSED at every step: an unresolvable name, a name that resolves
    /// to a project with no link to the caller, and the caller itself are all
    /// refused before anything is written. `waitSeconds` only long-polls when
    /// the target is actually connected — waiting on a project that is not
    /// there would burn the caller's tool budget to reach the same `pending`.
    func ask(
        callerProjectID: UUID,
        targetProject: String,
        question: String,
        waitSeconds: Int?,
        now: Date = Date()
    ) async throws -> AskOutcome {
        noteActivity(projectID: callerProjectID, now: now)
        await sweepExpired(now: now)

        let text = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw BusToolFailure.emptyText("question") }

        let targetID = try await resolvePeer(of: callerProjectID, named: targetProject)

        let message = BusMessage(
            id: BusMessage.mintID(),
            from: callerProjectID,
            to: targetID,
            subject: BusMessage.derivedSubject(from: text),
            body: BusTextSanitizer.sanitize(text, maxLength: BusTextSanitizer.maxBodyLength),
            askedAt: now,
            expiresAt: now.addingTimeInterval(Self.questionTTL)
        )
        try await global.saveBusMessage(message)
        logger.info("bus question \(message.id, privacy: .public) minted")
        emit(.asked(message))

        let wait = min(max(waitSeconds ?? 0, 0), Self.maxWaitSeconds)
        guard wait > 0, isConnected(targetID, now: now) else {
            return .pending(message)
        }
        await waitForAnswer(questionID: message.id, seconds: wait)
        // Re-read rather than trusting the wake-up: the row is the truth, and
        // it may have expired or been answered by the human instead.
        let settled = (try? await global.fetchBusMessage(id: message.id)) ?? message
        if settled.status == .answered {
            // The asker is holding THIS answer in hand — mark exactly this row
            // seen so a later check_messages does not repeat it. Scoped to the
            // one id: claiming the caller's whole unseen set here would swallow
            // answers to its other questions.
            try? await global.markBusOutcomeSeen(id: settled.id, at: Date())
            return .answered(settled)
        }
        return .pending(settled)
    }

    // MARK: - answer_agent

    /// Records `callerProjectID`'s answer to a question addressed to it and
    /// wakes any long-poll waiting on it.
    ///
    /// The status guard is inside the database transaction, so concurrent
    /// answers cannot both win: exactly one caller sees the row flip and every
    /// other gets a truthful conflict failure.
    @discardableResult
    func answer(
        callerProjectID: UUID?,
        questionID: String,
        answer text: String,
        byHuman: Bool = false,
        now: Date = Date()
    ) async throws -> BusMessage {
        if let callerProjectID { noteActivity(projectID: callerProjectID, now: now) }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw BusToolFailure.emptyText("answer") }

        let outcome = try await global.recordBusAnswer(
            id: questionID,
            answeringProjectID: callerProjectID,
            answer: BusTextSanitizer.sanitize(trimmed, maxLength: BusTextSanitizer.maxBodyLength),
            byHuman: byHuman,
            now: now
        )
        switch outcome {
        case .answered(let message):
            fulfillWaiters(questionID: message.id)
            logger.info("bus question \(message.id, privacy: .public) answered")
            emit(.answered(message))
            return message
        case .notFound:
            throw BusToolFailure.unknownMessage(questionID)
        case .alreadyAnswered:
            throw BusToolFailure.alreadyAnswered(questionID)
        case .expired(let reason):
            throw BusToolFailure.expired(questionID, reason: reason)
        case .notAddressee:
            throw BusToolFailure.notAddressee(questionID)
        }
    }

    // MARK: - check_messages

    /// The caller's inbox: questions addressed to it, plus the outcomes of its
    /// own questions it has not seen. Reading MARKS both sides — the questions
    /// as delivered, the outcomes as seen — so nothing is reported twice.
    func checkMessages(callerProjectID: UUID, now: Date = Date()) async throws -> BusInbox {
        noteActivity(projectID: callerProjectID, now: now)
        await sweepExpired(now: now)

        let open = try await global.pendingBusMessages(to: callerProjectID)
        for message in open where message.deliveredAt == nil {
            try? await global.markBusMessageDelivered(id: message.id, at: now)
        }
        let outcomes = try await global.claimUnseenBusOutcomes(for: callerProjectID, now: now)
        return BusInbox(openQuestions: open, outcomes: outcomes)
    }

    // MARK: - Pending probe (the session hooks' /pending endpoint)

    /// How many questions are waiting for `projectID` — the ONLY thing the
    /// `/bus/<token>/pending` probe reports.
    ///
    /// DELIBERATELY NOT LIVENESS. Every other path into this router calls
    /// `noteActivity` because reaching it required a real session's tool call.
    /// This one is polled by a SHELL HOOK on a timer the human never sees, so
    /// counting it would let a repo with no session at all look permanently
    /// connected — and `ask_agent` decides whether to long-poll on exactly that
    /// signal. A probe is a question about state, not evidence of presence.
    ///
    /// It also does NOT sweep expired questions (a hook must not drive durable
    /// state); the `expiresAt` guard in the query is what keeps a lapsed
    /// question out of the count until the real sweep flips it.
    /// Answered OFF the main actor (see `global`): the count is one indexed
    /// database read and needs no in-memory router state at all.
    nonisolated func pendingCount(for projectID: UUID, now: Date = Date()) async -> Int {
        do {
            // Inbound open questions PLUS unseen outcomes of this project's own
            // questions: an arrived answer is as nudge-worthy as a new question
            // (dogfood 2026-07-29: the asker's session never learned its answer
            // had landed). Counting an outcome does not claim it — only a real
            // check_messages marks it seen.
            let questions = try await global.openBusMessageCount(to: projectID, now: now)
            let outcomes = try await global.unseenBusOutcomeCount(for: projectID)
            return questions + outcomes
        } catch {
            // Fail CLOSED to zero: the hook stays silent rather than nudging a
            // session about questions we could not count.
            logger.error("pending probe count failed: \(String(describing: error), privacy: .public)")
            return 0
        }
    }

    // MARK: - list_projects

    /// The caller's linked peers. A link whose peer is no longer a registered
    /// project is DROPPED rather than surfaced as a half-resolved row — the
    /// same fail-closed posture `ask` takes.
    func listProjects(callerProjectID: UUID, now: Date = Date()) async throws -> [BusPeerStatus] {
        noteActivity(projectID: callerProjectID, now: now)
        let links = try await global.fetchProjectLinks(involving: callerProjectID)
        let inbound = try await global.pendingBusMessages(to: callerProjectID)
        return links
            .compactMap { $0.peer(of: callerProjectID) }
            .compactMap { peerID -> BusPeerStatus? in
                guard let name = projectNames[peerID] else { return nil }
                return BusPeerStatus(
                    projectID: peerID,
                    name: name,
                    connected: isConnected(peerID, now: now),
                    lastSeenAt: lastSeen(peerID),
                    openQuestionsForCaller: inbound.count { $0.from == peerID }
                )
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Peer resolution (fail closed)

    /// Resolves a caller-supplied project name (or id string) to a LINKED peer.
    /// Every failure mode is distinct so the tool result can say what to fix.
    func resolvePeer(of callerProjectID: UUID, named target: String) async throws -> UUID {
        let needle = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { throw BusToolFailure.emptyText("project") }

        let links = try await global.fetchProjectLinks(involving: callerProjectID)
        let peerIDs = Set(links.compactMap { $0.peer(of: callerProjectID) })

        // An id is accepted so a caller can echo back exactly what
        // list_projects gave it; a name match is case-insensitive.
        let matches = peerIDs.filter { peerID in
            if let uuid = UUID(uuidString: needle), uuid == peerID { return true }
            guard let name = projectNames[peerID] else { return false }
            return name.compare(needle, options: .caseInsensitive) == .orderedSame
        }
        if let only = matches.first, matches.count == 1 { return only }
        if matches.count > 1 { throw BusToolFailure.ambiguousProject(needle) }

        // Distinguish "not linked" from "no such project" — one is a request to
        // the human, the other is a typo.
        if projectNames.contains(where: { $0.value.compare(needle, options: .caseInsensitive) == .orderedSame })
            || UUID(uuidString: needle).map({ projectNames.keys.contains($0) }) == true {
            throw BusToolFailure.notLinked(needle)
        }
        throw BusToolFailure.unknownProject(needle)
    }

    // MARK: - Expiry

    /// How often the background sweep runs. The HUMAN is an observer of a
    /// question's state too — the inbox countdown, the badge, the ticker — so a
    /// purely traffic-driven sweep left a lapsed question rendering "expiring
    /// now" forever on a quiet bus.
    nonisolated static let sweepInterval: Duration = .seconds(60)

    @ObservationIgnored private var sweepTask: Task<Void, Never>?

    /// Starts (or restarts) the periodic sweep. Idempotent-by-replacement, and
    /// cheap: the sweep is one guarded UPDATE that touches nothing when no
    /// question has lapsed.
    func startExpirySweep(interval: Duration = DispatchRouter.sweepInterval) {
        sweepTask?.cancel()
        sweepTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                // A router that has gone away ends the loop — a weak capture
                // that only skips the work would spin for the app's lifetime.
                guard let self else { return }
                await self.sweepExpired()
            }
        }
    }

    func stopExpirySweep() {
        sweepTask?.cancel()
        sweepTask = nil
    }

    /// Lapses every question past its TTL. Driven BOTH by traffic (on the way
    /// into a tool call, so a caller never reads a stale row) and by the
    /// periodic `startExpirySweep` timer (so a quiet bus still flips them). The
    /// UPDATE guards on `status = 'pending'`, so a question answered in the same
    /// instant wins and is never overwritten.
    @discardableResult
    func sweepExpired(now: Date = Date()) async -> [BusMessage] {
        let lapsed = (try? await global.expireLapsedBusMessages(now: now)) ?? []
        // Wake anyone long-polling on a question that just lapsed: they must
        // learn the truth now, not at their wait ceiling.
        for message in lapsed {
            fulfillWaiters(questionID: message.id)
            emit(.closed(message))
        }
        if !lapsed.isEmpty {
            logger.info("bus expired \(lapsed.count, privacy: .public) unanswered question(s)")
        }
        return lapsed
    }

    // MARK: - Long-poll waiters

    /// Suspends until `questionID` is answered (or lapses), or `seconds` pass.
    /// Every wake path goes through `AnswerWaiter`, which resumes at most once,
    /// so an answer landing in the same instant as the timeout cannot
    /// double-resume the continuation.
    private func waitForAnswer(questionID: String, seconds: Int) async {
        let waiterID = UUID()
        let waiter = AnswerWaiter()
        waiters[questionID, default: [:]][waiterID] = waiter

        let timeout = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            await self?.releaseWaiter(questionID: questionID, waiterID: waiterID)
        }
        await withCheckedContinuation { continuation in
            waiter.attach(continuation)
        }
        timeout.cancel()
        waiters[questionID]?.removeValue(forKey: waiterID)
        if waiters[questionID]?.isEmpty == true { waiters.removeValue(forKey: questionID) }
    }

    private func releaseWaiter(questionID: String, waiterID: UUID) {
        waiters[questionID]?[waiterID]?.resume()
    }

    private func fulfillWaiters(questionID: String) {
        guard let pending = waiters[questionID] else { return }
        for waiter in pending.values { waiter.resume() }
    }

    /// One long poll's resumption box. MainActor-isolated, so `done` needs no
    /// lock; `attach` handles the ordering hazard where the wake-up beats the
    /// continuation into place (a zero-length wait, or an answer that lands
    /// between installing the waiter and suspending).
    @MainActor
    private final class AnswerWaiter {
        private var continuation: CheckedContinuation<Void, Never>?
        private var done = false

        func attach(_ continuation: CheckedContinuation<Void, Never>) {
            if done {
                continuation.resume()
            } else {
                self.continuation = continuation
            }
        }

        func resume() {
            guard !done else { return }
            done = true
            continuation?.resume()
            continuation = nil
        }
    }
}

// MARK: - Human arbitration

extension DispatchRouter: BusArbitrating {
    /// The Messages tab's write path (guardrail: any open question can always be
    /// answered by the human). `callerProjectID: nil` bypasses the addressee
    /// check — the human answers on any project's behalf — and every other
    /// guard (pending-only, atomic, waiter wake-up) is the agent path's.
    func answer(messageID: String, text: String, byHuman: Bool) async throws {
        _ = try await answer(
            callerProjectID: nil, questionID: messageID, answer: text, byHuman: byHuman
        )
    }

    /// Closes a thread the human has decided is done. The asking session learns
    /// the outcome on its next `check_messages` — the same path an expiry takes,
    /// which is why this reuses the terminal `closed` status rather than
    /// inventing a third ending. A question that settled first is refused
    /// (never overwritten), and any long poll on it is woken with the truth.
    /// Closes every still-pending question a project is on either end of, and
    /// WAKES anything long-polling on them. Called by the deletion path before
    /// the rows are deleted: without it a parked `ask_agent` would sit on its
    /// full wait window and then report `pending` for a question whose row is
    /// gone — a lie, and up to ten minutes of a session doing nothing.
    func closeAllPending(involving projectID: UUID, reason: String) async {
        let closed: [BusMessage]
        do {
            closed = try await global.closePendingBusMessages(
                involving: projectID, reason: reason)
        } catch {
            logger.error("closePendingBusMessages(involving:) failed: \(String(describing: error), privacy: .public)")
            return
        }
        for message in closed {
            fulfillWaiters(questionID: message.id)
            emit(.closed(message))
        }
    }

    /// The unlink twin of `closeAllPending(involving:)`: closes every pending
    /// question BETWEEN two projects and wakes anything long-polling on one.
    func closeAllPending(between first: UUID, and second: UUID, reason: String) async {
        let closed: [BusMessage]
        do {
            closed = try await global.closePendingBusMessages(
                between: first, and: second, reason: reason)
        } catch {
            logger.error("closePendingBusMessages(between:and:) failed: \(String(describing: error), privacy: .public)")
            return
        }
        for message in closed {
            fulfillWaiters(questionID: message.id)
            emit(.closed(message))
        }
    }

    func close(messageID: String, reason: String) async throws {
        guard let closed = try await global.closeBusMessage(id: messageID, reason: reason) else {
            // Nothing flipped: either there is no such row, or it already
            // settled. Re-read to say WHICH, so the inbox can explain itself.
            guard let existing = try await global.fetchBusMessage(id: messageID) else {
                throw BusToolFailure.unknownMessage(messageID)
            }
            throw existing.status == .answered
                ? BusToolFailure.alreadyAnswered(messageID)
                : BusToolFailure.expired(messageID, reason: existing.closedReason)
        }
        fulfillWaiters(questionID: closed.id)
        logger.info("bus question \(closed.id, privacy: .public) closed by the human")
        emit(.closed(closed))
    }
}

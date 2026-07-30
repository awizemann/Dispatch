// MessageStore.swift
// The live mirror of the bus inbox.
//
// P3 moved this off the per-project sources: a Dispatch message belongs to a
// PAIR of projects (every bus caller IS a project), so there is ONE global
// table and ONE observation behind it. `messages(in:)` narrows that set to the
// project the UI is looking at — both directions, because a project's inbox is
// as much what it asked as what it was asked.

import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "messages")

@MainActor
@Observable
final class MessageStore {

    /// The global read seam. nil in a fixture-only composition (previews and
    /// store tests that seed `messages` directly).
    @ObservationIgnored private let global: (any GlobalPersistenceReading)?
    @ObservationIgnored private var observation: Task<Void, Never>?
    private var activated = false

    /// Every message, newest first (the reader's order).
    private(set) var messages: [BusMessage] = []

    #if DEBUG
    /// Test drain seam. Monotonic count of observation deliveries
    /// APPLIED, plus threshold waiters. The observation stream delivers
    /// asynchronously; a wall-clock `eventually { … }` poll racing that delivery
    /// can starve past ANY deadline under the full suite's saturated shared
    /// MainActor. Tests await the ACTUAL applied delivery instead of polling.
    @ObservationIgnored private var observationAppliedCount = 0
    @ObservationIgnored private var observationWaiters:
        [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []

    /// The number of observation deliveries applied — tests snapshot this
    /// before a write, then await `reaching: base + <writes>`.
    func observationCountForTesting() -> Int { observationAppliedCount }

    /// Deterministically awaits the observation loop having applied deliveries
    /// up to `target` (replaces `eventually { … }`).
    func awaitObservationForTesting(reaching target: Int) async {
        if observationAppliedCount >= target { return }
        await withCheckedContinuation { cont in
            observationWaiters.append((target, cont))
        }
    }

    private func recordObservationAppliedForTesting() {
        observationAppliedCount += 1
        guard !observationWaiters.isEmpty else { return }
        var stillWaiting: [(threshold: Int, cont: CheckedContinuation<Void, Never>)] = []
        for waiter in observationWaiters {
            if observationAppliedCount >= waiter.threshold { waiter.cont.resume() }
            else { stillWaiting.append(waiter) }
        }
        observationWaiters = stillWaiting
    }

    /// Fixture seam for previews / store tests without a database.
    func setMessagesForTesting(_ messages: [BusMessage]) {
        self.messages = messages
    }
    #endif

    init(global: (any GlobalPersistenceReading)? = nil, messages: [BusMessage] = []) {
        self.global = global
        self.messages = messages
    }

    /// Every message this project is a party to — asked OR answered.
    func messages(in projectID: UUID) -> [BusMessage] {
        messages.filter { $0.from == projectID || $0.to == projectID }
    }

    /// Questions addressed TO this project and still awaiting an answer — the
    /// Messages badge and the project card's attention count. Deliberately
    /// inbound-only: a question this project ASKED is somebody else's to answer.
    func openCount(for projectID: UUID) -> Int {
        messages.count { $0.to == projectID && $0.status == .pending }
    }

    /// Every unanswered question, whoever asked whom — the all-projects inbox's
    /// badge. Not direction-scoped like `openCount(for:)`: in the global view
    /// the human is the fallback answerer for all of them, so every pending row
    /// is theirs to see.
    var pendingCount: Int {
        messages.count { $0.status == .pending }
    }

    func activate() async {
        guard !activated else { return }
        activated = true
        guard let global else { return }
        messages = await safeRead("fetchBusMessages", fallback: []) { try await global.fetchBusMessages() }
        observe()
    }

    private func observe() {
        guard let global else { return }
        observation?.cancel()
        observation = Task {
            let stream = await global.observeBusMessages()
            do {
                for try await updated in stream {
                    self.messages = updated
                    #if DEBUG
                    self.recordObservationAppliedForTesting()
                    #endif
                }
            } catch {
                if !(error is CancellationError) {
                    logger.warning("bus-messages observation stream ended: \(error)")
                }
            }
        }
    }
}

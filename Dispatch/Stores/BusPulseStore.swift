// BusPulseStore.swift
// The seam the bus map watches: a tiny ring buffer of the bus
// events that are worth ANIMATING, held on an @Observable store.
//
// WHY A STORE, NOT A CLOSURE INTO THE VIEW: `AppStores.handle(busEvent:)` is the
// single fan-out point, and the rule there is that a new reactive surface adds a
// LINE, not a subscription. A closure chain from the router into a SwiftUI view
// would also outlive the view, fire while the band is collapsed, and have
// nowhere honest to put the "which pulses are in flight right now" state. A
// ring-buffered @Observable gives property-level tracking: the map redraws, the
// rest of the workbench does not.
//
// NO TIMERS. A pulse decays on ONE self-terminating Task per pulse, armed when
// the pulse is recorded. Nothing repeats, nothing polls, and a collapsed band
// runs no animation at all — the view simply isn't in the tree.

import Foundation
import Observation

/// Which way a pulse travels, and why.
nonisolated enum BusPulseKind: Sendable, Equatable {
    /// A question was asked: the dot runs asker → asked.
    case asked
    /// An answer came back: the dot runs asked → asker (the return leg).
    case answered
}

/// One in-flight pulse along a line. `from`/`to` are already oriented for
/// TRAVEL, so the view never has to know which end asked.
nonisolated struct BusPulse: Identifiable, Equatable, Sendable {
    let id: UUID
    /// The question this pulse belongs to — the coalescing key.
    let messageID: String
    /// Where the dot starts.
    let from: UUID
    /// Where the dot lands.
    let to: UUID
    let kind: BusPulseKind
    let startedAt: Date
}

/// How a pulse should be shown. Reduce Motion gets a brief line HIGHLIGHT
/// instead of a travelling dot — the same fact, without the movement.
nonisolated enum BusPulseRendering: Sendable, Equatable {
    case travellingDot
    case lineHighlight
}

@MainActor
@Observable
final class BusPulseStore {

    /// Ring capacity. Small on purpose: the map shows what is happening NOW, and
    /// a burst of twenty simultaneous dots is noise, not information.
    static let capacity = 6
    /// How long a dot takes to cross its line.
    static let travel: TimeInterval = 1.1
    /// Grace after the travel before the pulse is dropped, so the dot is never
    /// yanked off screen mid-animation.
    static let decayGrace: TimeInterval = 0.35
    /// The same question repeating the same leg inside this window is ONE pulse.
    /// Guards the double-delivery case (a long poll returning as the observation
    /// stream also lands) from drawing two dots on one line.
    static let coalesceWindow: TimeInterval = 0.3

    /// Pulses currently in flight, oldest first.
    private(set) var pulses: [BusPulse] = []

    // MARK: - Pure model (unit-testable without a store)

    /// The pulse an event deserves, or nil. Only `.asked` / `.answered` move
    /// anything: a close/expiry is the ABSENCE of traffic, and connect events
    /// belong to the station's live dot, not to a line.
    static func pulse(for event: BusEvent, at now: Date, id: UUID = UUID()) -> BusPulse? {
        switch event {
        case .asked(let message):
            BusPulse(id: id, messageID: message.id, from: message.from, to: message.to,
                     kind: .asked, startedAt: now)
        case .answered(let message):
            // The return leg: the answer travels back from the asked project.
            BusPulse(id: id, messageID: message.id, from: message.to, to: message.from,
                     kind: .answered, startedAt: now)
        case .closed, .connected, .disconnected:
            nil
        }
    }

    /// The ring-buffer + coalescing step. Returns the buffer UNCHANGED when the
    /// pulse coalesces into one already in flight.
    static func appending(_ pulse: BusPulse, to existing: [BusPulse]) -> [BusPulse] {
        let coalesces = existing.contains { inFlight in
            inFlight.messageID == pulse.messageID
                && inFlight.kind == pulse.kind
                && pulse.startedAt.timeIntervalSince(inFlight.startedAt) < coalesceWindow
        }
        guard !coalesces else { return existing }
        var next = existing
        next.append(pulse)
        if next.count > capacity { next.removeFirst(next.count - capacity) }
        return next
    }

    /// Reduce Motion picks the highlight; everyone else gets the dot.
    static func rendering(reduceMotion: Bool) -> BusPulseRendering {
        reduceMotion ? .lineHighlight : .travellingDot
    }

    // MARK: - Recording

    /// Records an event, arming its one-shot decay. Returns the pulse actually
    /// added (nil when the event carries no motion, or coalesced away).
    @discardableResult
    func record(_ event: BusEvent, at now: Date = Date()) -> BusPulse? {
        guard let pulse = Self.pulse(for: event, at: now) else { return nil }
        pulses = Self.appending(pulse, to: pulses)
        // Coalesced: the buffer kept the older pulse, so there is nothing new to
        // decay and nothing new to draw.
        guard pulses.last?.id == pulse.id else { return nil }
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(Self.travel + Self.decayGrace))
            self?.pulses.removeAll { $0.id == pulse.id }
        }
        return pulse
    }

    /// Drops pulses whose endpoints are no longer registered projects — a
    /// question answered in the same breath its project was deleted must not
    /// leave a dot travelling to a station that no longer exists.
    func prune(knownProjectIDs: Set<UUID>) {
        pulses.removeAll {
            !knownProjectIDs.contains($0.from) || !knownProjectIDs.contains($0.to)
        }
    }
}

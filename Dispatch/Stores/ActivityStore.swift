// ActivityStore.swift
// The activity ticker's source: what the bus just did, per project.
//
// IN-MEMORY BY DESIGN. The bus's durable record is the message row itself; the
// ticker is a live "what just happened" strip, not a second history to keep in
// sync with the first. A relaunch starts quiet and repopulates from the next
// real traffic, which is the honest thing for a liveness surface to do.
//
// P5 removed the per-project persistence sources this store used to aggregate.
// They were vestigial: the live composition never attached one (the events they
// read belonged to the agent runtime demolished in P2), so the ticker silently
// showed nothing. Events now arrive from exactly one place — AppStores'
// bus-event fan-out.

import Foundation
import Observation

@MainActor
@Observable
final class ActivityStore {

    /// Feed depth kept per project. The ticker shows only the tail; the cap
    /// exists so a long-running session cannot grow this without bound.
    static let feedLimit = 200

    private(set) var eventsByProject: [UUID: [ActivityEvent]] = [:]

    init() {}

    func events(in projectID: UUID) -> [ActivityEvent] {
        eventsByProject[projectID] ?? []
    }

    func latest(for projectID: UUID) -> ActivityEvent? {
        events(in: projectID).max { $0.time < $1.time }
    }

    /// Records a bus event against every project it concerns — a question is as
    /// much news to the asker as to the asked.
    func record(_ event: BusEvent, at time: Date = Date(), name: (UUID) -> String?) {
        let entry = ActivityEvent(
            id: UUID(), time: time,
            text: BusEventText.tickerLine(for: event, name: name),
            category: .bus
        )
        for projectID in Set(event.projectIDs) {
            var events = eventsByProject[projectID] ?? []
            events.append(entry)
            if events.count > Self.feedLimit {
                events.removeFirst(events.count - Self.feedLimit)
            }
            eventsByProject[projectID] = events
        }
    }

    /// Records a plain line — a PROBLEM Dispatch itself hit (a link that didn't
    /// persist, a rotation that failed, a port that moved). Category `.other`:
    /// it is not something the bus did, and the ticker should not dress it up as
    /// traffic.
    func record(text: String, at time: Date = Date(), in projectIDs: [UUID]) {
        let entry = ActivityEvent(id: UUID(), time: time, text: text, category: .other)
        for projectID in Set(projectIDs) {
            var events = eventsByProject[projectID] ?? []
            events.append(entry)
            if events.count > Self.feedLimit {
                events.removeFirst(events.count - Self.feedLimit)
            }
            eventsByProject[projectID] = events
        }
    }

    /// Buckets event timestamps into `bucketCount` one-minute bars for the
    /// ticker's events-per-minute sparkline (the "activity heartbeat").
    /// Pure and clock-injected so it is directly testable.
    ///
    /// Buckets are trailing wall-clock minutes ending at `now`, OLDEST FIRST —
    /// index 0 covers (now − 10min, now − 9min], index 9 covers the minute
    /// ending at `now`. Timestamps outside the window (older than 10 minutes,
    /// or in the future) are dropped.
    nonisolated static func sparklineBuckets(
        times: [Date], now: Date, bucketCount: Int = 10
    ) -> [Int] {
        var buckets = [Int](repeating: 0, count: bucketCount)
        for time in times {
            let age = now.timeIntervalSince(time)   // seconds into the past
            guard age >= 0 else { continue }        // future stamps: drop
            let minutesAgo = Int(age / 60)          // 0 = the current minute
            guard minutesAgo < bucketCount else { continue }
            buckets[bucketCount - 1 - minutesAgo] += 1
        }
        return buckets
    }
}

// DomainModels.swift
// Dispatch — Sendable domain DTOs consumed by @MainActor stores and SwiftUI views.
// These are the ONLY types that cross the persistence boundary; GRDB record types
// live in Persistence/ and never leave the persistence actor.
//
// The whole domain is four types: a linked repo (Project), a link between two of
// them (ProjectLink), a cross-project question (BusMessage), and a ticker line
// (ActivityEvent). Nothing else has a reader anywhere in the product.
//
// Every type here is `nonisolated` (the project builds with
// SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor) and explicitly Sendable.

import Foundation

// MARK: - Core entities

nonisolated struct Project: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var repoPath: String          // chosen via NSOpenPanel folder picker only
    var pinned: Bool              // toggled via right-click menu
    var git: GitStatus?           // nil until the first live scan; cached for instant paint
    var lastOpenedAt: Date?
    /// OPT-IN, default off: whether Dispatch maintains its SessionStart /
    /// UserPromptSubmit nudge hooks in this repo's `.claude/settings.json`
    /// (RepoHooksConfig). Off means Dispatch never writes that file at all.
    var sessionHooksEnabled: Bool

    init(id: UUID, name: String, repoPath: String, pinned: Bool,
         git: GitStatus? = nil, lastOpenedAt: Date? = nil,
         sessionHooksEnabled: Bool = false) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.pinned = pinned
        self.git = git
        self.lastOpenedAt = lastOpenedAt
        self.sessionHooksEnabled = sessionHooksEnabled
    }
}

nonisolated struct GitStatus: Codable, Equatable, Sendable {
    var openPRs: Int
    var openTickets: Int
    var unpushedCommits: Int      // amber pill when > 0
    var branch: String
}

/// A cross-project link: an UNORDERED pair of
/// registered project ids that lets either one ask the other a question.
/// Lives in the GLOBAL DB, alongside the projects registry itself. The pair is
/// CANONICALIZED at construction
/// (`projectA.uuidString < projectB.uuidString`) so (X, Y) and (Y, X) mint the
/// identical row, and a UNIQUE(projectA, projectB) index rejects the reverse as
/// a duplicate — one link per unordered pair regardless of insert order. `id` is
/// the row identity; equality is over all fields (the pair + createdAt).
nonisolated struct ProjectLink: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let projectA: UUID            // canonical low end (uuidString-ordered)
    let projectB: UUID            // canonical high end
    var createdAt: Date

    /// Mints a link from an UNORDERED pair, canonicalizing the two ids so insert
    /// order can never produce two rows for the same pair. A self-pair
    /// (`first == second`) is meaningless; the store layer rejects it before save.
    init(id: UUID = UUID(), _ first: UUID, _ second: UUID, createdAt: Date = Date()) {
        self.id = id
        if first.uuidString <= second.uuidString {
            self.projectA = first
            self.projectB = second
        } else {
            self.projectA = second
            self.projectB = first
        }
        self.createdAt = createdAt
    }

    /// Row-faithful init (persistence decode + tests): sets the canonical ends
    /// verbatim, WITHOUT re-canonicalizing — a stored row is already canonical.
    init(id: UUID, projectA: UUID, projectB: UUID, createdAt: Date) {
        self.id = id
        self.projectA = projectA
        self.projectB = projectB
        self.createdAt = createdAt
    }

    /// True when this link connects the two given projects, in either order.
    func connects(_ x: UUID, _ y: UUID) -> Bool {
        (projectA == x && projectB == y) || (projectA == y && projectB == x)
    }

    /// The peer of `projectID` in this link, or nil when `projectID` isn't a member.
    func peer(of projectID: UUID) -> UUID? {
        if projectID == projectA { return projectB }
        if projectID == projectB { return projectA }
        return nil
    }
}


// MARK: - Activity

nonisolated struct ActivityEvent: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var time: Date
    var text: String
    var category: ActivityCategory
}

/// What an activity line is about. `bus` is the only category the switchboard
/// produces today (every ticker line comes from a bus event); `other` exists so
/// a future non-bus signal has somewhere honest to land.
nonisolated enum ActivityCategory: String, Codable, Sendable { case bus, other }



// MARK: - Bus questions (Dispatch P3 — the one global message model)

/// Status of a cross-project question row.
///
/// `pending`  — asked, not yet answered (the only answerable state).
/// `answered` — an answer is recorded (by the target project's agent, or by the
///              human through the Messages tab's arbitration seam).
/// `expired`  — the TTL lapsed with no answer. Terminal and honest: the bus
///              never fabricates an answer, and the asker re-asks.
/// `closed`   — closed without an answer for a non-TTL reason (e.g. a project
///              was unlinked or the human dismissed the thread). Terminal.
nonisolated enum BusStatus: String, Codable, Sendable, CaseIterable {
    case pending, answered, expired, closed

    var isTerminal: Bool { self != .pending }
}

/// ONE cross-project question/answer row — the whole message model of Dispatch.
///
/// Every bus caller IS a project (one endpoint identity per project), so a
/// message always has a distinct asking project and asked project; same-project
/// Q&A does not exist and is rejected at the tool layer. The row lives in the
/// GLOBAL database (it belongs to no single project) and its `id` is the
/// correlation ID handed back to `ask_agent` and quoted by `answer_agent`.
nonisolated struct BusMessage: Identifiable, Codable, Equatable, Sendable {
    /// Correlation ID — "q-" + 128 bits of hex. Opaque to agents.
    let id: String
    /// The project that asked.
    var from: UUID
    /// The project that was asked (the only one that may answer).
    var to: UUID
    /// One-line preview derived from the question (list/inbox surfaces).
    var subject: String
    /// The question text (sanitized at the write boundary).
    var body: String
    var status: BusStatus
    /// Sanitized at the write boundary; nil until answered.
    var answer: String?
    /// True when the human answered through the Messages tab, not an agent.
    var answeredByHuman: Bool
    var askedAt: Date
    var answeredAt: Date?
    /// Set the first time the question was handed to the target project (a
    /// `check_messages` read or a live long-poll delivery).
    var deliveredAt: Date?
    /// When a still-pending question lapses to `.expired`.
    var expiresAt: Date
    /// Why a terminal row closed without an answer — nil on pending/answered.
    var closedReason: String?

    init(
        id: String, from: UUID, to: UUID, subject: String, body: String,
        status: BusStatus = .pending, answer: String? = nil,
        answeredByHuman: Bool = false, askedAt: Date = Date(),
        answeredAt: Date? = nil, deliveredAt: Date? = nil,
        expiresAt: Date, closedReason: String? = nil
    ) {
        self.id = id
        self.from = from
        self.to = to
        self.subject = subject
        self.body = body
        self.status = status
        self.answer = answer
        self.answeredByHuman = answeredByHuman
        self.askedAt = askedAt
        self.answeredAt = answeredAt
        self.deliveredAt = deliveredAt
        self.expiresAt = expiresAt
        self.closedReason = closedReason
    }

    /// A fresh correlation ID: 128 bits of system randomness, hex-encoded.
    static func mintID() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = UInt64.random(in: .min ... .max, using: &generator)
        let low = UInt64.random(in: .min ... .max, using: &generator)
        return String(format: "q-%016llx%016llx", high, low)
    }

    /// The one-line subject shown in the inbox, derived from the question text.
    static func derivedSubject(from question: String) -> String {
        let firstLine = question
            .split(whereSeparator: \.isNewline)
            .first
            .map(String.init) ?? question
        return BusPromptFraming.displayShorten(
            firstLine.trimmingCharacters(in: .whitespaces), maxLength: 120
        )
    }
}

/// Result of the atomic answer transaction (GlobalDatabase.recordBusAnswer).
/// `.notAddressee` is the bus's non-spoofing invariant surfacing: a project may
/// only answer questions addressed to IT.
nonisolated enum BusAnswerOutcome: Equatable, Sendable {
    case answered(BusMessage)
    case notFound
    case alreadyAnswered
    /// The question lapsed (or was closed) before this answer arrived.
    case expired(reason: String?)
    case notAddressee
}

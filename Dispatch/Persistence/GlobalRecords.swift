// GlobalRecords.swift
// GRDB record types for the global database. Persistence-internal: records never
// leave the persistence actors — they map to/from the Sendable domain DTOs in
// Models/DomainModels.swift (see .memory/architecture/sendable-dto-boundary-architecture).
//
// ProjectLink is a flat value type whose row shape is identical to the DTO, so the
// DTO itself adopts the record protocols here (conformance lives in Persistence/,
// consumers still see a plain Sendable value).

import Foundation
import GRDB

// MARK: - project

nonisolated struct ProjectRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "project"

    var id: UUID
    var name: String
    var repoPath: String
    var repoBookmark: Data?
    var pinned: Bool
    var lastOpenedAt: Date?
    var cachedBranch: String?
    var cachedOpenPRs: Int?
    var cachedOpenTickets: Int?
    var cachedUnpushedCommits: Int?
    var sessionHooksEnabled: Bool

    init(project: Project, repoBookmark: Data? = nil) {
        self.id = project.id
        self.name = project.name
        self.repoPath = project.repoPath
        self.repoBookmark = repoBookmark
        self.pinned = project.pinned
        self.lastOpenedAt = project.lastOpenedAt
        self.cachedBranch = project.git?.branch
        self.cachedOpenPRs = project.git?.openPRs
        self.cachedOpenTickets = project.git?.openTickets
        self.cachedUnpushedCommits = project.git?.unpushedCommits
        self.sessionHooksEnabled = project.sessionHooksEnabled
    }

    var project: Project {
        let git: GitStatus?
        if let branch = cachedBranch,
           let prs = cachedOpenPRs,
           let tickets = cachedOpenTickets,
           let unpushed = cachedUnpushedCommits {
            git = GitStatus(openPRs: prs, openTickets: tickets,
                            unpushedCommits: unpushed, branch: branch)
        } else {
            git = nil
        }
        return Project(id: id, name: name, repoPath: repoPath,
                       pinned: pinned, git: git, lastOpenedAt: lastOpenedAt,
                       sessionHooksEnabled: sessionHooksEnabled)
    }
}

// MARK: - projectLink (flat: DTO == row)

// The stored row is already canonical (rows are written via the canonicalizing
// mint), so the synthesized Decodable init sets projectA/projectB VERBATIM — it
// must not re-order. A save with a new id but a duplicate unordered pair violates
// the UNIQUE(projectA, projectB) index and throws (the pair-uniqueness backstop).
nonisolated extension ProjectLink: FetchableRecord, PersistableRecord {
    static let databaseTableName = "projectLink"
}

// MARK: - projectBusToken (Dispatch P3 — one bus endpoint identity per project)

/// The durable per-project bus token. Flat row; the projectID primary key is
/// what makes re-registration a ROTATION (replace ⇒ the old token is gone).
/// Never logged, never framed into a prompt.
nonisolated struct ProjectBusTokenRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "projectBusToken"

    var projectID: UUID
    var token: String
    var createdAt: Date
}

// MARK: - busMessage (Dispatch P3 — the one global message table)

/// The persisted cross-project question row. `deliveredAt` / `answerSeenAt` are
/// deliberately ABSENT: they are raw-SQL-only delivery bookkeeping, so an
/// ordinary whole-record save can never clobber a live delivery mark (the
/// convention carried over from the per-project bus tables).
nonisolated struct BusMessageRecord: Codable, FetchableRecord, PersistableRecord, Equatable {
    static let databaseTableName = "busMessage"

    var id: String
    var fromProjectID: UUID
    var toProjectID: UUID
    var subject: String
    var body: String
    var status: String
    var answer: String?
    var answeredByHuman: Bool
    var askedAt: Date
    var answeredAt: Date?
    var expiresAt: Date
    var closedReason: String?

    init(message: BusMessage) {
        self.id = message.id
        self.fromProjectID = message.from
        self.toProjectID = message.to
        self.subject = message.subject
        self.body = message.body
        self.status = message.status.rawValue
        self.answer = message.answer
        self.answeredByHuman = message.answeredByHuman
        self.askedAt = message.askedAt
        self.answeredAt = message.answeredAt
        self.expiresAt = message.expiresAt
        self.closedReason = message.closedReason
    }

    /// Forward-tolerant: an unknown status TEXT (a newer binary's row) reads as
    /// `.closed` — terminal and inert — rather than failing the whole fetch.
    var message: BusMessage {
        BusMessage(
            id: id, from: fromProjectID, to: toProjectID, subject: subject,
            body: body, status: BusStatus(rawValue: status) ?? .closed,
            answer: answer, answeredByHuman: answeredByHuman, askedAt: askedAt,
            answeredAt: answeredAt, deliveredAt: nil, expiresAt: expiresAt,
            closedReason: closedReason
        )
    }
}

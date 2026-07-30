// GlobalDatabase.swift
// The persistence actor for the GLOBAL database — Dispatch's only database: the
// projects registry, the links between projects, one bus token per project, and
// the cross-project messages. The only place GRDB records are touched; everything
// that leaves this actor is a Sendable domain DTO.

import Foundation
import GRDB

nonisolated enum GlobalPersistenceError: Error, CustomStringConvertible, Equatable {
    /// A project cannot be linked to itself: a cross-project link is
    /// an UNORDERED pair of DISTINCT projects. Rejected at persist so a degenerate
    /// self-pair never occupies a valid (projectA == projectB) unique row.
    case selfLink
    var description: String {
        switch self {
        case .selfLink: "refusing to persist a project link from a project to itself"
        }
    }
}

actor GlobalDatabase: GlobalPersistenceReading {

    private let writer: any DatabaseWriter

    private init(writer: any DatabaseWriter) {
        self.writer = writer
    }

    // MARK: - Opening

    /// Shared pool configuration: WAL comes with DatabasePool; 5s busy timeout.
    nonisolated static func configuration() -> Configuration {
        var config = Configuration()
        config.busyMode = .timeout(5)
        #if DEBUG
        config.publicStatementArguments = true
        #endif
        return config
    }

    /// Opens (creating if needed) and migrates the global database.
    /// `nonisolated async` so the blocking pool open + migration run on the global
    /// executor, never on the main actor (cold-start rule) — callers just `await`.
    nonisolated static func open(at url: URL) async throws -> GlobalDatabase {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let pool = try DatabasePool(path: url.path, configuration: configuration())
        try GlobalSchema.makeMigrator().migrate(pool)
        return GlobalDatabase(writer: pool)
    }

    /// In-memory database for tests (DatabaseQueue: pools can't be in-memory).
    nonisolated static func openInMemory() async throws -> GlobalDatabase {
        let queue = try DatabaseQueue(configuration: configuration())
        try GlobalSchema.makeMigrator().migrate(queue)
        return GlobalDatabase(writer: queue)
    }

    // MARK: - Projects

    func saveProject(_ project: Project) async throws {
        try await writer.write { db in
            // Preserve an existing bookmark on update (bookmarks are set separately).
            let existing = try ProjectRecord.fetchOne(db, key: project.id)
            try ProjectRecord(project: project, repoBookmark: existing?.repoBookmark).save(db)
        }
    }

    func deleteProject(id: UUID) async throws {
        _ = try await writer.write { db in
            try ProjectRecord.deleteOne(db, key: id)
        }
    }

    func setPinned(projectID: UUID, pinned: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE project SET pinned = ? WHERE id = ?",
                arguments: [pinned, projectID]
            )
        }
    }

    /// The per-project session-hooks opt-in. A targeted UPDATE
    /// rather than a whole-record save: the toggle rides a live observation and
    /// must never carry a stale git cache back over the row.
    func setSessionHooksEnabled(projectID: UUID, enabled: Bool) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE project SET sessionHooksEnabled = ? WHERE id = ?",
                arguments: [enabled, projectID]
            )
        }
    }

    /// Selection persistence: the rail restores to max(lastOpenedAt) on launch.
    func updateLastOpenedAt(projectID: UUID, date: Date) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE project SET lastOpenedAt = ? WHERE id = ?",
                arguments: [date, projectID]
            )
        }
    }

    /// Overwrites the cached last-known git status for instant sidebar paint.
    func updateGitStatusCache(projectID: UUID, git: GitStatus) async throws {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE project
                    SET cachedBranch = ?, cachedOpenPRs = ?, cachedOpenTickets = ?,
                        cachedUnpushedCommits = ?
                    WHERE id = ?
                    """,
                arguments: [git.branch, git.openPRs, git.openTickets,
                            git.unpushedCommits, projectID]
            )
        }
    }

    func saveRepoBookmark(projectID: UUID, bookmark: Data) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE project SET repoBookmark = ? WHERE id = ?",
                arguments: [bookmark, projectID]
            )
        }
    }

    func repoBookmark(projectID: UUID) async throws -> Data? {
        try await writer.read { db in
            try ProjectRecord.fetchOne(db, key: projectID)?.repoBookmark
        }
    }

    func fetchProjects() async throws -> [Project] {
        try await writer.read { db in
            try Self.allProjects(db)
        }
    }

    func observeProjects() -> AsyncThrowingStream<[Project], Error> {
        observationStream(
            ValueObservation.tracking { try Self.allProjects($0) },
            in: writer
        )
    }

    nonisolated private static func allProjects(_ db: Database) throws -> [Project] {
        try ProjectRecord
            .order(Column("pinned").desc, Column("name").collating(.localizedCaseInsensitiveCompare))
            .fetchAll(db)
            .map(\.project)
    }

    // MARK: - Project links (cross-project linking)

    /// Persists a link. The ProjectLink mint canonicalizes the pair, so a duplicate
    /// UNORDERED pair (a new id over an already-linked pair) violates the
    /// UNIQUE(projectA, projectB) index and THROWS — the pair-uniqueness backstop
    /// regardless of insert order. Re-saving the SAME row (same id) is idempotent.
    func saveProjectLink(_ link: ProjectLink) async throws {
        guard link.projectA != link.projectB else { throw GlobalPersistenceError.selfLink }
        try await writer.write { db in try link.save(db) }
    }

    func deleteProjectLink(id: UUID) async throws {
        _ = try await writer.write { db in try ProjectLink.deleteOne(db, key: id) }
    }

    /// Removes the link between two projects, in EITHER order (the pair is
    /// canonicalized before the delete). No-op when the pair isn't linked.
    func deleteProjectLink(between first: UUID, and second: UUID) async throws {
        let probe = ProjectLink(first, second)
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM projectLink WHERE projectA = ? AND projectB = ?",
                arguments: [probe.projectA, probe.projectB]
            )
        }
    }

    /// Prunes EVERY link touching `projectID` on either end: when a project is
    /// deleted from Dispatch its links must go with it, or the registry keeps
    /// orphan pairs that resolve to a name that no longer exists. Called from
    /// the project-deletion path. No-op when the project had no links. Returns
    /// nothing; deletion is idempotent.
    func deleteProjectLinks(involving projectID: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM projectLink WHERE projectA = ? OR projectB = ?",
                arguments: [projectID, projectID]
            )
        }
    }

    func fetchProjectLinks() async throws -> [ProjectLink] {
        try await writer.read { db in try Self.allProjectLinks(db) }
    }

    /// Links that include `projectID` on either end — the caller's cross-project
    /// peers (Phase 2 router / discoverability read).
    func fetchProjectLinks(involving projectID: UUID) async throws -> [ProjectLink] {
        try await writer.read { db in
            try ProjectLink
                .filter(sql: "projectA = ? OR projectB = ?", arguments: [projectID, projectID])
                .order(Column("createdAt"))
                .fetchAll(db)
        }
    }

    func observeProjectLinks() -> AsyncThrowingStream<[ProjectLink], Error> {
        observationStream(
            ValueObservation.tracking { try Self.allProjectLinks($0) },
            in: writer
        )
    }

    nonisolated private static func allProjectLinks(_ db: Database) throws -> [ProjectLink] {
        try ProjectLink.order(Column("createdAt")).fetchAll(db)
    }

    // MARK: - Bus tokens (Dispatch P3 — one endpoint identity per project)

    /// Mints a FRESH token for `projectID` and returns it, replacing any
    /// existing row. Replacement IS revocation: the previous token no longer
    /// resolves, so a stale `.mcp.json` in the repo (or a leaked copy) goes
    /// dead the moment the project re-registers or the user rotates.
    @discardableResult
    func rotateBusToken(projectID: UUID, now: Date = Date()) async throws -> String {
        let token = Self.mintBusToken()
        try await writer.write { db in
            try ProjectBusTokenRecord(
                projectID: projectID, token: token, createdAt: now
            ).save(db)
        }
        return token
    }

    /// The project's current token, minting one on first use. Idempotent — the
    /// same token comes back on every later call, which is what makes the
    /// repo's `.mcp.json` entry durable across app restarts.
    func busToken(projectID: UUID, now: Date = Date()) async throws -> String {
        if let existing = try await writer.read({ db in
            try ProjectBusTokenRecord.fetchOne(db, key: projectID)
        }) {
            return existing.token
        }
        return try await rotateBusToken(projectID: projectID, now: now)
    }

    /// Every registered (projectID, token) pair — the listener's route table.
    func busTokens() async throws -> [(projectID: UUID, token: String)] {
        try await writer.read { db in
            try ProjectBusTokenRecord.fetchAll(db).map { ($0.projectID, $0.token) }
        }
    }

    /// Route resolution: token → project, or nil for an unknown/revoked token.
    func projectID(forBusToken token: String) async throws -> UUID? {
        try await writer.read { db in
            try ProjectBusTokenRecord
                .filter(Column("token") == token)
                .fetchOne(db)?
                .projectID
        }
    }

    func deleteBusToken(projectID: UUID) async throws {
        _ = try await writer.write { db in
            try ProjectBusTokenRecord.deleteOne(db, key: projectID)
        }
    }

    /// 128 bits of system randomness, hex-encoded (URL-path safe).
    nonisolated static func mintBusToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let high = UInt64.random(in: .min ... .max, using: &generator)
        let low = UInt64.random(in: .min ... .max, using: &generator)
        return String(format: "%016llx%016llx", high, low)
    }

    // MARK: - Bus messages (Dispatch P3 — the one global message table)

    func saveBusMessage(_ message: BusMessage) async throws {
        try await writer.write { db in
            try BusMessageRecord(message: message).insert(db)
        }
    }

    func fetchBusMessages() async throws -> [BusMessage] {
        try await writer.read { db in try Self.allBusMessages(db) }
    }

    func fetchBusMessage(id: String) async throws -> BusMessage? {
        try await writer.read { db in
            try BusMessageRecord.fetchOne(db, key: id)?.message
        }
    }

    func observeBusMessages() -> AsyncThrowingStream<[BusMessage], Error> {
        observationStream(
            ValueObservation.tracking { try Self.allBusMessages($0) },
            in: writer
        )
    }

    nonisolated private static func allBusMessages(_ db: Database) throws -> [BusMessage] {
        try BusMessageRecord
            .order(Column("askedAt").desc, Column("id").desc)
            .fetchAll(db)
            .map(\.message)
    }

    /// Records an answer ATOMICALLY — the single serialization point behind
    /// concurrent answers (two agents, or an agent racing the human's
    /// arbitration). The status guard is inside the write transaction, so
    /// exactly one caller sees `.answered` and every other gets
    /// `.alreadyAnswered`/`.expired`; no lost update is possible.
    ///
    /// `answeringProjectID` enforces the non-spoofing invariant: only the
    /// project a question was addressed TO may answer it. Pass nil for the
    /// human-arbitration path (the human answers on any project's behalf).
    func recordBusAnswer(
        id: String,
        answeringProjectID: UUID?,
        answer: String,
        byHuman: Bool,
        now: Date = Date()
    ) async throws -> BusAnswerOutcome {
        try await writer.write { db in
            guard let record = try BusMessageRecord.fetchOne(db, key: id) else {
                return .notFound
            }
            if let answeringProjectID, record.toProjectID != answeringProjectID {
                return .notAddressee
            }
            switch BusStatus(rawValue: record.status) ?? .closed {
            case .answered:
                return .alreadyAnswered
            case .expired, .closed:
                return .expired(reason: record.closedReason)
            case .pending:
                break
            }
            try db.execute(
                sql: """
                    UPDATE busMessage
                    SET status = ?, answer = ?, answeredByHuman = ?, answeredAt = ?
                    WHERE id = ? AND status = 'pending'
                    """,
                arguments: [BusStatus.answered.rawValue, answer, byHuman, now, id]
            )
            guard db.changesCount == 1,
                  let updated = try BusMessageRecord.fetchOne(db, key: id) else {
                // Lost the in-transaction race (belt-and-braces: the guard above
                // already ran inside this transaction).
                return .alreadyAnswered
            }
            return .answered(updated.message)
        }
    }

    /// PENDING questions addressed to `projectID`, oldest first — the inbox
    /// half of `check_messages`.
    func pendingBusMessages(to projectID: UUID) async throws -> [BusMessage] {
        try await writer.read { db in
            try BusMessageRecord
                .filter(Column("toProjectID") == projectID
                        && Column("status") == BusStatus.pending.rawValue)
                .order(Column("askedAt"))
                .fetchAll(db)
                .map(\.message)
        }
    }

    /// How many questions are OPEN for `projectID` right now — pending AND not
    /// past their TTL. The count the `/pending` probe answers with.
    ///
    /// The `expiresAt` guard is deliberate and is what makes this different
    /// from `pendingBusMessages(to:).count`: the probe never sweeps (a shell
    /// hook must not drive expiry), so a question that has lapsed but has not
    /// been swept yet must not be nudged about.
    func openBusMessageCount(to projectID: UUID, now: Date = Date()) async throws -> Int {
        try await writer.read { db in
            try BusMessageRecord
                .filter(Column("toProjectID") == projectID
                        && Column("status") == BusStatus.pending.rawValue
                        && Column("expiresAt") > now)
                .fetchCount(db)
        }
    }

    /// COUNT of terminal outcomes `projectID` has not yet seen — the read-only
    /// sibling of `claimUnseenBusOutcomes` for the hook probe. Deliberately
    /// does NOT mark anything seen: only a real `check_messages` claims.
    func unseenBusOutcomeCount(for projectID: UUID) async throws -> Int {
        try await writer.read { db in
            try BusMessageRecord
                .filter(sql: """
                    fromProjectID = ? AND answerSeenAt IS NULL
                    AND status IN ('answered', 'expired', 'closed')
                    """, arguments: [projectID])
                .fetchCount(db)
        }
    }

    /// Terminal outcomes (answers AND expiries) of questions `projectID` ASKED
    /// that it has not yet seen, oldest first — the second half of
    /// `check_messages`. Reading them MARKS them seen in the same transaction,
    /// so a row is reported exactly once and a relaunch neither repeats nor
    /// swallows it.
    func claimUnseenBusOutcomes(for projectID: UUID, now: Date = Date()) async throws -> [BusMessage] {
        try await writer.write { db in
            let rows = try BusMessageRecord
                .filter(sql: """
                    fromProjectID = ? AND answerSeenAt IS NULL
                    AND status IN ('answered', 'expired', 'closed')
                    """, arguments: [projectID])
                .order(Column("askedAt"))
                .fetchAll(db)
            guard !rows.isEmpty else { return [] }
            try db.execute(
                sql: """
                    UPDATE busMessage SET answerSeenAt = ?
                    WHERE id IN (\(databaseQuestionMarks(count: rows.count)))
                    """,
                arguments: StatementArguments([now] + rows.map { $0.id as DatabaseValueConvertible })
            )
            return rows.map(\.message)
        }
    }

    /// Marks ONE outcome seen by its asker — the inline long-poll path, where
    /// the answer is handed straight back instead of through check_messages.
    /// Scoped to a single id on purpose: claiming the caller's whole unseen set
    /// here would swallow answers to its OTHER questions.
    func markBusOutcomeSeen(id: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE busMessage SET answerSeenAt = ? WHERE id = ? AND answerSeenAt IS NULL",
                arguments: [date, id]
            )
        }
    }

    /// Marks a question DELIVERED to its target project (first `check_messages`
    /// read or live long-poll hand-off). Raw SQL on the bookkeeping column
    /// only, and only if not already stamped — the first delivery is the
    /// truthful one.
    func markBusMessageDelivered(id: String, at date: Date = Date()) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "UPDATE busMessage SET deliveredAt = ? WHERE id = ? AND deliveredAt IS NULL",
                arguments: [date, id]
            )
        }
    }

    /// Lapses every PENDING question whose TTL has passed and returns the rows
    /// that actually flipped (empty when there was nothing to do). The status
    /// guard lives in the UPDATE, so a question answered in the same instant
    /// wins and is never overwritten by the sweep.
    @discardableResult
    func expireLapsedBusMessages(now: Date = Date()) async throws -> [BusMessage] {
        try await writer.write { db in
            let due = try BusMessageRecord
                .filter(sql: "status = 'pending' AND expiresAt <= ?", arguments: [now])
                .fetchAll(db)
            guard !due.isEmpty else { return [] }
            try db.execute(
                sql: """
                    UPDATE busMessage
                    SET status = ?, closedReason = ?
                    WHERE status = 'pending' AND expiresAt <= ?
                    """,
                arguments: [BusStatus.expired.rawValue,
                            "no answer before the question timed out", now]
            )
            let ids = Set(due.map(\.id))
            return try BusMessageRecord
                .filter(ids.contains(Column("id")))
                .filter(Column("status") == BusStatus.expired.rawValue)
                .order(Column("askedAt"))
                .fetchAll(db)
                .map(\.message)
        }
    }

    /// Closes ONE still-pending question — the human's "close the thread"
    /// action in the Messages tab. Returns the closed row, or nil when the
    /// question was already terminal (somebody answered or it lapsed first);
    /// the status guard lives in the UPDATE, so the human can never overwrite
    /// an answer that landed in the same instant.
    @discardableResult
    func closeBusMessage(id: String, reason: String) async throws -> BusMessage? {
        try await writer.write { db in
            try db.execute(
                sql: """
                    UPDATE busMessage SET status = ?, closedReason = ?
                    WHERE id = ? AND status = 'pending'
                    """,
                arguments: [BusStatus.closed.rawValue, reason, id]
            )
            guard db.changesCount == 1 else { return nil }
            return try BusMessageRecord.fetchOne(db, key: id)?.message
        }
    }

    /// Closes every still-pending question between a project pair — the unlink
    /// path (a question can no longer be answered across a link that is gone).
    /// Returns the closed rows so the router can wake their long-poll waiters;
    /// the SQL flip alone cannot.
    @discardableResult
    func closePendingBusMessages(
        between first: UUID, and second: UUID, reason: String
    ) async throws -> [BusMessage] {
        try await closePending(
            reason: reason,
            predicate: """
                (fromProjectID = ? AND toProjectID = ?)
                  OR (fromProjectID = ? AND toProjectID = ?)
                """,
            arguments: [first, second, second, first]
        )
    }

    /// Drops every message a project is a party to — the project-deletion path.
    /// Closes EVERY still-pending question this project is on either end of,
    /// with an honest reason. The deletion path calls this BEFORE the rows go,
    /// so a session long-polling on one of them is woken and told the truth
    /// instead of blocking until its wait window elapses against a row that no
    /// longer exists. Returns the closed rows so the router can wake their
    /// waiters (the SQL flip alone cannot).
    @discardableResult
    func closePendingBusMessages(
        involving projectID: UUID, reason: String
    ) async throws -> [BusMessage] {
        try await closePending(
            reason: reason,
            predicate: "fromProjectID = ? OR toProjectID = ?",
            arguments: [projectID, projectID]
        )
    }

    /// The one close-a-set-of-pending-rows write. Reads the matching rows and
    /// flips them in the SAME transaction, so the returned set is exactly what
    /// was closed — never a row a concurrent answer settled first.
    private func closePending(
        reason: String, predicate: String, arguments: StatementArguments
    ) async throws -> [BusMessage] {
        try await writer.write { db in
            let pending = try BusMessageRecord
                .filter(sql: "status = ? AND (\(predicate))",
                        arguments: [BusStatus.pending.rawValue] + arguments)
                .fetchAll(db)
            guard !pending.isEmpty else { return [] }
            try db.execute(
                sql: """
                    UPDATE busMessage SET status = ?, closedReason = ?
                    WHERE status = 'pending' AND (\(predicate))
                    """,
                arguments: [BusStatus.closed.rawValue, reason] + arguments
            )
            return pending.map { record in
                var message = record.message
                message.status = .closed
                message.closedReason = reason
                return message
            }
        }
    }

    func deleteBusMessages(involving projectID: UUID) async throws {
        try await writer.write { db in
            try db.execute(
                sql: "DELETE FROM busMessage WHERE fromProjectID = ? OR toProjectID = ?",
                arguments: [projectID, projectID]
            )
        }
    }
}

/// "?, ?, ?" for an IN clause of `count` bound values.
private nonisolated func databaseQuestionMarks(count: Int) -> String {
    Array(repeating: "?", count: count).joined(separator: ", ")
}

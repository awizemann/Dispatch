// PersistenceDeliveryMarkLockTests.swift
// Locks a house convention: the bus delivery-bookkeeping columns (deliveredAt,
// answerSeenAt) are mutated by RAW SQL ONLY (GlobalDatabase
// .markBusMessageDelivered / .claimUnseenBusOutcomes), so they are kept OFF the
// Codable/persistable record struct — a whole-record save can then never
// clobber a concurrently-written delivery mark.
//
// Without this suite the convention is prose only (the BusMessageRecord
// comment). A future dev adding `deliveredAt` to the record's stored properties
// would silently reintroduce the clobber path — this suite fails instead.
//
// Discriminating power:
// - The lock reads the record's ACTUAL persisted column set through GRDB's own
//   record encoder (`databaseDictionary`), which records a nil optional as a
//   NULL column — so even a `var deliveredAt: Date? = nil` addition is caught,
//   not just a non-nil one (the false-negative a CodingKeys-by-eye check misses).
// - The completeness guard scans the migrated schema for EVERY bookkeeping-
//   marked table, so a NEW such table (or a new bookkeeping column) can't dodge
//   the lock unnoticed — it must be consciously classified here.

import Foundation
import GRDB
import Testing
@testable import DispatchApp

@Suite("Persistence delivery-mark lock")
struct PersistenceDeliveryMarkLockTests {

    /// A persisted column is delivery BOOKKEEPING iff its name carries
    /// "delivered" or "seen" — deliveredAt, answerSeenAt, and any future
    /// sibling. Matching by substring (not a frozen list) means a newly-named
    /// bookkeeping column is caught on both sides of the lock.
    private static func isBookkeepingColumn(_ name: String) -> Bool {
        let lowered = name.lowercased()
        return lowered.contains("delivered") || lowered.contains("seen")
    }

    /// A record's ACTUAL persisted columns, via GRDB's record encoder. A nil
    /// optional still surfaces as a NULL column key, so an added-but-nil
    /// delivery field cannot hide from the lock.
    private static func persistedColumns(_ record: some EncodableRecord) throws -> Set<String> {
        Set(try record.databaseDictionary.keys)
    }

    // MARK: The lock

    @Test("BusMessageRecord encodes no delivery-bookkeeping column")
    func offRecordConventionExcludesDeliveryColumns() throws {
        let columns = try Self.persistedColumns(BusMessageRecord(message: Self.sampleMessage))
        let offenders = columns.filter(Self.isBookkeepingColumn).sorted()
        #expect(
            offenders.isEmpty,
            "BusMessageRecord must not encode \(offenders) — they are raw-SQL-only, so a whole-record save would clobber a live delivery mark"
        )
    }

    // MARK: Completeness guard

    @Test("Every delivery-marked table is accounted for — a new one can't dodge the lock")
    func everyDeliveryMarkedTableIsClassified() throws {
        let queue = try DatabaseQueue()
        try GlobalSchema.makeMigrator().migrate(queue)
        let marked = try queue.read { db -> Set<String> in
            let names = try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table'
                  AND name NOT LIKE 'sqlite\\_%' ESCAPE '\\'
                """)
            var tables: Set<String> = []
            for table in names
            where try db.columns(in: table).map(\.name).contains(where: Self.isBookkeepingColumn) {
                tables.insert(table)
            }
            return tables
        }

        // busMessage keeps its bookkeeping columns OFF the record — asserted by
        // the lock above. Any other table appearing here must be consciously
        // classified: off-record → also cover it in the lock; born-unmarked and
        // saved exactly once → document why the whole-record save stays safe.
        let classified: Set<String> = ["busMessage"]
        #expect(
            marked == classified,
            "unclassified delivery-marked table(s) \(marked.subtracting(classified).sorted())"
        )
    }

    // MARK: Fixture
    //
    // The lock inspects the column SET, which is identical for every instance of
    // the record type (delivery optionals, if present, encode as NULL keys
    // regardless of value), so one instance suffices.

    private static let sampleMessage = BusMessage(
        id: "q-0001", from: UUID(), to: UUID(),
        subject: "Token shape?", body: "JWT or session?",
        status: .pending, askedAt: Fixtures.date(),
        expiresAt: Fixtures.date(offset: 86_400)
    )
}

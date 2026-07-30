// Persistence.swift
// Entry point for the persistence layer: on-disk locations + the @MainActor
// DatabaseManager, which owns the app's ONE database.
//
// Dispatch keeps no per-project database. Everything it persists — projects,
// links, bus identities, and the messages between projects — is inherently
// cross-project, so it all lives in the one global database. A project's
// on-disk footprint is exactly its registry row.
//
// Cold-start contract (see .memory/conventions/performance-and-cold-start-rules):
// nothing here runs in the synchronous App init. The app boots with a lightweight
// placeholder, `await`s `bootstrap()` from a task, then wires stores on main. The
// blocking pool opens happen inside the actors' `nonisolated async` static `open`
// methods, which run on the global executor.

import Foundation

// MARK: - Locations

nonisolated enum DatabaseLocations {

    /// ~/Library/Application Support/Dispatch/
    static func rootDirectory() throws -> URL {
        try FileManager.default
            .url(for: .applicationSupportDirectory, in: .userDomainMask,
                 appropriateFor: nil, create: true)
            .appendingPathComponent(AppInfo.name, isDirectory: true)
    }

    /// ~/Library/Application Support/Dispatch/global.sqlite
    static func globalDatabaseURL() throws -> URL {
        try rootDirectory().appendingPathComponent("global.sqlite")
    }

}

// MARK: - Manager

@MainActor
final class DatabaseManager {

    private(set) var global: GlobalDatabase?

    /// Opens + migrates the global database. Call once from the app's launch task —
    /// never from the synchronous App init.
    @discardableResult
    func bootstrap() async throws -> GlobalDatabase {
        if let global { return global }
        let db = try await GlobalDatabase.open(at: DatabaseLocations.globalDatabaseURL())
        global = db
        return db
    }

    /// Best-effort cleanup for a per-project database file
    /// (Application Support/Dispatch/projects/<id>.sqlite) that an older build
    /// may have left behind. Deleting a project sweeps it if one is still on
    /// disk, so no install is left with orphaned files. Idempotent: unlinking a
    /// missing file is a no-op.
    ///
    /// The path is derived HERE from the project id — it lives only under
    /// Application Support, never anywhere inside the user's repo.
    func deleteLegacyProjectDatabase(id: UUID) async throws {
        let root = try DatabaseLocations.rootDirectory()
            .appendingPathComponent("projects", isDirectory: true)
            .appendingPathComponent("\(id.uuidString).sqlite")
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(at: URL(fileURLWithPath: root.path + suffix))
        }
    }
}

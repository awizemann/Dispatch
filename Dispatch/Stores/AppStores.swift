// AppStores.swift
// Composition root for the domain stores, injected app-wide via .environment.
//
// The Dispatch keep-slice: projects, messages, cross-project links and the
// activity ticker, over one bus core (`DispatchRouter`). P5 dropped the agent
// roster store with the last UI that read it — Dispatch has no agents of its
// own, only projects whose OWN sessions connect over the bus.
//
// This is also where a bus EVENT becomes user-visible: the router emits, and
// `handle(busEvent:)` fans one event out to the ticker, the sound and the
// system-notification poster. That fan-out lives here, not in the router,
// because the router must not know what a ticker or a banner is.

import Defaults
import Foundation
import Observation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "stores")

/// Settings modal tabs — General (inbox scope + bus status), Theme, and
/// Notifications (one row per bus event).
enum SettingsTab: String, CaseIterable, Identifiable {
    case general = "General"
    case theme = "Theme"
    case notifications = "Notifications"

    var id: String { rawValue }
}

/// The seam that lets a write closure built before the composition root report a
/// failure INTO it. One indirection, deliberately tiny: the alternative is a
/// throwing write surface, which is a P8-sized refactor of every writer bundle.
@MainActor
final class ProblemRelay {
    var sink: ((String, [UUID]) -> Void)?

    func report(_ text: String, projectIDs: [UUID] = []) {
        sink?(text, projectIDs)
    }
}

@MainActor
@Observable
final class AppStores {

    let projects: ProjectStore
    let messages: MessageStore
    let activity: ActivityStore
    /// Cross-project links + the per-project request mirror.
    let crossProject: CrossProjectStore
    /// Recent bus traffic, as the bus map animates it. A ring
    /// buffer, not a subscription: the map reads it, nothing else does.
    let busPulses = BusPulseStore()
    /// Each project's real face — its repo's app icon or favicon — decoded once
    /// and cached in memory. Empty is a valid steady state: a repo
    /// with no icon keeps the letter tile.
    let icons = ProjectIconStore()

    /// Settings modal route (nil = closed).
    var settingsRoute: SettingsTab?

    /// First-run onboarding: set true when the human SKIPS the welcome surface.
    /// Session-only — a relaunch with a still-empty registry re-onboards.
    var onboardingDismissed = false

    /// Whether the first-run welcome surface should show right now.
    var shouldShowOnboarding: Bool {
        OnboardingGate.shouldShow(
            projectCount: projects.projects.count,
            dismissedThisSession: onboardingDismissed
        )
    }

    /// Cross-tab navigation request (e.g. a rail affordance → Messages focus).
    /// WorkbenchView switches tabs on it; the target tab consumes it and clears
    /// it back to nil.
    var routeRequest: WorkbenchRouteRequest?

    /// Live composition only: retains the DB registry (project DBs open on
    /// selection). nil in mocks.
    @ObservationIgnored var databases: DatabaseManager?
    /// Live composition only: the global database, for the bus wiring.
    @ObservationIgnored var global: GlobalDatabase?
    /// The bus core. Bound to the listener in `live()`; nil in mocks.
    @ObservationIgnored var router: DispatchRouter?
    /// The Messages tab's human-arbitration seam: the router in the live
    /// composition, MockBusArbitrator in the scripted scenario. nil disables
    /// the Answer buttons (no write path).
    @ObservationIgnored var arbitration: (any BusArbitrating)?
    /// The system-notification poster. nil in mocks — the real
    /// UNUserNotificationCenter crashes under a bare xctest host.
    @ObservationIgnored var notificationPoster: NotificationPoster?
    /// Bus feedback sounds. nil in mocks/tests (no audio in a headless host).
    @ObservationIgnored var sounds: (any SoundPlaying)?

    private var activated = false

    init(
        projects: ProjectStore,
        messages: MessageStore,
        activity: ActivityStore,
        crossProject: CrossProjectStore = CrossProjectStore()
    ) {
        self.projects = projects
        self.messages = messages
        self.activity = activity
        self.crossProject = crossProject
    }

    /// The scripted mock scenario (`--mock-scenario`) — previews and store tests.
    static func mock() -> AppStores {
        MockData.makeStores()
    }

    /// The real composition: GlobalDatabase behind the read seam, ProjectWriters
    /// over its write surface, GitClient behind GitStatusProviding. Called from
    /// the app's launch task — never from the synchronous App init.
    static func live() async throws -> AppStores {
        let databases = DatabaseManager()
        let global = try await databases.bootstrap()
        let git = GitClient()
        // MCP bus: one app-hosted listener, one endpoint identity per project.
        // The router is the brain; the listener is the wire; the tokens are the
        // identities. Built HERE, before the writers, because the destructive-
        // deletion and unlink paths below must close in-flight questions
        // THROUGH it — closing them in SQL alone would leave a long-polling
        // session parked on a row that no longer exists.
        let router = DispatchRouter(global: global)
        // The failure channel for the write closures below. They are built
        // BEFORE `stores` exists, so a relay carries their problems to it once
        // it does — without it, a link that failed to persist was a log line and
        // a UI that pretended the link was there (audit S3).
        let relay = ProblemRelay()

        let writers = ProjectWriters(
            saveProject: { try await global.saveProject($0) },
            // Registry-row-only delete: the add-project rollback path.
            deleteProject: { try await global.deleteProject(id: $0) },
            // FULL destructive deletion: legacy project DB file → bookmark →
            // registry row (LAST). Every step targets ONLY Dispatch-owned state;
            // the user's repo is never touched.
            deleteProjectFully: { @MainActor projectID, repoPath in
                let deletion = ProjectDeletion(steps: ProjectDeletionSteps(
                    // 0. The repo's OWN file first: take the `dispatch` entry
                    //    back out of `<repoRoot>/.mcp.json` while we still have
                    //    the path. Best-effort — a repo that has been deleted or
                    //    unmounted must never block the project's deletion.
                    removeRepoEntry: {
                        do { try await RepoMCPInstaller.shared.uninstall(repoPath: repoPath) }
                        catch { logger.error("repo .mcp.json uninstall failed: \(String(describing: error), privacy: .public)") }
                        // The session hooks go with the project, not with a
                        // link: DELETE removes them, UNLINK does not (a project
                        // may still be linked elsewhere, and with no links left
                        // the hook is a harmless no-op — it reports zero and
                        // says nothing). Best-effort, like the entry above.
                        do { try await RepoHooksInstaller.shared.uninstall(repoPath: repoPath) }
                        catch { logger.error("repo .claude/settings.local.json hook uninstall failed: \(String(describing: error), privacy: .public)") }
                    },
                    deleteProjectDatabase: { try await databases.deleteLegacyProjectDatabase(id: $0) },
                    releaseBookmark: { _ in
                        // The bookmark is a column on the registry row (dropped
                        // with the row). Kept as an explicit step so a future
                        // sandboxed build has the seam.
                    },
                    deleteRegistryRow: { @MainActor id in
                        // FIRST: close every question this project is still on
                        // either end of, which WAKES any session long-polling
                        // on one. Before the rows are deleted, so a waiter is
                        // told the truth instead of blocking on a row that is
                        // about to vanish.
                        await router.closeAllPending(
                            involving: id,
                            reason: "the project was removed from Dispatch before it was answered"
                        )
                        // Then drop this project's links, bus identity and bus
                        // history alongside its registry row. Best-effort — a
                        // failed prune must not block the row delete.
                        do { try await global.deleteProjectLinks(involving: id) }
                        catch { logger.error("deleteProjectLinks(involving:) failed: \(String(describing: error), privacy: .public)") }
                        await MCPBusListener.shared.unregister(projectID: id)
                        // The router must stop believing a deleted project is
                        // live — its liveness would otherwise outlive the row.
                        router.forgetSession(projectID: id)
                        do { try await global.deleteBusToken(projectID: id) }
                        catch { logger.error("deleteBusToken failed: \(String(describing: error), privacy: .public)") }
                        do { try await global.deleteBusMessages(involving: id) }
                        catch { logger.error("deleteBusMessages failed: \(String(describing: error), privacy: .public)") }
                        try await global.deleteProject(id: id)
                    }
                ))
                try await deletion.run(projectID: projectID)
            },
            setPinned: { id, pinned in
                do { try await global.setPinned(projectID: id, pinned: pinned) }
                catch { logger.error("pin write failed: \(String(describing: error), privacy: .public)") }
            },
            setSessionHooks: { id, enabled in
                do { try await global.setSessionHooksEnabled(projectID: id, enabled: enabled) }
                catch { logger.error("session-hooks opt-in write failed: \(String(describing: error), privacy: .public)") }
            },
            saveBookmark: { try await global.saveRepoBookmark(projectID: $0, bookmark: $1) },
            loadBookmark: { try await global.repoBookmark(projectID: $0) },
            updateGitCache: { try await global.updateGitStatusCache(projectID: $0, git: $1) },
            updateLastOpened: { id, date in
                do { try await global.updateLastOpenedAt(projectID: id, date: date) }
                catch { logger.error("lastOpenedAt write failed: \(String(describing: error), privacy: .public)") }
            }
        )

        let stores = AppStores(
            projects: ProjectStore(reader: global, writers: writers, git: git),
            messages: MessageStore(global: global),
            activity: ActivityStore(),
            // Links observed off the GLOBAL DB; add/remove persisted through it.
            crossProject: CrossProjectStore(
                global: global,
                writers: CrossProjectLinkWriters(
                    addLink: { a, b in
                        do { try await global.saveProjectLink(ProjectLink(a, b)) }
                        catch {
                            logger.error("saveProjectLink failed: \(String(describing: error), privacy: .public)")
                            await relay.report(
                                "Dispatch couldn't save that link — the two projects are NOT "
                                + "linked, and their sessions still can't reach each other.",
                                projectIDs: [a, b]
                            )
                        }
                    },
                    removeLink: { a, b in
                        do { try await global.deleteProjectLink(between: a, and: b) }
                        catch {
                            logger.error("deleteProjectLink failed: \(String(describing: error), privacy: .public)")
                            await relay.report(
                                "Dispatch couldn't remove that link — the two projects are STILL "
                                + "linked and can still ask each other questions.",
                                projectIDs: [a, b]
                            )
                        }
                        // Fail closed on BOTH ends: a question can no longer be
                        // answered across a link that is gone, so pending rows
                        // between the pair close honestly instead of sitting in
                        // an inbox nobody may answer. Through the ROUTER, so a
                        // session long-polling on one of them wakes now rather
                        // than sitting out its whole wait window.
                        await router.closeAllPending(
                            between: a, and: b,
                            reason: "the projects were unlinked before it was answered"
                        )
                    }
                )
            )
        )
        stores.databases = databases
        // Registration happens in `activateBus()` once the project roster has
        // actually loaded — a token minted for a project that is not in the
        // registry would route nowhere.
        await MCPBusListener.shared.configure(router: router)
        stores.router = router
        stores.arbitration = router
        stores.global = global
        stores.notificationPoster = NotificationPoster(center: SystemUserNotifying())
        stores.sounds = SoundPlayer()
        // The one subscription to what the bus did. `[weak stores]` because the
        // router is retained BY stores — a strong capture here would be a cycle
        // that outlives the window.
        router.onEvent = { [weak stores] event in stores?.handle(busEvent: event) }
        relay.sink = { [weak stores] text, projectIDs in
            stores?.report(problem: text, blocking: true, projectIDs: projectIDs)
        }
        return stores
    }

    /// Idempotent; kicked off once from the workbench root's .task.
    func activate() async {
        guard !activated else { return }
        activated = true
        wireRegistryHooks()
        async let p: Void = projects.activate()
        async let m: Void = messages.activate()
        async let xp: Void = crossProject.activate()
        _ = await (p, m, xp)
        await activateBus()
    }

    /// Subscribes the composition root to the project registry. Called from
    /// `activate()` BEFORE the stores load, so the hook catches the very first
    /// delivery and not just the ones after it. Separate from `activate()` so a
    /// test can wire the real hooks without starting a real listener.
    func wireRegistryHooks() {
        projects.onProjectsChanged = { [weak self] projects in
            self?.projectsDidChange(projects)
        }
        projects.onSelectionChange = { [weak self] projectID in
            guard let self, let projectID else { return }
            // Selecting a project is the moment its card is about to be read —
            // re-verify what its repo file actually says (audit S2), and give
            // its icon a cheap re-check (one stat when it is already cached).
            Task { await self.verifyRepoInstall(for: projectID) }
            Task { await self.icons.recheck(projectID: projectID) }
        }
        // Icon discovery resolves the repo folder exactly the way the git
        // refresh does — bookmark first, through the access scope.
        icons.repoURLProvider = { [weak self] projectID in
            await self?.projects.existingRepoURL(projectID: projectID)
        }
    }

    /// Every registry change, from the ONE projects observation: the router's
    /// name map, the pruning of per-project bus state, and a first install for
    /// a project that appeared after activation.
    ///
    /// The name map is the whole of S1: `list_projects` and `resolvePeer` read
    /// it, so a map frozen at launch made a project added later unreachable and
    /// kept resolving a name that had been renamed away.
    private func projectsDidChange(_ projects: [Project]) {
        // A pulse to a station that no longer exists has nowhere to land. Done
        // BEFORE the router guard: a deletion must clear the map in every
        // composition, including the routerless mock.
        busPulses.prune(knownProjectIDs: Set(projects.map(\.id)))
        // Same reasoning for the icon cache — and the same
        // every-composition placement, since a project can be deleted in the
        // routerless mock too.
        icons.prune(knownProjectIDs: Set(projects.map(\.id)))
        // Launch, and every registry gain after it: discover the face of any
        // project that hasn't been looked at yet. Cached and already-empty
        // projects cost nothing here.
        let projectIDs = projects.map(\.id)
        Task { await self.icons.refreshAll(projectIDs: projectIDs) }
        guard let router else { return }
        router.setProjectNames(
            Dictionary(projects.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        )
        // Drop per-project bus state for rows that are gone (the deletion path
        // does the durable work; this keeps the observable mirrors honest).
        let live = Set(projects.map(\.id))
        repoInstallStates = repoInstallStates.filter { live.contains($0.key) }
        repoHooksStates = repoHooksStates.filter { live.contains($0.key) }
        repoTokenExposure = repoTokenExposure.filter { live.contains($0.key) }
        sessionsNeedingRestart.formIntersection(live)
        guard busActivated else { return }
        // A project added after activation still needs its endpoint + repo entry.
        // (The add flow installs too; this covers any other path and is a no-op
        // once a state exists.)
        let unseen = projects.map(\.id).filter { repoInstallStates[$0] == nil }
        guard !unseen.isEmpty else { return }
        Task {
            for projectID in unseen { await self.syncRepoInstall(for: projectID) }
        }
    }

    /// True once `activateBus()` has run — before that, a registry delivery must
    /// not race the initial registration pass.
    private var busActivated = false

    /// Registers a bus endpoint for every known project, binds the listener on
    /// the persisted port, brings every repo's entry up to date, and starts the
    /// expiry sweep.
    ///
    /// Tokens are DURABLE (minted once per project, in the global DB), so this
    /// re-registers the same URLs on every launch — which is exactly what makes
    /// the entry P4 writes into a repo's `.mcp.json` keep working. A project
    /// added later comes through the registry observation (`projectsDidChange`).
    func activateBus() async {
        // Both must exist: the router does the registering, and every
        // registration below mints its token out of the global database.
        guard global != nil, let router else { return }
        projectsDidChange(projects.projects)
        // STABLE PORT: ask the listener to re-bind the port every `.mcp.json`
        // already on disk points at, BEFORE the first registration binds it.
        let persistedPort = Defaults[.busListenerPort]
        await MCPBusListener.shared.setPreferredPort(persistedPort)
        for project in projects.projects {
            await registerBusEndpoint(for: project.id)
        }
        // The bound port is the truth. If it is not the one we persisted, every
        // installed entry now points at a dead port — rewrite them all.
        let boundPort = await MCPBusListener.shared.port
        if let boundPort, boundPort != persistedPort {
            Defaults[.busListenerPort] = boundPort
            if persistedPort != 0 {
                logger.warning("bus port changed \(persistedPort, privacy: .public) → \(boundPort, privacy: .public); rewriting every repo entry")
                // A port change is not a detail: every repo's entry is being
                // rewritten under sessions that are already running against the
                // old one, and only a restart picks the new address up.
                report(problem: "The bus moved to port \(boundPort) — Dispatch rewrote every "
                       + "repo's .mcp.json. Restart the Claude Code sessions in those repos "
                       + "so they reconnect.")
            }
        }
        busActivated = true
        await syncAllRepoInstalls()
        await refreshBusStatus()
        // Anything that lapsed while the app was closed surfaces as expired
        // rather than sitting in an inbox pretending to be live.
        await router.sweepExpired()
        // …and from here a timer keeps doing it, so a question lapses on a
        // silent bus too (audit S2).
        router.startExpirySweep()
    }

    // MARK: - Listener status (rail footer)

    /// What the rail footer reports about the app's one listener. The listener
    /// is an actor, so its state is PULLED into this observable snapshot rather
    /// than read from a view.
    nonisolated struct BusListenerStatus: Equatable, Sendable {
        /// nil = not bound (the bus is down; no repo can reach it).
        var port: Int?
        /// How many projects have a live `dispatch` entry in their repo.
        var installedCount: Int
        var projectCount: Int

        var isRunning: Bool { port != nil }

        static let down = BusListenerStatus(port: nil, installedCount: 0, projectCount: 0)
    }

    /// Settable so the mock composition can script a running listener
    /// (`seedMockBusStatus`); the live app only ever writes it through
    /// `refreshBusStatus()`.
    var busStatus: BusListenerStatus = .down

    /// Re-reads the listener's bound port and recounts installs. Cheap; called
    /// after bus activation and on the footer's periodic refresh.
    ///
    /// No router means no live listener to read — the mock composition scripts
    /// `busStatus` instead, and polling the (never-started) shared listener
    /// there would stomp the scripted value with a false "not running".
    func refreshBusStatus() async {
        guard router != nil else { return }
        // RE-VERIFY, don't remember: `repoInstallStates` used to be written only
        // by the install path, so a hand-removed entry left the footer reporting
        // "installed" forever (audit S2). The footer's own poll is the natural
        // place to re-read the files.
        await verifyAllRepoInstalls()
        let port = await MCPBusListener.shared.port
        busStatus = BusListenerStatus(
            port: port,
            installedCount: repoInstallStates.count { $0.value == .installed },
            projectCount: projects.projects.count
        )
    }

    // MARK: - Per-project liveness (rail cards + footer popover)

    /// One project's bus liveness, as the rail draws it.
    nonisolated struct ProjectConnection: Equatable, Sendable {
        var isConnected: Bool
        /// nil = this project's endpoint has never been used in this run.
        var lastSeenAt: Date?

        static let never = ProjectConnection(isConnected: false, lastSeenAt: nil)
    }

    /// Mock/preview override for liveness — the scripted scenario has no live
    /// router, and a rail with every dot dark would misrepresent the product.
    /// Ignored entirely once a real router exists.
    @ObservationIgnored var mockConnections: [UUID: ProjectConnection] = [:]

    func connection(for projectID: UUID, now: Date = Date()) -> ProjectConnection {
        guard let router else { return mockConnections[projectID] ?? .never }
        return ProjectConnection(
            isConnected: router.isConnected(projectID, now: now),
            lastSeenAt: router.lastSeen(projectID)
        )
    }

    /// The names of the projects `projectID` is linked to, name-sorted — the
    /// link chips on its rail card. A link whose peer is no longer registered
    /// is dropped (it cannot be addressed).
    func linkedPeerNames(of projectID: UUID) -> [String] {
        crossProject.linkedPeerIDs(of: projectID)
            .compactMap { projects.project(id: $0)?.name }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    // MARK: - Bus events → ticker, sound, banner

    /// Everything user-visible that follows from one bus event. The single
    /// fan-out point: a new surface that should react to the bus adds a line
    /// here, not another subscription on the router.
    func handle(busEvent event: BusEvent) {
        activity.record(event, name: { [weak self] id in self?.projects.project(id: id)?.name })
        // The bus map's pulse seam. One line, per the rule above — the map
        // observes the ring buffer, it does not subscribe to the router.
        busPulses.record(event)
        switch event {
        case .asked: sounds?.play(.question)
        case .answered(let message) where !message.answeredByHuman: sounds?.play(.answer)
        case .connected(let projectID):
            // Traffic from that repo IS the evidence its session restarted and
            // read the new entry — the only evidence Dispatch can honestly have.
            sessionsNeedingRestart.remove(projectID)
        default: break
        }
        notificationPoster?.post(event, name: { [weak self] id in
            self?.projects.project(id: id)?.name
        })
    }

    /// Registers (or re-registers) one project's bus endpoint. Returns the URL
    /// the repo's `.mcp.json` entry points at, or nil when the bus could not be
    /// started — a bus failure must never block using the app.
    @discardableResult
    func registerBusEndpoint(for projectID: UUID) async -> String? {
        // A registration is only meaningful once the router exists to route to.
        guard let global, router != nil else { return nil }
        do {
            let token = try await global.busToken(projectID: projectID)
            return try await MCPBusListener.shared.register(projectID: projectID, token: token)
        } catch {
            logger.error("bus registration failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }

    /// Rotates a project's token: the old one stops resolving in the same
    /// breath the new one starts (DB replace + listener replace), and the repo's
    /// `.mcp.json` is rewritten to the new URL so the session on the other side
    /// can reconnect. A rotation that leaves the repo entry stale would look
    /// like a broken app, so the rewrite is part of the SAME action.
    @discardableResult
    func rotateBusToken(for projectID: UUID) async -> String? {
        let name = projects.project(id: projectID)?.name ?? "this project"
        guard let global else {
            // No global database means no rotation happened. Saying nothing here
            // is what made the menu item look like it worked (audit S3).
            report(problem: "Dispatch couldn't rotate \(name)'s bus token — its "
                   + "database isn't available.", blocking: true, projectIDs: [projectID])
            return nil
        }
        do {
            let token = try await global.rotateBusToken(projectID: projectID)
            let url = try await MCPBusListener.shared.register(projectID: projectID, token: token)
            await installRepoEntry(for: projectID, url: url)
            // The old URL is dead the instant the new one exists — the session in
            // that repo is now holding a revoked token until it restarts.
            if case .installed = repoInstallStates[projectID] {
                report(problem: "Rotated \(name)'s bus token and rewrote its .mcp.json. "
                       + "Restart the Claude Code session in that repo — the old token no "
                       + "longer works.", blocking: true, projectIDs: [projectID])
            } else {
                report(problem: "Rotated \(name)'s bus token, but its repo .mcp.json "
                       + "couldn't be rewritten. That repo's session can't reach the bus "
                       + "until the file is fixed.", blocking: true, projectIDs: [projectID])
            }
            return url
        } catch {
            logger.error("bus token rotation failed: \(String(describing: error), privacy: .public)")
            report(problem: "Dispatch couldn't rotate \(name)'s bus token.",
                   blocking: true, projectIDs: [projectID])
            return nil
        }
    }

    // MARK: - Problem reporting (audit S3)

    /// A blocking problem the human must see NOW — raised as an alert by the
    /// workbench. Only set for failures of an action the human just took.
    var problemAlert: String?

    /// One place a silent failure becomes visible: a ticker line on every
    /// project it concerns (so there is a record), and — for a failure of the
    /// human's OWN gesture — an alert.
    ///
    /// - Parameter projectIDs: empty = every project (a bus-wide fact).
    func report(problem text: String, blocking: Bool = false, projectIDs: [UUID] = []) {
        logger.warning("surfaced problem: \(text, privacy: .public)")
        let targets = projectIDs.isEmpty ? projects.projects.map(\.id) : projectIDs
        activity.record(text: text, in: targets)
        if blocking { problemAlert = text }
    }

    // MARK: - Repo install (P4)

    /// Per-project `.mcp.json` install state, for the rail's indicator. Absent =
    /// not evaluated yet.
    var repoInstallStates: [UUID: RepoMCPConfig.InstallState] = [:]

    /// Per-project bus-token exposure: the repo had its OWN
    /// `.mcp.json` before Dispatch, so we never touched its `.gitignore`, and
    /// the entry we merged in carries a token git is willing to commit. INFO,
    /// not a warning — nothing is broken, and the repair is the human's call.
    var repoTokenExposure: [UUID: RepoMCPInstaller.TokenExposure] = [:]

    /// Registers a project's endpoint and installs (or refreshes) the `dispatch`
    /// entry in its repo. The whole add/link path and the port-change rewrite
    /// both come through here, so there is ONE definition of "installed".
    func syncRepoInstall(for projectID: UUID) async {
        guard let url = await registerBusEndpoint(for: projectID) else {
            repoInstallStates[projectID] = .invalid("Dispatch couldn't start its local bus")
            return
        }
        await installRepoEntry(for: projectID, url: url)
    }

    /// Every project's entry — launch, and after a port change.
    func syncAllRepoInstalls() async {
        for project in projects.projects {
            await syncRepoInstall(for: project.id)
        }
    }

    /// Projects whose `.mcp.json` entry Dispatch has CHANGED in this run and
    /// whose repo session has not been seen since. An external Claude Code
    /// session reads that file once, at startup — so a rewritten entry means
    /// nothing until the human restarts it. Cleared the moment that project's
    /// endpoint carries traffic again (the only honest evidence of a restart:
    /// Dispatch cannot see a terminal).
    /// Settable so the mock composition and tests can script the cue; the live
    /// app only ever writes it through the install path and the connect event.
    var sessionsNeedingRestart: Set<UUID> = []

    func needsSessionRestart(_ projectID: UUID) -> Bool {
        sessionsNeedingRestart.contains(projectID)
    }

    private func installRepoEntry(
        for projectID: UUID, url: String, replacingForeignEntry: Bool = false
    ) async {
        guard let project = projects.project(id: projectID) else { return }
        do {
            let outcome = try await RepoMCPInstaller.shared.install(
                repoPath: project.repoPath, url: url,
                replacingForeignEntry: replacingForeignEntry
            )
            repoInstallStates[projectID] = .installed
            repoTokenExposure[projectID] = await RepoMCPInstaller.shared.tokenExposure(
                repoPath: project.repoPath)
            // Only a real byte change earns the restart cue — a launch that
            // re-writes the identical entry must not nag.
            if outcome.changed, router != nil, !isConnected(projectID) {
                sessionsNeedingRestart.insert(projectID)
            }
        } catch let error as RepoMCPConfig.ConfigError {
            // The URL carries the project's token — the state text describes the
            // FILE, never the entry we wanted to write.
            repoInstallStates[projectID] = Self.state(for: error)
            logger.error("repo .mcp.json install failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
        } catch {
            repoInstallStates[projectID] = .invalid("Dispatch couldn't write the repo's .mcp.json")
            logger.error("repo .mcp.json install failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
        }
    }

    private func isConnected(_ projectID: UUID) -> Bool {
        router?.isConnected(projectID) ?? false
    }

    /// The human's explicit "yes, replace it" for a repo whose `dispatch` key
    /// belongs to someone else's server (the modal's Replace entry button). The
    /// ONLY path that may overwrite a foreign entry.
    func replaceForeignRepoEntry(for projectID: UUID) async {
        guard let url = await registerBusEndpoint(for: projectID) else {
            repoInstallStates[projectID] = .invalid("Dispatch couldn't start its local bus")
            return
        }
        await installRepoEntry(for: projectID, url: url, replacingForeignEntry: true)
        await refreshBusStatus()
    }

    private static func state(for error: RepoMCPConfig.ConfigError) -> RepoMCPConfig.InstallState {
        switch error {
        case .invalidJSON:
            .invalid("This repo's .mcp.json isn't valid JSON — Dispatch left it alone. Fix the file, then rotate the token to retry.")
        case .unreadable:
            .invalid("Dispatch couldn't read this repo's .mcp.json.")
        case .repoUnavailable:
            .invalid("This repo's folder isn't reachable — Dispatch couldn't write .mcp.json.")
        case .foreignEntry:
            .conflict(RepoMCPConfig.conflictReason)
        }
    }

    // MARK: - Session hooks

    /// Per-project `.claude/settings.local.json` hook state, for the modal's toggle
    /// row. Absent = not evaluated yet.
    var repoHooksStates: [UUID: RepoHooksConfig.InstallState] = [:]

    /// The human's opt-in, in one place: persist the flag, then make the repo's
    /// file match it. OFF is a REMOVAL, not a no-op — turning the toggle off has
    /// to take our lines back out of the user's file, or the switch is a lie.
    func setSessionHooks(_ enabled: Bool, for projectID: UUID) async {
        guard let project = projects.project(id: projectID) else { return }
        await projects.setSessionHooks(enabled, for: projectID)
        do {
            if enabled {
                try await RepoHooksInstaller.shared.install(repoPath: project.repoPath)
                repoHooksStates[projectID] = .installed
            } else {
                try await RepoHooksInstaller.shared.uninstall(repoPath: project.repoPath)
                repoHooksStates[projectID] = .missing
            }
        } catch let error as RepoHooksConfig.ConfigError {
            repoHooksStates[projectID] = Self.hooksState(for: error)
            logger.error("session hooks write failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
            // The FILE did not change, so the opt-in must not pretend it did.
            await projects.setSessionHooks(!enabled, for: projectID)
            report(problem: "Dispatch couldn't update \(project.name)'s .claude/settings.local.json, "
                   + "so its session hooks are unchanged.", blocking: true, projectIDs: [projectID])
        } catch {
            repoHooksStates[projectID] = .invalid("Dispatch couldn't write this repo's .claude/settings.local.json.")
            logger.error("session hooks write failed for \(project.name, privacy: .public): \(String(describing: error), privacy: .public)")
            await projects.setSessionHooks(!enabled, for: projectID)
        }
    }

    /// Re-reads what ONE repo's `.claude/settings.local.json` actually says. A repo
    /// whose opt-in is OFF is reported as `.missing` without a read: we do not
    /// go looking in a file the human never let us touch.
    func verifyRepoHooks(for projectID: UUID) async {
        guard let project = projects.project(id: projectID) else { return }
        guard project.sessionHooksEnabled else {
            repoHooksStates[projectID] = .missing
            return
        }
        repoHooksStates[projectID] = await RepoHooksInstaller.shared.state(
            repoPath: project.repoPath)
    }

    private static func hooksState(for error: RepoHooksConfig.ConfigError) -> RepoHooksConfig.InstallState {
        switch error {
        case .invalidJSON: .invalid(RepoHooksConfig.invalidReason)
        case .unreadable: .invalid("Dispatch couldn't read this repo's .claude/settings.local.json.")
        case .repoUnavailable: .invalid("This repo's folder isn't reachable — Dispatch couldn't write .claude/settings.local.json.")
        }
    }

    // MARK: - Install re-verification (audit S2)

    /// Re-reads what ONE repo's `.mcp.json` actually says right now. The
    /// expected URL comes from the live listener + the project's durable token,
    /// so a stale port or a rotated token reads as `.stale` rather than as
    /// "installed, honest".
    func verifyRepoInstall(for projectID: UUID) async {
        guard let global, router != nil,
              let project = projects.project(id: projectID) else { return }
        let expectedURL: String?
        do {
            let token = try await global.busToken(projectID: projectID)
            expectedURL = await MCPBusListener.shared.url(token: token)
        } catch {
            logger.error("install re-verification couldn't read the token: \(String(describing: error), privacy: .public)")
            expectedURL = nil
        }
        let state = await RepoMCPInstaller.shared.state(
            repoPath: project.repoPath, expectedURL: expectedURL
        )
        repoInstallStates[projectID] = state
        repoTokenExposure[projectID] = await RepoMCPInstaller.shared.tokenExposure(
            repoPath: project.repoPath)
        // The hooks live in a different file with a different failure mode, and
        // the modal shows both — they are re-read together or the section is
        // half honest.
        await verifyRepoHooks(for: projectID)
        // An entry that is no longer ours cannot be reached by that repo's
        // session, so a pending restart cue about it would be a second lie.
        if state != .installed { sessionsNeedingRestart.remove(projectID) }
    }

    func verifyAllRepoInstalls() async {
        for project in projects.projects {
            await verifyRepoInstall(for: project.id)
        }
    }

    /// The amber "needs your eyes" badge on UNSELECTED project cards: questions
    /// another project asked THIS one that nobody has answered.
    func attentionCount(for projectID: UUID) -> Int {
        messages.openCount(for: projectID)
    }

    /// The amber badge's action — select the project and focus the question
    /// that has been waiting longest. OLDEST, not newest: the badge is a
    /// backlog signal, and the one closest to lapsing is the one the human can
    /// still save. No pending question (a badge racing an answer) routes
    /// nowhere rather than to an arbitrary card.
    func routeToOldestPendingQuestion(in projectID: UUID) {
        projects.select(projectID)
        guard let oldest = messages.messages
            .filter({ $0.to == projectID && $0.status == .pending })
            .min(by: { $0.askedAt < $1.askedAt })
        else { return }
        routeRequest = .message(projectID: projectID, messageID: oldest.id)
    }
}

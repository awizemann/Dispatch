// MessagesTabView.swift
// The Messages tab: the switchboard's message centre — every question between
// linked projects, made inspectable and human-arbitrable. One white framed
// panel on the canvas: toolbar row, hairline divider, then the scrollable
// question-card list (newest first).
//
// Participants are PROJECTS. A card is one project's question to another,
// answerable by that project's own Claude Code session or, at any time, by the
// human (arbitration). The human can also close a thread, or copy a nudge to
// paste into the asked session — Dispatch has no channel into a terminal.
//
// SCOPE: by default this is one inbox across EVERY project (Settings → General
// turns it back into a per-project view). Traffic between repos is the point;
// making the human first pick the right rail card to find the question they
// were notified about is exactly the friction the product exists to remove.

import AppKit   // NSPasteboard — the nudge's only side effect
import Defaults
import SwiftUI

struct MessagesTabView: View {
    @Environment(AppStores.self) private var stores
    @Environment(Theme.self) private var theme
    @Default(.messagesShowAllProjects) private var showAllProjects

    @State private var model = MessagesInboxModel()
    /// Card under the chip→card focus pulse.
    @State private var highlightedID: String?
    /// DEBUG `--expand-messages` (with --mock-scenario): boot with every card
    /// open. The verification policy forbids synthetic clicks, so the expanded
    /// card — where the answer block and the pending action row live — is
    /// otherwise unreachable in a headless screenshot pass.
    @State private var didApplyLaunchExpansion = false

    var body: some View {
        Group {
            if showAllProjects {
                inbox(projectID: nil)
            } else if let projectID = stores.projects.selectedProjectID {
                inbox(projectID: projectID)
            } else {
                emptyPanel("Select a project in the rail to see its questions, or switch "
                           + "Settings → General back to the all-projects inbox.")
            }
        }
        .padding(EdgeInsets(
            top: 4,
            leading: Metrics.surfacePadding,
            bottom: Metrics.surfacePadding,
            trailing: Metrics.surfacePadding
        ))
        // SELECTION SCOPING: picking a project in the rail (or
        // clicking its station on the map) scopes the all-projects inbox to it
        // by driving the SAME chip the human can click, so the toolbar always
        // shows what is being filtered and one click clears it. Runs on the
        // initial pass too, so the inbox boots scoped to the restored selection.
        //
        // Only in the all-projects inbox: the per-project inbox is already
        // scoped by `projectID`, and there `peerFilter` means "the peer", so
        // pinning it to the selected project would filter to a project that
        // cannot appear in its own peer list — an inbox that always renders
        // empty. Flipping the setting therefore also releases the scope.
        .task(id: ScopeKey(showAll: showAllProjects,
                           selected: stores.projects.selectedProjectID)) {
            model.applySelectionScope(
                showAllProjects ? stores.projects.selectedProjectID : nil
            )
        }
        .task {
            #if DEBUG
            guard !didApplyLaunchExpansion else { return }
            didApplyLaunchExpansion = true
            if CommandLine.arguments.contains("--expand-messages") {
                model.setGlobalExpansion(true)
            }
            if let filter = LaunchState.statusFilter() {
                model.statusFilter = filter
            }
            #endif
        }
    }

    /// `.task(id:)` key for the selection scope — re-run when the rail selection
    /// or the all-projects setting changes.
    private struct ScopeKey: Equatable {
        let showAll: Bool
        let selected: UUID?
    }

    // MARK: - Inbox panel

    /// - Parameter projectID: nil = the all-projects inbox.
    private func inbox(projectID: UUID?) -> some View {
        // Selection/detail state (answeringID, highlight, route target) always
        // resolves against this UNFILTERED source (view-discipline note); the
        // model only narrows what the list shows.
        let all = projectID.map { stores.messages.messages(in: $0) } ?? stores.messages.messages
        let counts = MessageInboxLogic.counts(of: all)
        // Filters/search always see the FULL set (ruling); the window rides on
        // top of the result. `filtered` is the full match set; `visible` is the
        // rendered slice, growing on "Load older".
        let filtered = MessageInboxLogic.apply(
            all, query: model.query, status: model.statusFilter,
            peerID: model.peerFilter, projectLabel: projectLabel(_:)
        )
        let visible = MessageInboxLogic.window(filtered, pageCount: model.visiblePageCount)
        let hasMore = MessageInboxLogic.hasMore(
            filteredCount: filtered.count, pageCount: model.visiblePageCount
        )
        let answeringMessage = model.answeringID.flatMap { id in
            all.first { $0.id == id }
        }

        return VStack(spacing: 0) {
            MessagesToolbarView(
                model: model, counts: counts,
                peers: peerProjects(of: projectID, in: all)
            )
            Divider().overlay(Surface.hairline)
            list(visible: visible, allCount: all.count,
                 filteredCount: filtered.count, hasMore: hasMore, projectID: projectID)
        }
        .background(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .fill(Surface.white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Surface.hairline)
        )
        .cardShadow()
        // Lost the arbitration race: the asked project's own session answered —
        // or the thread lapsed or was closed — while the editor was open. The card
        // flips via the stream; drop the editor state.
        .onChange(of: answeringMessage?.status) { _, status in
            if let status, status != .pending { model.cancelAnswering() }
        }
    }

    private func list(
        visible: [BusMessage], allCount: Int, filteredCount: Int,
        hasMore: Bool, projectID: UUID?
    ) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    Text(scopeCaption(projectID: projectID))
                        .textStyle(TextStyle(TypeScale.ui(11, .semibold)))
                        .foregroundStyle(Ink.tertiary)
                        .padding(.bottom, 2)
                    if visible.isEmpty {
                        emptyListState(allCount: allCount)
                    } else {
                        ForEach(visible) { message in
                            card(message)
                                .id(message.id)
                        }
                        if hasMore {
                            loadOlderRow(shownCount: visible.count, totalCount: filteredCount)
                        }
                    }
                }
                .padding(EdgeInsets(top: 14, leading: 18, bottom: 14, trailing: 18))
            }
            .task(id: RouteScope(route: stores.routeRequest, projectID: projectID)) {
                consumeRoute(proxy: proxy, projectID: projectID)
            }
        }
    }

    // MARK: - Cards

    private func card(_ message: BusMessage) -> some View {
        QuestionCardView(
            message: message,
            fromProjectName: stores.projects.project(id: message.from)?.name,
            toProjectName: stores.projects.project(id: message.to)?.name,
            isExpanded: model.isExpanded(message.id),
            isAnswering: model.answeringID == message.id,
            isSubmitting: model.isSubmitting,
            isHighlighted: highlightedID == message.id,
            canAnswer: stores.arbitration != nil,
            didCopyNudge: model.nudgedID == message.id,
            draft: Binding(get: { model.draft }, set: { model.draft = $0 }),
            onToggleExpand: { withAnimation(Motion.state) { model.toggleExpansion(message.id) } },
            onStartAnswer: { model.beginAnswering(message.id) },
            onCancelAnswer: { model.cancelAnswering() },
            onSubmitAnswer: {
                guard let arbitrator = stores.arbitration else { return }
                Task { await model.submitAnswer(for: message, using: arbitrator) }
            },
            onNudge: {
                model.nudge(
                    message,
                    askingProjectName: stores.projects.project(id: message.from)?.name,
                    write: { text in
                        // The pasteboard is AppKit state, not model state — the
                        // model stays testable by taking the writer.
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                    }
                )
            },
            onClose: {
                guard let arbitrator = stores.arbitration else { return }
                Task { await model.close(message, using: arbitrator) }
            }
        )
    }

    /// The list's one-line "what am I looking at" caption. It names the SCOPE,
    /// because an all-projects inbox and a single project's inbox can look
    /// identical when there is only traffic between one pair.
    private func scopeCaption(projectID: UUID?) -> String {
        // The all-projects inbox narrowed by the project chip (rail selection or
        // a click) has to SAY so — otherwise a scoped inbox and an empty bus
        // look identical.
        if projectID == nil, let peer = model.peerFilter,
           let name = stores.projects.project(id: peer)?.name {
            return MessagesTabView.filteredCaption(projectName: name)
        }
        guard let projectID, let name = stores.projects.project(id: projectID)?.name else {
            return "Every question between your linked projects · asked and answered by their own sessions"
        }
        return "Questions \(name) asked or was asked · answered by their own sessions, or by you"
    }

    /// The all-projects inbox, narrowed to one project by the chip (testable).
    static func filteredCaption(projectName: String) -> String {
        "Filtered to \(projectName) · click its chip above to see every project again"
    }

    /// "Load older" affordance at the list bottom: grows the window by one page
    /// (design §6 tone). Shown only while older rows remain past the window.
    private func loadOlderRow(shownCount: Int, totalCount: Int) -> some View {
        Button {
            withAnimation(Motion.state) { model.loadMore() }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down")
                    .textStyle(TextStyle(TypeScale.ui(10, .semibold)))
                    .accessibilityHidden(true)
                Text("Load older · showing \(shownCount) of \(totalCount)")
                    .textStyle(TextStyle(TypeScale.ui(12, .semibold)))
            }
            .foregroundStyle(theme.accent)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                    .fill(theme.accentTint(0.08))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help("Load the next \(MessageInboxLogic.pageSize) older questions")
        .accessibilityLabel("Load older questions, showing \(shownCount) of \(totalCount)")
    }

    /// Searchable identity for a participant PROJECT id.
    private func projectLabel(_ id: UUID) -> String {
        stores.projects.projects.first { $0.id == id }?.name ?? ""
    }

    /// The projects the filter chips offer. In a single-project inbox these are
    /// the PEERS it has actually exchanged questions with (derived from the
    /// messages, not the link list, so a chip always narrows to something); in
    /// the all-projects inbox they are every project that appears in the
    /// traffic, so the chip row is "filter by project" outright.
    private func peerProjects(of projectID: UUID?, in messages: [BusMessage]) -> [Project] {
        var ids: Set<UUID>
        if let projectID {
            ids = Set(messages.map { $0.from == projectID ? $0.to : $0.from })
        } else {
            ids = Set(messages.flatMap { [$0.from, $0.to] })
        }
        // Whatever is ACTIVE always gets a chip, traffic or not. Rail selection
        // can scope the inbox to a project with no questions yet;
        // without this the list would come back empty with nothing on screen
        // explaining why, and no chip to click to undo it.
        if let active = model.peerFilter { ids.insert(active) }
        return stores.projects.projects
            .filter { ids.contains($0.id) && $0.id != projectID }
    }

    // MARK: - Chip→card focus (route consumption)

    /// .task(id:) key: re-consume when the request OR the inbox scope changes
    /// (a cross-project route lands before the project's messages do).
    private struct RouteScope: Equatable {
        let route: WorkbenchRouteRequest?
        let projectID: UUID?
    }

    private func consumeRoute(proxy: ScrollViewProxy, projectID: UUID?) {
        guard case .message(let routeProject, let messageID)? = stores.routeRequest else {
            return
        }
        // In a single-project inbox a route to ANOTHER project must wait:
        // WorkbenchView switches selection, and this re-runs via RouteScope
        // once the new project is in place. The all-projects inbox already
        // holds every card, so it consumes any route immediately.
        if let projectID, routeProject != projectID { return }
        let scoped = projectID.map { stores.messages.messages(in: $0) } ?? stores.messages.messages
        guard let message = scoped.first(where: { $0.id == messageID }) else {
            // Unknown/deleted message: consume the request, touch nothing.
            stores.routeRequest = nil
            return
        }
        model.revealIfHidden(message, projectLabel: projectLabel(_:))
        // Grow the window to include the target (it may be an old question below
        // the window) and expand it so the scroll+pulse land on real content.
        let filtered = MessageInboxLogic.apply(
            scoped, query: model.query,
            status: model.statusFilter, peerID: model.peerFilter,
            projectLabel: projectLabel(_:)
        )
        model.focus(
            rank: filtered.firstIndex { $0.id == messageID } ?? -1,
            messageID: messageID
        )
        stores.routeRequest = nil
        // Defer the scroll out of the current update pass — a scrollTo issued
        // inside it is silently dropped (view-discipline field note). The
        // small grace also lets a just-revealed list (filters cleared above)
        // register its ForEach content before the scroll targets it.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(60))
            proxy.scrollTo(message.id, anchor: .center)
            withAnimation(Motion.rise) { highlightedID = message.id }
            try? await Task.sleep(for: .seconds(1.4))
            if highlightedID == message.id {
                withAnimation(.easeOut(duration: 0.6)) { highlightedID = nil }
            }
        }
    }

    // MARK: - Empty states

    /// Every way this list can be empty says something DIFFERENT, and each one
    /// points at the next move: no projects → add one; projects but no links →
    /// link them; linked but quiet → nothing is wrong, wait; filtered to
    /// nothing → clear the filters. A single "no results" would strand a
    /// first-run user on the surface that is supposed to explain the product.
    @ViewBuilder
    private func emptyListState(allCount: Int) -> some View {
        if allCount > 0 {
            filteredToNothingState
        } else if stores.projects.projects.isEmpty {
            emptyMessage("No projects yet. Add a repository in the rail — Dispatch installs "
                         + "its bus into that repo so the session you run there can join.")
        } else if stores.crossProject.links.isEmpty {
            emptyMessage("Nothing is linked yet. Select a project in the rail and press Links… "
                         + "on its card, then link it to another — linking is the consent that "
                         + "lets two repos' sessions ask each other questions.")
        } else {
            emptyMessage("No questions yet. When a session calls ask_agent in one of your "
                         + "linked repos, the question lands here.")
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .textStyle(TextStyle(TypeScale.ui(13)))
            .foregroundStyle(Ink.tertiary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: 460)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 36)
    }

    /// Filters narrowed a non-empty inbox to nothing. Names WHICH filter is
    /// responsible — a status pill hiding everything reads as a broken inbox
    /// unless the copy says otherwise.
    private var filteredToNothingState: some View {
        HStack(spacing: 0) {
            Text(model.query.isEmpty
                 ? "No \(model.statusFilter.rawValue.lowercased()) questions here"
                 : "No questions match ")
                .foregroundStyle(Ink.tertiary)
            if !model.query.isEmpty {
                Text("“\(model.query)”")
                    .textStyle(TextStyle(TypeScale.mono(12.5)))
                    .foregroundStyle(Ink.tertiary)
            }
            Text(" — ")
                .foregroundStyle(Ink.tertiary)
            Button {
                model.clearFilters()
            } label: {
                Text("clear filters")
                    .textStyle(TextStyle(TypeScale.ui(13, .semibold)))
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear search and filters")
        }
        .textStyle(TextStyle(TypeScale.ui(13)))
        .frame(maxWidth: .infinity)
        .padding(.vertical, 36)
    }

    private func emptyPanel(_ message: String) -> some View {
        Text(message)
            .textStyle(TypeScale.caption)
            .foregroundStyle(Ink.faint)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .fill(Surface.white)
            )
            .overlay(
                RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                    .strokeBorder(Surface.hairline)
            )
            .cardShadow()
    }
}

#Preview("Messages tab — mock scenario") {
    let stores = AppStores.mock()
    MessagesTabView()
        .environment(Theme())
        .environment(stores)
        .frame(width: 980, height: 720)
        .background(Theme().canvas)
        .task { await stores.activate() }
}

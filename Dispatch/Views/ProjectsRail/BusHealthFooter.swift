// BusHealthFooter.swift
// The rail's footer: is the switchboard actually up?
//
// Dispatch's one moving part is a localhost HTTP listener. If it is not bound,
// nothing works — no repo's session can reach the bus, and every other surface
// in the app is quietly lying. So the footer states the listener's truth
// (running + port, or DOWN) at all times, and the popover breaks that down per
// project: is this repo's entry installed, and is its session live?
//
// Replaces P2's MCPHealthFooter, which reported the health of AGENTS — a
// concept Dispatch no longer has.

import SwiftUI

struct BusHealthFooter: View {
    @Environment(AppStores.self) private var stores
    @State private var showPopover = false

    private var status: AppStores.BusListenerStatus { stores.busStatus }

    var body: some View {
        Button {
            showPopover.toggle()
        } label: {
            HStack(spacing: 8) {
                Text("BUS")
                    .textStyle(TypeScale.monoMeta)
                    .foregroundStyle(Chrome.sectionLabel)
                Circle()
                    .fill(status.isRunning ? Chrome.dot(for: .success) : Chrome.dot(for: .danger))
                    .frame(width: Metrics.healthDot, height: Metrics.healthDot)
                    .accessibilityHidden(true)  // the label beside it carries the state
                Text(statusLine)
                    .textStyle(TypeScale.monoMeta)
                    .foregroundStyle(Chrome.textMeta)
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14)
            .frame(height: 34)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(helpText)
        .accessibilityLabel("Bus status: \(spokenStatus). Opens per-project detail.")
        .popover(isPresented: $showPopover, arrowEdge: .top) {
            BusHealthPopover()
        }
        // The listener is an actor and the port is settled asynchronously
        // during launch; a single read at activation can land before the bind.
        // A slow poll keeps the footer honest without a notification seam for
        // one label.
        .task {
            while !Task.isCancelled {
                await stores.refreshBusStatus()
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private var statusLine: String {
        guard let port = status.port else { return "not running" }
        return "127.0.0.1:\(port)"
    }

    private var spokenStatus: String {
        status.isRunning
            ? "running on port \(status.port ?? 0), \(status.installedCount) of \(status.projectCount) repos installed"
            : "not running — no repo can reach the bus"
    }

    private var helpText: String {
        status.isRunning
            ? "The bus is listening on 127.0.0.1:\(status.port ?? 0). Each linked repo's .mcp.json points at it."
            : "The bus listener isn't bound — no repo's session can reach Dispatch."
    }
}

private struct BusHealthPopover: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("SWITCHBOARD")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
            listenerLine
            Rectangle().fill(Chrome.cardBorder).frame(height: 1)
                .padding(.vertical, 2)
            Text("PROJECTS ON THE BUS")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Chrome.sectionLabel)
            if stores.projects.projects.isEmpty {
                Text("No projects yet — add one to put it on the bus.")
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Chrome.textMeta)
            } else {
                ForEach(stores.projects.projects) { project in
                    row(for: project)
                }
            }
        }
        .padding(14)
        .frame(width: 330, alignment: .leading)
        // Dark chrome popover (v3 Obsidian): solid `Chrome.popover` fill, a
        // hairline border, and the deep dark shadow.
        .background(Chrome.popover)
        .overlay(
            RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous)
                .strokeBorder(Chrome.popoverBorder)
        )
        .clipShape(RoundedRectangle(cornerRadius: Metrics.radiusPanel, style: .continuous))
        .darkPopoverShadow()
    }

    @ViewBuilder
    private var listenerLine: some View {
        let status = stores.busStatus
        VStack(alignment: .leading, spacing: 2) {
            Text(status.isRunning
                 ? "Listening on 127.0.0.1:\(status.port ?? 0)"
                 : "Listener not running")
                .textStyle(TypeScale.control)
                .foregroundStyle(Chrome.text)
            Text(status.isRunning
                 ? "\(status.installedCount) of \(status.projectCount) repos have the dispatch entry installed."
                 : "No repo's Claude Code session can reach Dispatch until this binds.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Chrome.textMeta)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }

    private func row(for project: Project) -> some View {
        let connection = stores.connection(for: project.id)
        let install = stores.repoInstallStates[project.id]
        return HStack(spacing: 8) {
            Circle()
                .fill(connection.isConnected ? Chrome.dot(for: .success) : Chrome.textDisabled)
                .frame(width: Metrics.healthDot, height: Metrics.healthDot)
                .accessibilityHidden(true)  // the status line below carries the state
            VStack(alignment: .leading, spacing: 1) {
                Text(project.name)
                    .textStyle(TypeScale.control)
                    .foregroundStyle(Chrome.text)
                Text(ProjectCardView.connectionLabel(connection))
                    .textStyle(TypeScale.monoMeta)
                    .foregroundStyle(Chrome.textMeta)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            installChip(install)
        }
        .accessibilityElement(children: .combine)
    }

    /// Only a NON-installed repo gets a chip here — "installed" is the quiet
    /// default, and a green badge on every healthy row would bury the one that
    /// needs work. The Fix action is the same rotate-and-rewrite the card's
    /// context menu offers, because that is the only repair Dispatch can make.
    @ViewBuilder
    private func installChip(_ state: RepoMCPConfig.InstallState?) -> some View {
        switch state {
        case .installed, nil:
            EmptyView()
        default:
            Chip(state == .missing ? "not installed" : "needs repair",
                 style: .statusDark(Chrome.amberPill), mono: true)
                .fixedSize()
                .help("This repo's .mcp.json doesn't carry a working dispatch entry.")
        }
    }
}

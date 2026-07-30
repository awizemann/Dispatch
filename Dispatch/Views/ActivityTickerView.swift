// ActivityTickerView.swift
// Activity ticker (34pt, white, design §8): a liveness dot + the latest bus
// event (mono 10.5) + the 10-minute events/min sparkline (§8a "activity
// heartbeat") + "All activity ▴", which opens the recent feed.
//
// P5 made the feed button real. It had been a stub since the design phase —
// a control that visibly did nothing on every click.

import SwiftUI

struct ActivityTickerView: View {
    @Environment(Theme.self) private var theme
    @Environment(AppStores.self) private var stores
    @State private var showFeed = false

    /// Sparkline geometry: ten 1-minute bars, tiny per the design.
    private static let barCount = 10
    private static let barWidth: CGFloat = 3
    private static let barMaxHeight: CGFloat = 12
    private static let barMinHeight: CGFloat = 2.5

    var body: some View {
        HStack(spacing: 10) {
            // Green and blinking only when the bus is actually up — a liveness
            // dot that pulses through a dead listener is a lie.
            Circle()
                .fill(stores.busStatus.isRunning ? Status.successDot : Ink.faint)
                .frame(width: Metrics.statusDot, height: Metrics.statusDot)
                .modifier(BlinkWhenLive(isLive: stores.busStatus.isRunning))
                .accessibilityHidden(true)
            Text(latestText)
                .textStyle(TextStyle(TypeScale.mono(10.5)))
                .foregroundStyle(Ink.mutedMono)
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 12)
            sparkline
            Button {
                showFeed.toggle()
            } label: {
                Text("All activity ▴")
                    .textStyle(TextStyle(TypeScale.ui(11.5, .semibold)))
                    .foregroundStyle(theme.accent)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Show recent bus activity")
            .accessibilityLabel("Show recent bus activity")
            .popover(isPresented: $showFeed, arrowEdge: .top) {
                ActivityFeedPopover()
            }
        }
        .padding(.horizontal, Metrics.surfacePadding)
        .frame(height: Metrics.tickerHeight)
        .frame(maxWidth: .infinity)
        .background(Surface.white)
        .overlay(alignment: .top) {
            Rectangle().fill(Surface.hairline).frame(height: 1)
        }
    }

    private var latestText: String {
        guard let projectID = stores.projects.selectedProjectID,
              let latest = stores.activity.latest(for: projectID) else {
            return stores.busStatus.isRunning
                ? "quiet — no activity yet"
                : "bus not running — no repo can reach Dispatch"
        }
        return latest.text
    }

    // MARK: - Events/min sparkline (§8a "activity heartbeat")

    /// Ten 1-minute bars over the last 10 minutes of ActivityStore events —
    /// accent when the minute saw activity, a faint stub otherwise. Decorative
    /// by design: the ticker TEXT carries the meaning, so the whole cluster is
    /// accessibilityHidden.
    ///
    /// Derivation, not state: bars re-bucket from the observed store on every
    /// render (new activity re-renders this view via @Observable). The ONLY
    /// timer is TimelineView's 1-minute cadence, needed because buckets are
    /// wall-clock minutes — without it a quiet stretch would freeze stale bars
    /// (an event from 11 minutes ago would keep reading "1 minute ago"). The
    /// periodic re-render is scoped to THIS tiny subtree, and a static bar row
    /// re-render carries no continuous animation (containment is moot: nothing
    /// here animates, and the cluster is a11y-hidden regardless).
    private var sparkline: some View {
        TimelineView(.periodic(from: .now, by: 60)) { context in
            let counts = bucketCounts(now: context.date)
            // Empty window (no project selected, or zero events in the last 10
            // minutes) → render nothing so the slot collapses, rather than ten
            // faint stub bars. The presence check reads the SAME buckets the bars
            // render from, so visibility and heights can never disagree; the 60s
            // tick re-evaluates it as the window slides (an event aging past 10
            // minutes drops the sparkline back out, matching the bars' decay).
            if counts.contains(where: { $0 > 0 }) {
                sparklineBars(counts: counts)
            }
        }
        .accessibilityHidden(true)
    }

    private func sparklineBars(counts: [Int]) -> some View {
        let peak = max(counts.max() ?? 0, 1)
        return HStack(alignment: .bottom, spacing: 1.5) {
            // Positional identity is correct here: exactly 10 slots, oldest
            // first; bars are anonymous minutes, not tracked entities.
            ForEach(0..<Self.barCount, id: \.self) { index in
                let count = counts[index]
                RoundedRectangle(cornerRadius: 1, style: .continuous)
                    .fill(count > 0 ? theme.accent : Surface.controlBorder)
                    .frame(width: Self.barWidth, height: barHeight(count: count, peak: peak))
            }
        }
        .frame(height: Self.barMaxHeight, alignment: .bottom)
    }

    /// Zero → a faint fixed stub; non-zero scales linearly against the
    /// window's peak minute (floor keeps a 1-event minute visible).
    private func barHeight(count: Int, peak: Int) -> CGFloat {
        guard count > 0 else { return Self.barMinHeight }
        let scaled = Self.barMaxHeight * CGFloat(count) / CGFloat(peak)
        return max(scaled, Self.barMinHeight + 1.5)
    }

    private func bucketCounts(now: Date) -> [Int] {
        guard let projectID = stores.projects.selectedProjectID else {
            return [Int](repeating: 0, count: Self.barCount)
        }
        return ActivityStore.sparklineBuckets(
            times: stores.activity.events(in: projectID).map(\.time),
            now: now, bucketCount: Self.barCount
        )
    }
}

// MARK: - Liveness blink

/// The ticker dot blinks ONLY while the bus is up. Wrapping the modifier in a
/// conditional branch (rather than an `enabled:` parameter on the shared
/// modifier) keeps the `.repeatForever` animation from being installed at all
/// when there is nothing live to represent.
private struct BlinkWhenLive: ViewModifier {
    let isLive: Bool

    func body(content: Content) -> some View {
        if isLive {
            content.workingDotsBlink()
        } else {
            content
        }
    }
}

// MARK: - Recent activity (the "All activity" feed)

/// The ticker shows the newest line; this shows the last N. Scoped to the
/// selected project for the same reason the ticker is: it is that project's
/// story, and an app-wide firehose would bury it.
private struct ActivityFeedPopover: View {
    @Environment(AppStores.self) private var stores

    /// Deep enough to cover a working session, short enough to scan.
    private static let limit = 40

    private var events: [ActivityEvent] {
        guard let projectID = stores.projects.selectedProjectID else { return [] }
        return Array(
            stores.activity.events(in: projectID)
                .sorted { $0.time > $1.time }
                .prefix(Self.limit)
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT ACTIVITY")
                .textStyle(TypeScale.sectionLabel)
                .foregroundStyle(Ink.tertiary)
            if events.isEmpty {
                Text("Nothing yet. Questions, answers and sessions joining the bus show up here.")
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(events) { event in
                            row(event)
                        }
                    }
                }
                .frame(maxHeight: 260)
            }
        }
        .padding(14)
        .frame(width: 380, alignment: .leading)
        .background(Surface.white)
    }

    private func row(_ event: ActivityEvent) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(event.time, format: .relative(presentation: .named))
                .textStyle(TypeScale.monoMeta)
                .foregroundStyle(Ink.faint)
            Text(event.text)
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

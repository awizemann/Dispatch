// SettingsNotificationsPane.swift
// Settings → Notifications: one row per BUS EVENT, in both registers — a sound
// while you're here, a macOS banner while you're not. @Default live-reads so a
// flip applies immediately (SoundPlayer and NotificationPoster both read these
// keys at use time, never at construction).
//
// P5 pruned the rows that named demolished subsystems: the "needs your eyes"
// chime, the critical-agent alert, human-action banners and usage-limit
// banners all described the agent runtime removed in P2, and nothing had fired
// them since.

import Defaults
import SwiftUI

struct SettingsNotificationsPane: View {
    @Environment(AppStores.self) private var stores
    @Default(.notificationSoundsEnabled) private var soundsEnabled
    @Default(.notificationQuestionSoundEnabled) private var questionSound
    @Default(.notificationAnswerSoundEnabled) private var answerSound
    @Default(.notificationSoundVolume) private var soundVolume
    @Default(.busQuestionNotificationsEnabled) private var questionBanners
    @Default(.busAnswerNotificationsEnabled) private var answerBanners
    @Default(.busExpiryNotificationsEnabled) private var expiryBanners

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    soundsSection
                    systemSection
                }
                .padding(.vertical, 2)
            }
        }
        .task { await stores.notificationPoster?.refreshAuthorizationState() }
    }

    // MARK: - System notifications

    private var systemSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("SYSTEM NOTIFICATIONS")
            Text("Only while Dispatch is in the background — the ticker and the badge "
                 + "already cover you when it's in front. macOS asks for permission on "
                 + "the first banner.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.tertiary)
                .fixedSize(horizontal: false, vertical: true)
            deniedNote
            SettingsToggleRow(
                title: "A project asked a question",
                caption: "One project asked another something on the bus.",
                isOn: $questionBanners
            )
            SettingsToggleRow(
                title: "An answer landed",
                caption: "A session answered a question. Your own answers never notify you.",
                isOn: $answerBanners
            )
            SettingsToggleRow(
                title: "A question closed unanswered",
                caption: "A question timed out, or was closed without an answer.",
                isOn: $expiryBanners
            )
        }
    }

    /// macOS is refusing banners. The toggles below still record a preference,
    /// but nothing will be delivered until the human changes it in System
    /// Settings — Dispatch cannot re-ask (macOS shows that dialog once), so the
    /// honest move is to say so and point at the one place it can be fixed.
    @ViewBuilder
    private var deniedNote: some View {
        if stores.notificationPoster?.isAuthorized == false {
            Text("macOS is blocking Dispatch's notifications, so these stay off no matter what "
                 + "you set here. Turn them on in System Settings → Notifications → Dispatch.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Status.warningInk)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: Metrics.radiusControl, style: .continuous)
                        .fill(Status.warningTint)
                )
                .accessibilityLabel("macOS is blocking Dispatch's notifications. "
                                    + "Enable them in System Settings, Notifications, Dispatch.")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Notifications")
                .textStyle(TypeScale.panelTitle)
                .foregroundStyle(Ink.primary)
            Text("How Dispatch tells you what the bus did. Changes apply immediately.")
                .textStyle(TypeScale.caption)
                .foregroundStyle(Ink.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - Sounds

    private var soundsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            SettingsSectionLabel("SOUNDS")
            SettingsToggleRow(
                title: "Notification sounds",
                caption: "Master switch for every app sound.",
                isOn: $soundsEnabled
            )
            SettingsToggleRow(
                title: "Question arrives",
                caption: "Play a whoosh when a project asks another a question.",
                isOn: $questionSound,
                disabled: !soundsEnabled
            )
            SettingsToggleRow(
                title: "Answer lands",
                caption: "Play a chime when a session answers a question.",
                isOn: $answerSound,
                disabled: !soundsEnabled
            )
            SettingsSliderRow(
                title: "Volume",
                caption: "Applies to every app sound.",
                value: $soundVolume,
                disabled: !soundsEnabled
            )
        }
    }

}

// MARK: - Shared settings rows (reused by General)

/// A small-caps section header used across the toggle-list Settings panes.
struct SettingsSectionLabel: View {
    let title: String
    init(_ title: String) { self.title = title }

    var body: some View {
        Text(title)
            .textStyle(TypeScale.sectionLabel)
            .foregroundStyle(Ink.tertiary)
    }
}

/// A titled toggle row (title + caption on the left, switch on the right).
/// `disabled` dims and blocks the row while a parent toggle is off, but its
/// stored value is preserved (re-enabling the parent restores it).
struct SettingsToggleRow: View {
    let title: String
    let caption: String
    @Binding var isOn: Bool
    var disabled: Bool = false

    var body: some View {
        // Spacer + labelsHidden, not `Toggle { label }`: the built-in layout
        // puts the switch immediately after each row's text, so a column of
        // rows with different caption lengths gets a ragged right edge. The
        // switches must line up — and this matches SettingsSliderRow.
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(TypeScale.cardTitle)
                    .foregroundStyle(Ink.primary)
                Text(caption)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityHint(caption)
    }
}

/// A titled slider row (title + caption on the left, 0…1 slider + percent on
/// the right) matching SettingsToggleRow's layout. Releasing the thumb plays
/// the notification sound at the new level so the volume is audible while
/// setting it (the preview respects the same Settings gates as any play).
struct SettingsSliderRow: View {
    let title: String
    let caption: String
    @Binding var value: Double
    var disabled: Bool = false

    /// One preloaded player for the release preview — static so repeated
    /// Settings visits don't reload the assets.
    private static let preview = SoundPlayer()

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .textStyle(TypeScale.cardTitle)
                    .foregroundStyle(Ink.primary)
                Text(caption)
                    .textStyle(TypeScale.caption)
                    .foregroundStyle(Ink.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Slider(value: $value, in: 0...1) { editing in
                if !editing { Self.preview.play(.answer) }
            }
            .controlSize(.small)
            .frame(width: 140)
            Text("\(Int((value * 100).rounded()))%")
                .textStyle(TypeScale.caption)
                .monospacedDigit()
                .foregroundStyle(Ink.secondary)
                .frame(width: 36, alignment: .trailing)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.5 : 1)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
        .accessibilityHint(caption)
    }
}

#Preview("Settings — notifications (mock)") {
    ZStack {
        Color.gray.opacity(0.3).ignoresSafeArea()
        SettingsModalView()
    }
    .environment(Theme())
    .environment({ () -> AppStores in
        let stores = AppStores.mock()
        stores.settingsRoute = .notifications
        return stores
    }())
    .frame(width: 900, height: 640)
}

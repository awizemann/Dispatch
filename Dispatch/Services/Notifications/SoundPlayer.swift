// SoundPlayer.swift
// The app-bundled feedback sounds: distinct sounds per signal class, each
// app-owned bundled audio — deliberately NOT system sounds (NSSound(named:))
// so the app owns its own voice and the Settings → Notifications surface
// governs it.
//
// Split of concerns: the CALLER owns *when* to play (AppStores' bus-event
// fan-out, which already knows an event is real and new); this player is a
// dumb "play now". It only self-censors on the Defaults keys (master + the
// sound's own toggle), applies the shared volume, and no-ops on a missing
// asset — never on timing.

import AVFoundation
import Defaults
import Foundation
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "sound")

/// The app's feedback sounds. Raw value = the bundled asset's basename
/// (<rawValue>.mp3 in Resources), titled to where each applies.
nonisolated enum AppSound: String, CaseIterable, Sendable {
    /// A question arrived on the bus. Asset basename `buscomm.mp3` — the
    /// FILE name is frozen (it ships in the bundle); the case is named for the
    /// signal, not the file.
    case question = "buscomm"
    /// An answer landed. Asset basename `notification.mp3`.
    case answer = "notification"

    /// The per-sound Settings toggle, checked under the master key.
    /// @MainActor because the Defaults keys are (default isolation).
    @MainActor var enabledKey: Defaults.Key<Bool> {
        switch self {
        case .question: .notificationQuestionSoundEnabled
        case .answer: .notificationAnswerSoundEnabled
        }
    }
}

/// The play-now seam the stores depend on. MainActor-bound: the caller is the
/// @MainActor composition root, and AVAudioPlayer is not Sendable — pinning the
/// player to the main actor is both correct and matches how it's used. A test
/// spy conforms the same way.
@MainActor
protocol SoundPlaying: AnyObject {
    /// Play the given sound now, if the user's sound settings allow it. A
    /// no-op when sounds are disabled or the asset is missing.
    func play(_ sound: AppSound)
}

/// The real player: preloads and RETAINS one AVAudioPlayer per bundled sound.
/// Retaining them as properties is load-bearing — a player created as a local
/// deallocates the instant the function returns, cutting the sound off before
/// it's heard (known AVAudioPlayer pitfall).
@MainActor
final class SoundPlayer: SoundPlaying {
    /// Missing/failed assets are absent — play(_:) then no-ops for that sound
    /// (logged once at construction, not per call).
    private let players: [AppSound: AVAudioPlayer]

    init(bundle: Bundle = .main) {
        var players: [AppSound: AVAudioPlayer] = [:]
        for sound in AppSound.allCases {
            guard let url = bundle.url(forResource: sound.rawValue, withExtension: "mp3") else {
                logger.error("\(sound.rawValue, privacy: .public).mp3 missing from bundle — sound disabled")
                continue
            }
            do {
                let player = try AVAudioPlayer(contentsOf: url)
                player.prepareToPlay()
                players[sound] = player
            } catch {
                logger.error("\(sound.rawValue, privacy: .public).mp3 load failed: \(String(describing: error), privacy: .public)")
            }
        }
        self.players = players
    }

    func play(_ sound: AppSound) {
        guard Defaults[.notificationSoundsEnabled],
              Defaults[sound.enabledKey] else { return }
        guard let player = players[sound] else { return }
        // Shared volume, read at play time so the Settings slider applies
        // immediately (0…1; clamped against a hand-edited Defaults plist).
        player.volume = Float(min(max(Defaults[.notificationSoundVolume], 0), 1))
        player.currentTime = 0
        player.play()
    }
}

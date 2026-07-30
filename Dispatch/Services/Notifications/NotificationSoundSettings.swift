// NotificationSoundSettings.swift
// Defaults-backed keys that govern the app-bundled feedback sounds. Global, in
// the BusSettings.swift pattern; SoundPlayer reads every key at PLAY time so a
// Settings flip applies immediately, no code change.
//
// P5 pruned these to the two signals the switchboard actually has — a question
// arriving and an answer landing. The old "needs your eyes" chime and critical
// alert belonged to the agent-runtime subsystems demolished in P2, and nothing
// has played them since.

import Defaults
import Foundation

extension Defaults.Keys {
    /// Master switch for ALL app notification sounds. false → silent app,
    /// regardless of the per-sound keys below (checked first in SoundPlayer).
    static let notificationSoundsEnabled = Key<Bool>("notificationSoundsEnabled", default: true)

    /// One project asked another a question. Gated by the master key.
    static let notificationQuestionSoundEnabled = Key<Bool>(
        "notificationQuestionSoundEnabled", default: true
    )

    /// An answer landed on the bus. Gated by the master key.
    static let notificationAnswerSoundEnabled = Key<Bool>(
        "notificationAnswerSoundEnabled", default: true
    )

    /// Shared volume for every app sound, 0.0…1.0 (one slider, not per-sound).
    /// Applied by SoundPlayer at play time.
    static let notificationSoundVolume = Key<Double>("notificationSoundVolume", default: 1.0)
}

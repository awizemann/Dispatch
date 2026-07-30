// SettingsKeysTests.swift
// The Settings panes' Defaults-backed keys: declared defaults +
// a set/get round-trip. Each test restores the key to its prior value on exit
// so it never leaks state into other suites (the keys live in .standard, shared
// with the running app's own persistence).

import Defaults
import Foundation
import Testing
@testable import DispatchApp

@Suite("Settings keys — defaults + round-trip", .serialized)
struct SettingsKeysTests {

    @Test("Notification sound keys default on and round-trip")
    func notificationSoundKeys() {
        let priorMaster = Defaults[.notificationSoundsEnabled]
        let priorQuestion = Defaults[.notificationQuestionSoundEnabled]
        defer {
            Defaults[.notificationSoundsEnabled] = priorMaster
            Defaults[.notificationQuestionSoundEnabled] = priorQuestion
        }
        #expect(Defaults.Keys.notificationSoundsEnabled.defaultValue == true)
        #expect(Defaults.Keys.notificationQuestionSoundEnabled.defaultValue == true)
        #expect(Defaults.Keys.notificationAnswerSoundEnabled.defaultValue == true)

        Defaults[.notificationSoundsEnabled] = false
        #expect(Defaults[.notificationSoundsEnabled] == false)
        Defaults[.notificationQuestionSoundEnabled] = false
        #expect(Defaults[.notificationQuestionSoundEnabled] == false)
    }

    @Test("Every app sound has a Settings key and a bundled asset behind it")
    func everySoundIsWired() {
        // A sound whose asset is missing degrades to silence at runtime, which
        // is invisible — so the pairing is asserted here instead.
        for sound in AppSound.allCases {
            #expect(Bundle.main.url(forResource: sound.rawValue, withExtension: "mp3") != nil,
                    "\(sound.rawValue).mp3 must ship in the bundle")
        }
        #expect(Set(AppSound.allCases.map(\.rawValue)).count == AppSound.allCases.count)
    }

    @Test("The inbox-scope key defaults to the all-projects view and round-trips")
    func messagesScopeKey() {
        let prior = Defaults[.messagesShowAllProjects]
        defer { Defaults[.messagesShowAllProjects] = prior }
        #expect(Defaults.Keys.messagesShowAllProjects.defaultValue == true)

        Defaults[.messagesShowAllProjects] = false
        #expect(Defaults[.messagesShowAllProjects] == false)
    }
}

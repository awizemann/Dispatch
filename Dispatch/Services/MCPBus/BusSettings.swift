// BusSettings.swift
// Defaults-backed switchboard settings — global, not per-project (the bus is
// one listener for the whole app).
//
// P5 retired `agentsAutoAnswerBus`. It described the demolished agent runtime,
// where Dispatch itself decided whether an agent or the human answered. Nothing
// has read it since P2: the sessions on the other end are the user's OWN Claude
// Code sessions, so whether one answers is theirs to decide, not a toggle here.

import Defaults
import Foundation

extension Defaults.Keys {
    /// The port the bus listener last bound (P4 stable port). 0 = never bound.
    /// On launch we try to RE-BIND this exact port so every `.mcp.json` entry
    /// already on disk keeps resolving; a bind failure falls back to a fresh
    /// kernel-assigned port and every project's entry is rewritten.
    static let busListenerPort = Key<Int>("busListenerPort", default: 0)

    /// Messages tab scope: true → one inbox across every project, false → only
    /// the project selected in the rail. Default ON, because the switchboard's
    /// whole job is traffic BETWEEN projects — a per-project inbox makes the
    /// human hunt for the question they were just notified about.
    static let messagesShowAllProjects = Key<Bool>("messagesShowAllProjects", default: true)
}

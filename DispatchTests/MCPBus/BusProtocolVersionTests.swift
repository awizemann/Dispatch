// BusProtocolVersionTests.swift
// Version + snapshot + word-budget lock for the agent-facing bus protocol TEXT:
// the ONE prompt surface an external Claude Code session reads,
// BusPromptFraming.protocolSection. The point is that a prompt-behavior change
// can never be a silent diff:
//   • the SNAPSHOT test locks each section's full text by SHA-256 — any wording
//     edit changes the digest and fails, until the digest is updated AND
//     BusProtocolText.protocolVersion is bumped in the same change;
//   • the BUDGET test caps each section's word count at its current count plus
//     ~5% headroom, so a section can only grow by a DELIBERATE ceiling bump,
//     never by silent accretion.
//
// To reland after an INTENTIONAL edit: run once, copy the reported digest into
// `expectedDigests`, bump protocolVersion (MINOR = wording, MAJOR = semantics),
// and raise the ceiling only if the growth is deliberate.

import CryptoKit
import Foundation
import Testing
@testable import DispatchApp

@Suite("Bus protocol text: version + snapshot + word budget")
struct BusProtocolVersionTests {

    /// One locked prompt surface: a stable name, its live assembled text, and
    /// the word ceiling (current count + ~5%).
    private struct Section {
        let name: String
        let text: String
        let ceiling: Int
    }

    /// Every distinct surface an external session can read. There is exactly
    /// ONE protocol section: the bus caller is a project, not a role, so there
    /// is nothing to split by role. protocolVersion holds at 12.0.0.
    private static let sections: [Section] = [
        .init(name: "protocolSection",
              text: BusPromptFraming.protocolSection, ceiling: 383),
    ]

    /// SHA-256 (hex) of each section's full text at the current protocolVersion.
    private static let expectedDigests: [String: String] = [
        "protocolSection": "49f56cd93675213985b7b26ba36d18d45785e53c790ea0f8d20333a289566d88",
    ]

    private static func sha256Hex(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0.isWhitespace }).count
    }

    @Test("protocol version is a valid semver and the pinned baseline")
    func versionBaseline() {
        let parts = BusProtocolText.protocolVersion.split(separator: ".")
        #expect(parts.count == 3, "protocolVersion must be MAJOR.MINOR.PATCH semver")
        #expect(parts.allSatisfy { Int($0) != nil }, "each semver component is numeric")
        // 12.0.0: the protocol addresses a single actor — an external session
        // speaking for a whole PROJECT, with four verbs and no work lifecycle.
        #expect(BusProtocolText.protocolVersion == "12.0.0")
    }

    @Test("every locked section matches its text snapshot for the current version")
    func snapshotLock() throws {
        for section in Self.sections {
            let actual = Self.sha256Hex(section.text)
            let expected = try #require(Self.expectedDigests[section.name],
                                        "\(section.name) has no stored digest — add one")
            #expect(actual == expected,
                    "\(section.name) text changed at version \(BusProtocolText.protocolVersion). If intentional: set its digest to \(actual) and bump BusProtocolText.protocolVersion (MINOR = wording, MAJOR = semantics).")
        }
    }

    @Test("every locked section stays within its word budget")
    func wordBudget() {
        for section in Self.sections {
            let count = Self.wordCount(section.text)
            #expect(count <= section.ceiling,
                    "\(section.name) is \(count) words, over its \(section.ceiling) ceiling — tighten it, or raise the ceiling deliberately (and bump protocolVersion).")
        }
    }
}

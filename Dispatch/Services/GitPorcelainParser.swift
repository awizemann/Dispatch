// GitPorcelainParser.swift
// Typed parser for `git status --porcelain=v2 --branch` output. Pure string →
// struct: no subprocess, no Foundation side effects — unit-tested against
// fixture strings (GitPorcelainParserTests).
//
// Format reference (git-status(1), porcelain v2):
//   # branch.oid <oid | (initial)>
//   # branch.head <name | (detached)>
//   # branch.upstream <remote/branch>            (only when an upstream is set)
//   # branch.ab +<ahead> -<behind>               (only when an upstream is set)
//   1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>                    changed
//   2 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <X><score> <path>\t<orig> rename/copy
//   u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>          unmerged
//   ? <path>                                                        untracked
//   ! <path>                                                        ignored
//
// v1 parses the newline-separated (non `-z`) form: paths containing unusual
// characters arrive C-quoted, which is fine because the app only *counts*
// entries today. Switch to `-z` parsing before any per-path display.

import Foundation

nonisolated enum GitPorcelainParser {

    // MARK: - Output types

    struct Status: Equatable, Sendable {
        /// `# branch.head` — "(detached)" when HEAD is detached.
        var branchHead: String?
        /// `# branch.oid` — "(initial)" on an unborn branch (no commits yet).
        var branchOID: String?
        /// `# branch.upstream` — nil when no upstream is configured.
        var upstream: String?
        /// `# branch.ab` ahead count — nil when no upstream is configured.
        var ahead: Int?
        /// `# branch.ab` behind count (absolute value).
        var behind: Int?
        var entries: [Entry] = []

        var isDetached: Bool { branchHead == "(detached)" }
        var isUnborn: Bool { branchOID == "(initial)" }
        /// Ignored entries are not dirt; everything else is.
        var dirtyCount: Int { entries.count { $0.kind != .ignored } }
        var isClean: Bool { dirtyCount == 0 }
    }

    struct Entry: Equatable, Sendable {
        enum Kind: Equatable, Sendable {
            case changed, renamedOrCopied, unmerged, untracked, ignored
        }

        var kind: Kind
        /// Two-character XY status field; nil for untracked/ignored lines.
        var xy: String?
        var path: String
        /// Rename/copy source path.
        var originalPath: String?
    }

    // MARK: - Parsing

    static func parse(_ text: String) -> Status {
        var status = Status()
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            parseLine(line, into: &status)
        }
        return status
    }

    private static func parseLine(_ line: Substring, into status: inout Status) {
        switch line.first {
        case "#":
            parseHeader(line, into: &status)
        case "1":
            // 1 <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path> — path is field 8
            // and may contain spaces (maxSplits keeps it whole).
            let fields = line.split(separator: " ", maxSplits: 8, omittingEmptySubsequences: false)
            guard fields.count == 9 else { return }
            status.entries.append(Entry(kind: .changed, xy: String(fields[1]), path: String(fields[8])))
        case "2":
            // 2 ... <X><score> <path>\t<origPath>
            let fields = line.split(separator: " ", maxSplits: 9, omittingEmptySubsequences: false)
            guard fields.count == 10 else { return }
            let paths = fields[9].split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard paths.count == 2 else { return }
            status.entries.append(Entry(
                kind: .renamedOrCopied, xy: String(fields[1]),
                path: String(paths[0]), originalPath: String(paths[1])
            ))
        case "u":
            // u <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
            let fields = line.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false)
            guard fields.count == 11 else { return }
            status.entries.append(Entry(kind: .unmerged, xy: String(fields[1]), path: String(fields[10])))
        case "?":
            guard line.count > 2 else { return }
            status.entries.append(Entry(kind: .untracked, xy: nil, path: String(line.dropFirst(2))))
        case "!":
            guard line.count > 2 else { return }
            status.entries.append(Entry(kind: .ignored, xy: nil, path: String(line.dropFirst(2))))
        default:
            // Unknown line kinds (future git versions) are skipped by design.
            return
        }
    }

    private static func parseHeader(_ line: Substring, into status: inout Status) {
        // "# branch.head main" → key "branch.head", value "main".
        let fields = line.dropFirst(2).split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
        guard fields.count == 2 else { return }
        let value = String(fields[1])
        switch fields[0] {
        case "branch.oid": status.branchOID = value
        case "branch.head": status.branchHead = value
        case "branch.upstream": status.upstream = value
        case "branch.ab":
            // "+3 -1"
            let counts = value.split(separator: " ")
            guard counts.count == 2 else { return }
            status.ahead = Int(counts[0].dropFirst())          // strip '+'
            status.behind = Int(counts[1].dropFirst()).map(abs) // strip '-'
        default:
            return // e.g. "# stash N" — irrelevant here
        }
    }
}

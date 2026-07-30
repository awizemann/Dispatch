// BusEventText.swift
// The ONE place the product's event vocabulary is written down.
//
// A bus event is announced in two registers — a one-line activity-ticker entry
// and (when the human is away) a system notification. Both are derived here,
// from the same event, so the ticker and the banner can never describe the same
// fact differently. Pure and name-injected: no store, no notification centre,
// directly unit-testable.

import Foundation

nonisolated enum BusEventText {

    /// Fallback for a participant whose project row is gone (deleted mid-flight).
    static let unknownProject = "a removed project"

    /// Quoted, length-capped subject — a question's subject is derived from its
    /// first line and can be long; a ticker line and a banner title are not.
    static func quoted(_ subject: String, limit: Int = 60) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        let clipped = trimmed.count > limit
            ? String(trimmed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
            : trimmed
        return "“\(clipped)”"
    }

    // MARK: - Activity ticker

    /// One ticker line for an event. `name` resolves a participant project id.
    static func tickerLine(for event: BusEvent, name: (UUID) -> String?) -> String {
        func label(_ id: UUID) -> String { name(id) ?? unknownProject }
        switch event {
        case .asked(let message):
            return "\(label(message.from)) asks \(label(message.to)) · \(quoted(message.subject))"
        case .answered(let message):
            return message.answeredByHuman
                ? "You answered \(quoted(message.subject)) · arbitration"
                : "\(label(message.to)) answered \(label(message.from)) · \(quoted(message.subject))"
        case .closed(let message):
            let reason = message.closedReason ?? "closed without an answer"
            return "\(quoted(message.subject)) closed — \(reason)"
        case .connected(let projectID):
            return "\(label(projectID)) connected to the bus"
        case .disconnected(let projectID):
            return "\(label(projectID)) left the bus"
        }
    }

    // MARK: - System notifications

    /// Title + body for a banner, or nil when the event is not worth
    /// interrupting a human for. Connect/disconnect deliberately return nil:
    /// they are ambient facts (a session starting up), not news that needs
    /// hands — the ticker carries them and the rail's live dot shows them.
    ///
    /// The human's OWN arbitration answer returns nil too: they just typed it.
    static func notification(
        for event: BusEvent, name: (UUID) -> String?
    ) -> (id: String, title: String, body: String)? {
        func label(_ id: UUID) -> String { name(id) ?? unknownProject }
        switch event {
        case .asked(let message):
            return (id: "bus-asked-\(message.id)",
                    title: "\(label(message.from)) asked \(label(message.to)) a question",
                    body: message.subject)
        case .answered(let message):
            guard !message.answeredByHuman else { return nil }
            return (id: "bus-answered-\(message.id)",
                    title: "\(label(message.to)) answered \(label(message.from))",
                    body: message.answer ?? message.subject)
        case .closed(let message):
            return (id: "bus-closed-\(message.id)",
                    title: "A question closed without an answer",
                    body: "\(label(message.from)) → \(label(message.to)): \(message.subject)")
        case .connected, .disconnected:
            return nil
        }
    }

    // MARK: - Nudge snippet (Messages tab)

    /// The copy-to-clipboard nudge. Dispatch cannot push into somebody else's
    /// terminal session — the only honest "poke" is a line the human pastes
    /// into that repo's Claude Code session, so it is written as an instruction
    /// TO that session, naming the tool it needs to call.
    static func nudgeSnippet(
        for message: BusMessage, askingProjectName: String?
    ) -> String {
        let asker = askingProjectName ?? unknownProject
        return "Check your dispatch inbox — call the dispatch MCP server's "
            + "`check_messages` tool. \(asker) is waiting on an answer to "
            + "\(quoted(message.subject, limit: 120)) (question id \(message.id))."
    }
}

// BusArbitration.swift
// The Messages tab's write seam for human arbitration (guardrail §11: any open
// question can always be answered by the human). The mock scenario and tests
// inject fakes, so the inbox — Answer flow included — stays fully exercisable
// without the MCP bus. DispatchRouter is the live conformer.

import Foundation

@MainActor
protocol BusArbitrating: AnyObject {
    /// Records an answer to a pending question. The Messages tab always passes
    /// `byHuman: true` → the card renders "↳ You answered · arbitration".
    /// Throws BusToolFailure on conflict.
    func answer(messageID: String, text: String, byHuman: Bool) async throws

    /// Closes a pending question WITHOUT an answer — the human's "this thread
    /// is done" verdict (the asking session learns the outcome on its next
    /// `check_messages`, exactly as it would for an expiry). Throws
    /// BusToolFailure when the question already settled.
    func close(messageID: String, reason: String) async throws
}

/// Why a thread closed without an answer. One definition each, so the card,
/// the tool result handed back to the asking agent, and the activity line all
/// say the same thing.
nonisolated enum BusCloseReason {
    /// The human closed the thread from the Messages tab.
    static let human = "the human closed the thread without an answer"
}

/// Domain-level bus failures, surfaced to the model as isError tool results —
/// clear text beats a protocol error, because the agent can correct and retry.
/// Every case names both WHAT went wrong and WHAT to do about it; several exist
/// only to keep distinct situations distinguishable (an unlinked project is a
/// request to the human, a misspelled one is a typo).
nonisolated enum BusToolFailure: Error, Equatable {
    /// No question with that id.
    case unknownMessage(String)
    /// The question was already answered — by the target project or the human.
    case alreadyAnswered(String)
    /// The question closed without an answer before this answer arrived.
    case expired(String, reason: String?)
    /// Only the project a question was addressed to may answer it.
    case notAddressee(String)
    /// No project by that name/id is registered with Dispatch at all.
    case unknownProject(String)
    /// The project exists but is not linked to the caller — fail closed.
    case notLinked(String)
    /// The name matched more than one linked peer.
    case ambiguousProject(String)
    /// A required free-text argument was empty after trimming.
    case emptyText(String)

    /// The text handed back to the model.
    var message: String {
        switch self {
        case .unknownMessage(let id):
            "No question with id \"\(id)\". Call check_messages for the ids addressed to you — "
                + "ids are opaque, never construct one."
        case .alreadyAnswered(let id):
            "Question \(id) has already been answered. Nothing was overwritten; no action is needed."
        case .expired(let id, let reason):
            "Question \(id) closed without an answer (\(reason ?? "it timed out")), so it can no "
                + "longer be answered. If the exchange still matters, ask that project yourself "
                + "with ask_agent."
        case .notAddressee(let id):
            "Question \(id) was not addressed to this project, so this project cannot answer it. "
                + "Only the project a question was sent to can answer."
        case .unknownProject(let name):
            "No project named \"\(name)\" is registered with Dispatch. Call list_projects for the "
                + "exact names you can reach."
        case .notLinked(let name):
            "This project is not linked to \"\(name)\", so it cannot be reached. Linking is the "
                + "human's decision — ask them to link the two projects in Dispatch."
        case .ambiguousProject(let name):
            "\"\(name)\" matches more than one linked project. Use the exact name from list_projects."
        case .emptyText(let field):
            "The \"\(field)\" argument was empty. Say what you actually need — an empty \(field) "
                + "cannot be acted on."
        }
    }
}

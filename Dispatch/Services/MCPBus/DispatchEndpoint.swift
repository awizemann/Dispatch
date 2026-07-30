// DispatchEndpoint.swift
// ONE project's MCP surface: a dedicated (Server, StatelessHTTPServerTransport)
// pair whose tool handlers close over that project's identity.
//
// Identity is STRUCTURAL — reaching this endpoint requires the project's
// durable bus token in the URL path, so no header or argument can be spoofed
// into another project's identity. That is also why the transport pair is
// per-project rather than shared: a stateless transport keys its response
// waiters by JSON-RPC id, and sharing one across identities is the classic
// cross-wiring hazard.
//
// SDK 0.12.1 facts this codes against (verified against the pre-Dispatch
// endpoint this replaced, which shipped on the same pins):
// - Server rejects a second `initialize` ("Server is already initialized") and
//   the CLI re-initializes on every process run → the pair is REBUILT whenever
//   an initialize request arrives on a live pair.
// - StatelessHTTPServerTransport answers POSTs with plain JSON and 405s
//   GET/DELETE; the CLI tolerates both.

import Foundation
import MCP
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "bus-endpoint")

actor DispatchEndpoint: BusEndpointServing {

    /// The project this endpoint speaks for. Fixed at registration — it is the
    /// whole identity model.
    private let projectID: UUID
    private let router: DispatchRouter

    private var server: Server?
    private var transport: StatelessHTTPServerTransport?
    private var sawInitialize = false

    init(projectID: UUID, router: DispatchRouter) {
        self.projectID = projectID
        self.router = router
    }

    // MARK: - Request handling

    func handle(_ request: HTTPRequest) async -> HTTPResponse {
        // Any request that reaches this endpoint carried the project's token,
        // which only exists in that repo's .mcp.json — so even an initialize
        // or tools/list proves the session (re)started and read the entry.
        // Counting it keeps liveness and the restart cue honest without
        // waiting for a first tool call.
        await router.noteActivity(projectID: projectID)
        // The CLI re-initializes per spawn; the SDK server rejects a second
        // initialize — swap in a fresh pair when one arrives on a used pair.
        if sawInitialize, isInitializeRequest(request.body) {
            await teardown()
        }
        if transport == nil {
            do {
                try await makePair()
            } catch {
                logger.error("bus endpoint failed to start: \(String(describing: error), privacy: .public)")
                return .error(statusCode: 500, .internalError("dispatch bus endpoint failed to start"))
            }
        }
        if isInitializeRequest(request.body) {
            sawInitialize = true
        }
        guard let transport else {
            return .error(statusCode: 500, .internalError("dispatch bus endpoint unavailable"))
        }
        return await transport.handleRequest(request)
    }

    func shutdown() async {
        await teardown()
    }

    private func teardown() async {
        if let server { await server.stop() }
        server = nil
        transport = nil
        sawInitialize = false
    }

    /// Minimal initialize detection (the SDK's JSONRPCMessageKind is
    /// `package`-scoped): a JSON-RPC *request* whose method is "initialize".
    private nonisolated func isInitializeRequest(_ body: Data?) -> Bool {
        guard let body,
              let object = try? JSONSerialization.jsonObject(with: body) as? [String: Any]
        else { return false }
        return object["method"] as? String == "initialize" && object["id"] != nil
    }

    // MARK: - Server construction

    private func makePair() async throws {
        let transport = StatelessHTTPServerTransport()
        let server = Server(
            name: "dispatch",
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0",
            instructions: BusPromptFraming.protocolSection,
            capabilities: .init(tools: .init(listChanged: false))
        )

        let projectID = self.projectID
        let router = self.router

        await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(tools: DispatchToolCatalog.tools)
        }
        await server.withMethodHandler(CallTool.self) { params in
            await Self.dispatch(params, projectID: projectID, router: router)
        }

        try await server.start(transport: transport)
        self.server = server
        self.transport = transport
    }

    // MARK: - Tool dispatch

    private static func dispatch(
        _ params: CallTool.Parameters, projectID: UUID, router: DispatchRouter
    ) async -> CallTool.Result {
        do {
            switch params.name {
            case "ask_agent":
                let target = try requireString("project", in: params.arguments)
                let question = try requireString("question", in: params.arguments)
                let wait = optionalInt("wait_seconds", in: params.arguments)
                let outcome = try await router.ask(
                    callerProjectID: projectID, targetProject: target,
                    question: question, waitSeconds: wait
                )
                switch outcome {
                case .answered(let message):
                    let name = await router.projectName(message.to) ?? target
                    return json([
                        "status": "answered",
                        "question_id": message.id,
                        // The answer arrives FRAMED: it is another session's
                        // text, so it crosses into this model's context inside
                        // the untrusted-content markers, exactly like a
                        // check_messages delivery.
                        "answer": BusPromptFraming.answer(message: message, fromProjectName: name),
                    ])
                case .pending(let message):
                    return json([
                        "status": message.status == .pending ? "pending" : message.status.rawValue,
                        "question_id": message.id,
                        "note": message.status == .pending
                            ? "Delivered to the project's inbox. The answer arrives on a later "
                                + "check_messages — it is not lost if that session is offline."
                            : "The question is no longer pending; call check_messages for the outcome.",
                    ])
                }

            case "answer_agent":
                let questionID = try requireString("question_id", in: params.arguments)
                let answer = try requireString("answer", in: params.arguments)
                let message = try await router.answer(
                    callerProjectID: projectID, questionID: questionID, answer: answer
                )
                return json([
                    "status": "recorded",
                    "question_id": message.id,
                    "note": "The asking project has it.",
                ])

            case "check_messages":
                let inbox = try await router.checkMessages(callerProjectID: projectID)
                var questions: [[String: Any]] = []
                for message in inbox.openQuestions {
                    let name = await router.projectName(message.from) ?? "unknown project"
                    questions.append([
                        "question_id": message.id,
                        "from_project": name,
                        "asked_at": Self.iso(message.askedAt),
                        // Framed, not raw: this is another session's text.
                        "question": BusPromptFraming.question(message: message, fromProjectName: name),
                    ])
                }
                var outcomes: [[String: Any]] = []
                for message in inbox.outcomes {
                    let name = await router.projectName(message.to) ?? "unknown project"
                    switch message.status {
                    case .answered:
                        outcomes.append([
                            "question_id": message.id,
                            "project": name,
                            "status": "answered",
                            "answered_by": message.answeredByHuman ? "the human" : name,
                            "answer": BusPromptFraming.answer(message: message, fromProjectName: name),
                        ])
                    default:
                        outcomes.append([
                            "question_id": message.id,
                            "project": name,
                            "status": message.status.rawValue,
                            "notice": BusPromptFraming.expiry(message: message),
                        ])
                    }
                }
                return json([
                    "open_questions": questions,
                    "open_question_count": questions.count,
                    "answers": outcomes,
                    "answer_count": outcomes.count,
                ])

            case "list_projects":
                let peers = try await router.listProjects(callerProjectID: projectID)
                return json([
                    "count": peers.count,
                    "projects": peers.map { peer -> [String: Any] in
                        var entry: [String: Any] = [
                            // The id is what makes two identically-NAMED linked
                            // projects addressable at all: `ask_agent` accepts
                            // either, and a duplicate name resolves to neither.
                            "project_id": peer.projectID.uuidString,
                            "name": peer.name,
                            "connected": peer.connected,
                            "open_questions_for_you": peer.openQuestionsForCaller,
                        ]
                        if let lastSeen = peer.lastSeenAt {
                            entry["last_seen"] = Self.iso(lastSeen)
                        }
                        return entry
                    },
                ])

            default:
                return failure("Unknown tool \"\(params.name)\".")
            }
        } catch let toolFailure as BusToolFailure {
            return failure(toolFailure.message)
        } catch let argumentFailure as ArgumentFailure {
            return failure(argumentFailure.message)
        } catch {
            logger.error("bus tool \(params.name, privacy: .public) failed: \(String(describing: error), privacy: .public)")
            return failure("The bus could not complete that call. Try again, or ask the human.")
        }
    }

    // MARK: - Argument parsing

    private struct ArgumentFailure: Error {
        let message: String
    }

    private static func requireString(_ key: String, in arguments: [String: Value]?) throws -> String {
        guard let value = arguments?[key], case .string(let string) = value else {
            throw ArgumentFailure(message: "Missing or non-string argument \"\(key)\".")
        }
        return string
    }

    /// A JSON number decodes as .int or .double depending on the wire form —
    /// accept both; clamping is the router's.
    private static func optionalInt(_ key: String, in arguments: [String: Value]?) -> Int? {
        guard let value = arguments?[key] else { return nil }
        if case .int(let number) = value { return number }
        if case .double(let number) = value { return Int(number) }
        return nil
    }

    // MARK: - Result helpers

    private static func json(_ payload: [String: Any]) -> CallTool.Result {
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data()
        return CallTool.Result(
            content: [.text(text: String(decoding: data, as: UTF8.self), annotations: nil, _meta: nil)],
            isError: false
        )
    }

    /// Domain failures come back as isError tool RESULTS, not protocol errors:
    /// clear text the model can act on beats an opaque JSON-RPC error.
    private static func failure(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text: message, annotations: nil, _meta: nil)], isError: true)
    }

    private static func iso(_ date: Date) -> String {
        ISO8601DateFormatter().string(from: date)
    }
}

// MARK: - Tool catalog

/// The whole tool surface: four verbs. Descriptions carry the MECHANICS (what
/// the arguments mean, what the result shapes are); BusPromptFraming
/// .protocolSection carries the judgment.
nonisolated enum DispatchToolCatalog {

    /// Split out of the schema literal: the surrounding `Value` tree is deeply
    /// nested, and inlining an interpolated string there blows past the type
    /// checker's budget.
    private static let waitSecondsDescription =
        "Seconds to wait for an inline answer (0 = do not wait, capped at "
        + "\(DispatchRouter.maxWaitSeconds)). Waiting only happens when the target project "
        + "is connected; otherwise this returns immediately as pending."

    private static let questionDescription =
        "One self-contained question (max \(BusTextSanitizer.maxBodyLength) chars). Include "
        + "the context the other project needs — it can see nothing of yours."

    private static let answerDescription =
        "Your answer (max \(BusTextSanitizer.maxBodyLength) chars)."

    static let tools: [Tool] = [
        Tool(
            name: "ask_agent",
            description: "Ask another linked project a question. The question goes to that "
                + "project's own Claude Code session — a separate repository you cannot read. "
                + "Only projects listed by list_projects are reachable; anything else is "
                + "refused. If that project is connected right now and you pass wait_seconds, "
                + "this waits and returns the answer inline; otherwise it returns "
                + "{status:\"pending\", question_id} and the answer reaches you on a later "
                + "check_messages. Ask about things that live in THAT repo (its contract, its "
                + "behavior, whether a change is safe there) — a question is not a task, and "
                + "the other session cannot see your repo or this conversation.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "project": .object([
                        "type": "string",
                        "description": "The target project's name exactly as list_projects reports it.",
                    ]),
                    "question": .object([
                        "type": "string",
                        "description": Value.string(questionDescription),
                    ]),
                    "wait_seconds": .object([
                        "type": "number",
                        "description": Value.string(waitSecondsDescription),
                    ]),
                ]),
                "required": .array(["project", "question"]),
            ])
        ),
        Tool(
            name: "answer_agent",
            description: "Answer a question addressed to THIS project (you saw it via "
                + "check_messages, or it arrived while you were connected). Only the project a "
                + "question was addressed to can answer it. If someone is waiting on it, your "
                + "answer reaches them immediately. Answer from what you can verify in this "
                + "repo, and say plainly when you do not know — the asker cannot check your "
                + "claims. A question that was already answered, or that expired, is refused "
                + "rather than silently overwritten.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([
                    "question_id": .object([
                        "type": "string",
                        "description": "The question's id, exactly as received — ids are opaque, never construct one.",
                    ]),
                    "answer": .object([
                        "type": "string",
                        "description": Value.string(answerDescription),
                    ]),
                ]),
                "required": .array(["question_id", "answer"]),
            ])
        ),
        Tool(
            name: "check_messages",
            description: "Read this project's bus inbox: questions other projects have asked "
                + "you and are still waiting on (answer them with answer_agent), plus the "
                + "outcome of every question YOU asked that you have not seen yet — answers, "
                + "and questions that expired unanswered. Outcomes are reported exactly once, "
                + "so record what matters when you read it. Call it when you start work and "
                + "whenever you are waiting on another project.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "required": .array([]),
            ])
        ),
        Tool(
            name: "list_projects",
            description: "List the projects this one is LINKED to — the only projects "
                + "ask_agent can reach. Each entry reports whether that project's session is "
                + "connected right now (so a wait_seconds ask is worth it), when it was last "
                + "seen, and how many of its questions are sitting in your inbox. Linking is "
                + "the human's decision: if the project you need is missing, ask the human to "
                + "link it.",
            inputSchema: .object([
                "type": "object",
                "properties": .object([:]),
                "required": .array([]),
            ])
        ),
    ]
}

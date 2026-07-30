// MCPBusListener.swift
// The app-hosted HTTP face of the MCP message bus: ONE localhost listener for
// the whole app, binding 127.0.0.1 on a kernel-assigned free port, routing
// POST /bus/<token> to the registered PROJECT's endpoint. The swift-sdk 0.12.1
// server transports are framework-agnostic (HTTPRequest in → HTTPResponse out,
// NO listener of their own), so this file owns the wire: NIOHTTP1, already
// pinned in our resolved graph.
//
// Identity & credential model (P3):
// - ONE endpoint identity per PROJECT, not per attach. The token is durable
//   (GlobalDatabase.projectBusToken) so the entry P4 writes into the repo's
//   .mcp.json keeps working across app restarts and CLI respawns.
// - register(projectID:token:) is idempotent per project and REPLACES any
//   previous registration: rotating a token revokes the old one here as well as
//   in the database, so a leaked config file goes dead immediately.
// - Requests are validated by ROUTE: an unknown/revoked token is a 404 before
//   any MCP parsing happens. The SDK transport's own localhost Origin
//   validation runs after that.
// - Tokens are per-repo CONFIG values, not user secrets — but they are still
//   credentials: they are never logged, never framed into a prompt, and never
//   put in an error body.

import Foundation
import MCP
import NIOCore
import NIOHTTP1
import NIOPosix
import os

private nonisolated let logger = Logger(subsystem: "com.wizemann.dispatch", category: "bus-listener")

actor MCPBusListener {

    /// The app's single listener. P2 hands it a placeholder router; P3 swaps in
    /// the real Dispatch bus core behind the same seam.
    static let shared = MCPBusListener()

    /// Router injected by the composition root (endpoints hold it strongly for
    /// their tool closures; the router weakly references stores, not us).
    private var router: DispatchRouter?

    /// token → (project, endpoint). The token is the ONLY thing that maps a
    /// request to an identity, which is what makes identity unspoofable: there
    /// is no header or argument to lie in.
    private var endpointsByToken: [String: Route] = [:]

    /// One registered project's route.
    private struct Route {
        let projectID: UUID
        let endpoint: any BusEndpointServing
    }

    private var serverChannel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>?
    private var acceptTask: Task<Void, Never>?
    private(set) var port: Int?

    /// The port to TRY first (P4 stable port). Set from the persisted value
    /// before the first registration; 0 means "kernel, pick one".
    private var preferredPort: Int = 0

    /// Bodies above this are rejected before parsing (largest legal tool call
    /// is a body-limit ask_agent plus JSON-RPC envelope).
    private static let maxBodyBytes = 256 * 1024

    init() {}

    func configure(router: DispatchRouter) {
        self.router = router
    }

    /// Asks the listener to re-bind a specific port on its next start — the
    /// port every `.mcp.json` entry already on disk points at. Ignored once the
    /// listener is bound (the port cannot change under live routes).
    func setPreferredPort(_ port: Int) {
        guard serverChannel == nil, (1...65_535).contains(port) else { return }
        preferredPort = port
    }

    // MARK: - Registration

    /// Registers (or re-registers) a project's bus endpoint under its durable
    /// token and returns the URL an external session connects to.
    ///
    /// Re-registration is a REPLACE: the project's previous endpoint — and, if
    /// the token changed, its previous route — is torn down first, so a rotated
    /// token can never be ridden by a stale config, and one project can never
    /// hold two live endpoints.
    @discardableResult
    func register(projectID: UUID, token: String) async throws -> String {
        guard let router else { throw BusListenerError.notConfigured }
        try await startIfNeeded()
        guard let port else { throw BusListenerError.notRunning }

        await revokeRoutes(projectID: projectID, keeping: token)
        if let existing = endpointsByToken[token], existing.projectID == projectID {
            return Self.url(port: port, token: token)
        }
        // The endpoint's init is main-actor isolated (it captures the
        // @MainActor router), so it is built there and handed back — a
        // DispatchEndpoint is an actor, so crossing isolation with it is safe.
        let endpoint = await MainActor.run { DispatchEndpoint(projectID: projectID, router: router) }
        endpointsByToken[token] = Route(projectID: projectID, endpoint: endpoint)
        return Self.url(port: port, token: token)
    }

    /// Drops every route for a project (unlink / delete / rotation).
    func unregister(projectID: UUID) async {
        await revokeRoutes(projectID: projectID, keeping: nil)
    }

    func unregister(token: String) async {
        if let route = endpointsByToken.removeValue(forKey: token) {
            await route.endpoint.shutdown()
        }
    }

    /// The URL for an already-registered token, or nil when the listener is not
    /// bound yet.
    func url(token: String) -> String? {
        port.map { Self.url(port: $0, token: token) }
    }

    /// True when this token currently resolves to this project — the test seam
    /// behind "rotation revokes the old token".
    func resolves(token: String, to projectID: UUID) -> Bool {
        endpointsByToken[token]?.projectID == projectID
    }

    private func revokeRoutes(projectID: UUID, keeping token: String?) async {
        for (existingToken, route) in endpointsByToken
        where route.projectID == projectID && existingToken != token {
            endpointsByToken.removeValue(forKey: existingToken)
            await route.endpoint.shutdown()
        }
    }

    private nonisolated static func url(port: Int, token: String) -> String {
        "http://127.0.0.1:\(port)/bus/\(token)"
    }

    // MARK: - Lifecycle

    func startIfNeeded() async throws {
        guard serverChannel == nil else { return }
        // STABLE PORT (P4): try the port the repos' `.mcp.json` files already
        // point at. Another process holding it is the only realistic failure,
        // and it must not stop the bus — fall back to a kernel-assigned port and
        // let the caller rewrite every entry.
        var preferred: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>?
        if preferredPort != 0 {
            do {
                preferred = try await bind(port: preferredPort)
            } catch {
                logger.warning("preferred bus port \(self.preferredPort, privacy: .public) unavailable; taking a fresh one: \(String(describing: error), privacy: .public)")
            }
        }
        let channel: NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never>
        if let preferred {
            channel = preferred
        } else {
            channel = try await bind(port: 0)
        }
        serverChannel = channel
        port = channel.channel.localAddress?.port
        logger.info("bus listener bound to 127.0.0.1:\(self.port ?? -1)")

        // Strong self: the accept loop runs for the listener's whole life;
        // stop() cancels it (NIOAsyncChannel's inbound stream honors task
        // cancellation), which is also what breaks the reference.
        acceptTask = Task {
            try? await channel.executeThenClose { inbound in
                try await withThrowingDiscardingTaskGroup { group in
                    for try await connection in inbound {
                        group.addTask {
                            await Self.serve(connection: connection, listener: self)
                        }
                    }
                }
            }
        }
    }

    /// One bind attempt. `port: 0` asks the kernel for any free port.
    private func bind(
        port: Int
    ) async throws -> NIOAsyncChannel<NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>, Never> {
        try await ServerBootstrap(group: NIOSingletons.posixEventLoopGroup)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .bind(host: "127.0.0.1", port: port) { childChannel in
                childChannel.eventLoop.makeCompletedFuture {
                    try childChannel.pipeline.syncOperations.configureHTTPServerPipeline()
                    return try NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>(
                        wrappingChannelSynchronously: childChannel
                    )
                }
            }
    }

    func stop() async {
        acceptTask?.cancel()
        acceptTask = nil
        try? await serverChannel?.channel.close()
        serverChannel = nil
        port = nil
        for route in endpointsByToken.values {
            await route.endpoint.shutdown()
        }
        endpointsByToken.removeAll()
    }

    // MARK: - Routing (actor-isolated lookup; body handling stays off-actor)

    /// What a request path resolved to. Both arms go through the SAME token
    /// table, so an unknown or revoked token is a 404 on either route — the
    /// probe is not a second door with its own rules.
    private enum Resolution {
        /// `/bus/<token>` — the MCP surface a Claude Code session speaks to.
        case mcp(any BusEndpointServing)
        /// `/bus/<token>/pending` — the content-free probe the repo's session
        /// hooks poll.
        case pending(UUID)
    }

    private func resolve(path: String) -> Resolution? {
        let components = path.split(separator: "?", maxSplits: 1)[0]
            .split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 2 || components.count == 3,
              components[0] == "bus",
              let route = endpointsByToken[String(components[1])]
        else { return nil }
        if components.count == 2 { return .mcp(route.endpoint) }
        guard components[2] == Self.pendingPathComponent else { return nil }
        return .pending(route.projectID)
    }

    static let pendingPathComponent = "pending"

    /// The probe's whole body: a count, and NOTHING else. No question text, no
    /// subjects, no ids — the reader is a shell script, and a shell script has
    /// no business handling message content (it would end up in a log, an
    /// argv, or a session transcript by accident).
    private func pendingBody(projectID: UUID) async -> Data {
        guard let router else { return Data(#"{"pending":0}"#.utf8) }
        let count = await router.pendingCount(for: projectID)
        return Data("{\"pending\":\(count)}\n".utf8)
    }

    // MARK: - Connection serving (nonisolated: one task per connection)

    private static func serve(
        connection: NIOAsyncChannel<HTTPServerRequestPart, HTTPServerResponsePart>,
        listener: MCPBusListener
    ) async {
        try? await connection.executeThenClose { inbound, outbound in
            var head: HTTPRequestHead?
            var body = Data()
            for try await part in inbound {
                switch part {
                case .head(let requestHead):
                    head = requestHead
                    body.removeAll(keepingCapacity: true)
                case .body(let buffer):
                    guard body.count + buffer.readableBytes <= maxBodyBytes else {
                        try await Self.writeSimpleResponse(
                            outbound, status: .payloadTooLarge,
                            body: Data(), keepAlive: false
                        )
                        return
                    }
                    body.append(contentsOf: buffer.readableBytesView)
                case .end:
                    guard let requestHead = head else { continue }
                    let request = HTTPRequest(
                        method: requestHead.method.rawValue,
                        headers: Dictionary(
                            requestHead.headers.map { ($0.name, $0.value) },
                            uniquingKeysWith: { first, _ in first }
                        ),
                        body: body.isEmpty ? nil : body,
                        path: requestHead.uri
                    )
                    let keepAlive = requestHead.isKeepAlive
                    guard let resolution = await listener.resolve(path: requestHead.uri) else {
                        try await Self.writeSimpleResponse(
                            outbound, status: .notFound, body: Data(), keepAlive: keepAlive
                        )
                        if !keepAlive { return }
                        head = nil
                        continue
                    }
                    let endpoint: any BusEndpointServing
                    switch resolution {
                    case .pending(let projectID):
                        // GET is what the hook uses; POST is accepted so a
                        // caller that only knows how to POST at this bus is not
                        // stuck. Anything else is a 405, not a silent 200.
                        guard requestHead.method == .GET || requestHead.method == .POST else {
                            try await Self.writeSimpleResponse(
                                outbound, status: .methodNotAllowed,
                                body: Data(), keepAlive: keepAlive
                            )
                            if !keepAlive { return }
                            head = nil
                            continue
                        }
                        let body = await listener.pendingBody(projectID: projectID)
                        try await Self.writeSimpleResponse(
                            outbound, status: .ok, body: body, keepAlive: keepAlive,
                            contentType: "application/json"
                        )
                        if !keepAlive { return }
                        head = nil
                        continue
                    case .mcp(let resolved):
                        endpoint = resolved
                    }
                    let response = await endpoint.handle(request)
                    try await Self.write(response, to: outbound, keepAlive: keepAlive)
                    if !keepAlive { return }
                    head = nil
                }
            }
        }
    }

    private static func write(
        _ response: HTTPResponse,
        to outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        keepAlive: Bool
    ) async throws {
        // The stateless transport never streams; .stream would mean a design
        // regression upstream — refuse it loudly rather than hang the CLI.
        if case .stream = response {
            try await writeSimpleResponse(outbound, status: .internalServerError,
                                          body: Data(), keepAlive: false)
            return
        }
        let bodyData = response.bodyData ?? Data()
        var headers = HTTPHeaders()
        for (name, value) in response.headers {
            headers.replaceOrAdd(name: name, value: value)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(bodyData.count))
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )
        try await outbound.write(.head(head))
        if !bodyData.isEmpty {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: bodyData))))
        }
        try await outbound.write(.end(nil))
    }

    private static func writeSimpleResponse(
        _ outbound: NIOAsyncChannelOutboundWriter<HTTPServerResponsePart>,
        status: HTTPResponseStatus,
        body: Data,
        keepAlive: Bool,
        contentType: String? = nil
    ) async throws {
        var headers = HTTPHeaders()
        if let contentType {
            headers.replaceOrAdd(name: "Content-Type", value: contentType)
        }
        headers.replaceOrAdd(name: "Content-Length", value: String(body.count))
        headers.replaceOrAdd(name: "Connection", value: keepAlive ? "keep-alive" : "close")
        try await outbound.write(.head(HTTPResponseHead(version: .http1_1, status: status, headers: headers)))
        if !body.isEmpty {
            try await outbound.write(.body(.byteBuffer(ByteBuffer(bytes: body))))
        }
        try await outbound.write(.end(nil))
    }

}

nonisolated enum BusListenerError: Error {
    case notConfigured
    case notRunning
}

/// One registered project's request handler. DispatchEndpoint is the live
/// conformer; tests substitute fakes to exercise routing without the SDK.
protocol BusEndpointServing: Sendable {
    func handle(_ request: HTTPRequest) async -> HTTPResponse
    func shutdown() async
}

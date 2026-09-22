import Foundation
import GRPCCore
import GRPCProtobuf

/// The mothership's side of ThreadRegistration.
///
/// On a shared ~/.rao stack one mothership serves every app's Thread. Given a
/// `callerResolver`, it learns which app each RPC comes from by the stack
/// secret in its metadata (the interceptor has already refused unknown
/// secrets), records that app on the node at Register, and refuses any later
/// RPC about a node from a different app — so Craft's Thread can neither
/// re-register, heartbeat, flip the availability of, nor hold the one session
/// slot of Ambient's node. Without a resolver every caller is unscoped, exactly
/// as before.
public final class ThreadRegistrationServiceImpl: Thread_V1_ThreadRegistration.SimpleServiceProtocol, Sendable {
    public let registry: any ThreadRegistry
    public let sessionManager: ThreadSessionManager
    public let mothershipId: UUID
    private let logger: any ConduitLogger
    private let callerResolver: StackSecretResolver?

    /// Who is calling, as far as ownership checks go.
    enum Caller: Sendable, Equatable {
        /// No resolver: a single-app or open mothership; no app checks.
        case unscoped
        /// The app whose secret the RPC presented.
        case app(String)
        /// A resolver is set but the RPC's secret maps to no app.
        case unresolved
    }

    public init(
        registry: any ThreadRegistry,
        mothershipId: UUID,
        sessionManager: ThreadSessionManager,
        logger: any ConduitLogger,
        callerResolver: StackSecretResolver? = nil
    ) {
        self.registry = registry
        self.mothershipId = mothershipId
        self.sessionManager = sessionManager
        self.logger = logger
        self.callerResolver = callerResolver
    }

    // MARK: - Caller resolution

    /// The caller for an RPC whose metadata we can see.
    func caller(in metadata: Metadata) -> Caller {
        guard let callerResolver else { return .unscoped }
        guard let app = StackSecretMetadata.callerApp(in: metadata, resolver: callerResolver) else { return .unresolved }
        return .app(app)
    }

    /// The caller for an RPC reaching the metadata-less simple methods
    /// directly. With a resolver that can only be unresolved.
    private var callerWithoutMetadata: Caller {
        callerResolver == nil ? .unscoped : .unresolved
    }

    /// Throws unless `caller` may act on the node registered as `threadId`.
    /// A node nobody registered yet, or one registered without an app, is
    /// nobody's to defend.
    private func requireOwnership(of threadId: UUID, by caller: Caller, method: String, peer: String) async throws {
        switch caller {
        case .unscoped:
            return
        case .unresolved:
            logger.warning("ThreadRegistration: refused \(method) for Thread \(threadId) from \(peer) — the stack secret names no app")
            throw RPCError(code: .unauthenticated, message: "Missing or unknown x-ambient-secret")
        case .app(let app):
            guard let owner = await registry.registeredNode(threadId: threadId)?.app, owner != app else { return }
            logger.warning("ThreadRegistration: refused \(method) for Thread \(threadId) from \(peer) — the node belongs to \(owner), the caller is \(app)")
            throw RPCError(code: .permissionDenied, message: "Thread \(threadId) belongs to another app")
        }
    }

    // MARK: - ServiceProtocol (sees metadata)

    public func register(
        request: GRPCCore.ServerRequest<Thread_V1_RegisterRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_RegisterResponse> {
        let message = try await register(request.message, context: context, caller: caller(in: request.metadata))
        return GRPCCore.ServerResponse(message: message, metadata: [:])
    }

    public func heartbeat(
        request: GRPCCore.ServerRequest<Thread_V1_HeartbeatRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_HeartbeatResponse> {
        let message = try await heartbeat(request.message, context: context, caller: caller(in: request.metadata))
        return GRPCCore.ServerResponse(message: message, metadata: [:])
    }

    public func updateAvailability(
        request: GRPCCore.ServerRequest<Thread_V1_AvailabilityUpdateRequest>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.ServerResponse<Thread_V1_AvailabilityUpdateResponse> {
        let message = try await updateAvailability(request.message, context: context, caller: caller(in: request.metadata))
        return GRPCCore.ServerResponse(message: message, metadata: [:])
    }

    public func session(
        request: GRPCCore.StreamingServerRequest<Thread_V1_ThreadSessionMessage>,
        context: GRPCCore.ServerContext
    ) async throws -> GRPCCore.StreamingServerResponse<Thread_V1_ThreadSessionMessage> {
        // Resolve now: the producer below runs after this method returns.
        let caller = caller(in: request.metadata)
        return GRPCCore.StreamingServerResponse(
            metadata: [:],
            producer: { writer in
                try await self.session(request: request.messages, response: writer, context: context, caller: caller)
                return [:]
            }
        )
    }

    // MARK: - SimpleServiceProtocol (no metadata)

    public func register(
        request: Thread_V1_RegisterRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_RegisterResponse {
        try await register(request, context: context, caller: callerWithoutMetadata)
    }

    public func heartbeat(
        request: Thread_V1_HeartbeatRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_HeartbeatResponse {
        try await heartbeat(request, context: context, caller: callerWithoutMetadata)
    }

    public func updateAvailability(
        request: Thread_V1_AvailabilityUpdateRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_AvailabilityUpdateResponse {
        try await updateAvailability(request, context: context, caller: callerWithoutMetadata)
    }

    public func session(
        request: GRPCCore.RPCAsyncSequence<Thread_V1_ThreadSessionMessage, any Swift.Error>,
        response: GRPCCore.RPCWriter<Thread_V1_ThreadSessionMessage>,
        context: GRPCCore.ServerContext
    ) async throws {
        try await session(request: request, response: response, context: context, caller: callerWithoutMetadata)
    }

    // MARK: - Handlers

    private func register(
        _ request: Thread_V1_RegisterRequest,
        context: GRPCCore.ServerContext,
        caller: Caller
    ) async throws -> Thread_V1_RegisterResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_RegisterResponse()
            resp.accepted = false
            resp.mothershipID = mothershipId.uuidString
            return resp
        }
        try await requireOwnership(of: threadId, by: caller, method: "Register", peer: context.remotePeer)

        var app: String?
        if case .app(let name) = caller { app = name }
        let node = ThreadNode(
            threadId: threadId,
            host: request.host,
            grpcPort: Int(request.grpcPort),
            httpPort: Int(request.httpPort),
            app: app
        )
        await registry.registerNode(node)
        let owner = app.map { " for \($0)" } ?? ""
        logger.info("ThreadRegistration", "Registered Thread \(threadId)\(owner) at \(request.host) grpc:\(request.grpcPort) http:\(request.httpPort)")

        var resp = Thread_V1_RegisterResponse()
        resp.accepted = true
        resp.mothershipID = mothershipId.uuidString
        return resp
    }

    private func heartbeat(
        _ request: Thread_V1_HeartbeatRequest,
        context: GRPCCore.ServerContext,
        caller: Caller
    ) async throws -> Thread_V1_HeartbeatResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_HeartbeatResponse()
            resp.alive = false
            return resp
        }
        try await requireOwnership(of: threadId, by: caller, method: "Heartbeat", peer: context.remotePeer)

        await registry.heartbeatNode(threadId: threadId)

        var resp = Thread_V1_HeartbeatResponse()
        resp.alive = true
        return resp
    }

    private func updateAvailability(
        _ request: Thread_V1_AvailabilityUpdateRequest,
        context: GRPCCore.ServerContext,
        caller: Caller
    ) async throws -> Thread_V1_AvailabilityUpdateResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_AvailabilityUpdateResponse()
            resp.acknowledged = false
            return resp
        }
        try await requireOwnership(of: threadId, by: caller, method: "UpdateAvailability", peer: context.remotePeer)

        await registry.updateNodeAvailability(threadId: threadId, accepting: request.acceptingStorage)
        logger.info("ThreadRegistration", "Thread \(threadId) availability → acceptingStorage=\(request.acceptingStorage)")

        var resp = Thread_V1_AvailabilityUpdateResponse()
        resp.acknowledged = true
        return resp
    }

    // MARK: - Bidirectional session

    private func session(
        request: GRPCCore.RPCAsyncSequence<Thread_V1_ThreadSessionMessage, any Swift.Error>,
        response: GRPCCore.RPCWriter<Thread_V1_ThreadSessionMessage>,
        context: GRPCCore.ServerContext,
        caller: Caller
    ) async throws {
        // First message must be a Ping carrying the Thread's UUID.
        var iter = request.makeAsyncIterator()
        guard let first = try await iter.next(),
              case .ping = first.payload,
              let threadId = UUID(uuidString: first.threadID) else { return }

        // A shared stack only opens a session for a node its caller
        // registered — checked before the one-session slot is taken, so
        // another app can't squat it.
        if case .app(let app) = caller {
            guard await registry.registeredNode(threadId: threadId) != nil else {
                logger.warning("ThreadSession: refused a session for unregistered Thread \(threadId) from \(app) at \(context.remotePeer)")
                throw RPCError(code: .failedPrecondition, message: "Register Thread \(threadId) before opening its session")
            }
        }
        try await requireOwnership(of: threadId, by: caller, method: "Session", peer: context.remotePeer)

        // Open the managed outgoing channel. The writer task below is the ONLY
        // code that calls response.write(), and it only runs while session() is
        // executing, so the gRPC stream is guaranteed open for every write.
        //
        // One live session per Thread. A second stream for the same id — a
        // duplicate node, or a reconnect racing a handler the mothership hasn't
        // torn down yet — is refused rather than silently stealing the channel
        // from under the handler that owns it; the client backs off and retries.
        let opened: (handle: SessionHandle, outgoing: AsyncStream<Thread_V1_ThreadSessionMessage>)
        do {
            opened = try await sessionManager.openSession(for: threadId)
        } catch ThreadSessionError.sessionAlreadyOpen {
            logger.warning("ThreadSession: Refused a second session for Thread \(threadId) from \(context.remotePeer): one is already live")
            throw RPCError(code: .alreadyExists, message: "Thread \(threadId) already has a live session; retry after it closes")
        }
        let handle = opened.handle
        let outgoing = opened.outgoing
        await registry.heartbeatNode(threadId: threadId)
        logger.info("ThreadSession", "Session opened for Thread \(threadId)")

        // Acknowledge the first ping via the managed channel.
        var pong = Thread_V1_ThreadSessionMessage()
        pong.correlationID = first.correlationID
        pong.payload = .pong(Thread_V1_ThreadSessionPong())
        await sessionManager.send(pong, to: threadId)

        // Run the writer and reader concurrently inside this handler so all
        // writes are bounded to session()'s lifetime.
        await withTaskGroup(of: Void.self) { [self] group in
            // Writer task: drains the outgoing channel to the gRPC response stream.
            group.addTask {
                do {
                    for await msg in outgoing {
                        try await response.write(msg)
                    }
                } catch {
                    self.logger.warning("ThreadSession: writer task error for Thread \(threadId): \(error)")
                }
            }

            // Reader: process messages until Thread closes its send side or errors.
            do {
                while let msg = try await iter.next() {
                    switch msg.payload {
                    case .ping:
                        await registry.heartbeatNode(threadId: threadId)
                        var pong = Thread_V1_ThreadSessionMessage()
                        pong.correlationID = msg.correlationID
                        pong.payload = .pong(Thread_V1_ThreadSessionPong())
                        await sessionManager.send(pong, to: threadId)
                    case .none:
                        break
                    default:
                        // Any message from the Thread keeps the node alive, not only pings.
                        await registry.heartbeatNode(threadId: threadId)
                        logger.info("ThreadSession", "← Thread \(threadId) delivered \(payloadName(msg.payload))")
                        await sessionManager.deliver(msg)
                    }
                }
                logger.info("ThreadSession", "Thread \(threadId) closed its send side cleanly")
            } catch {
                logger.warning("ThreadSession: reader error from Thread \(threadId): \(error)")
            }

            // Reader done: cancel the writer task (it's blocked on the channel).
            group.cancelAll()
        }

        // Close the session and cancel pending continuations BEFORE returning.
        // This must happen while session() is still on the call stack — the moment
        // session() returns, gRPC marks the stream closed and any write would crash.
        await sessionManager.closeSession(handle)
        logger.info("ThreadSession", "Session closed for Thread \(threadId)")
    }
}

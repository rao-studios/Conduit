import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Thrown by the session watchdog when no message has been received from the
/// mothership/Fleet for longer than the staleness window, forcing the session
/// to tear down so the reconnect loop can run.
struct SessionStalledError: Error {}

/// Thread-safe timestamp of the last message received from the peer. Shared
/// between the session's response loop (which touches it) and the watchdog
/// (which reads it), so it can't live on the actor without forcing every touch
/// through `await`.
final class PongTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var last = Date()
    var value: Date { lock.withLock { last } }
    func touch() { lock.withLock { last = Date() } }
}

public actor MothershipRegistrationClient {
    public let mothershipHost: String
    public let mothershipGRPCPort: Int
    public let threadId: UUID
    public let threadHost: String
    public let threadGRPCPort: Int
    public let threadHTTPPort: Int
    public let requestDispatcher: any SessionRequestHandling
    private let logger: any ConduitLogger
    /// Applied to every RPC this client makes, on every connection it opens
    /// (e.g. ``StackSecretClientInterceptor`` in Ambient's local stack).
    private let interceptors: [any ClientInterceptor]
    private var sessionTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(
        mothershipHost: String,
        mothershipGRPCPort: Int,
        threadId: UUID,
        threadHost: String,
        threadGRPCPort: Int,
        threadHTTPPort: Int,
        requestDispatcher: any SessionRequestHandling,
        logger: any ConduitLogger,
        interceptors: [any ClientInterceptor] = []
    ) {
        self.mothershipHost      = mothershipHost
        self.mothershipGRPCPort  = mothershipGRPCPort
        self.threadId             = threadId
        self.threadHost           = threadHost
        self.threadGRPCPort       = threadGRPCPort
        self.threadHTTPPort       = threadHTTPPort
        self.requestDispatcher   = requestDispatcher
        self.logger              = logger
        self.interceptors        = interceptors
    }

    // MARK: - Lifecycle

    /// Starts the registration + session stream loop. Reconnects automatically on
    /// connection loss. Call once at startup; registration retries until Sewn is reachable.
    public func startHeartbeatLoop() {
        sessionTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.runSession()
                guard !Task.isCancelled else { break }
                // Back off 5 s before reconnecting after a dropped session.
                try? await Task.sleep(nanoseconds: 5_000_000_000)
            }
        }
        // Out-of-band liveness: a unary Heartbeat on its own short-lived
        // connection, independent of the session stream. A large inbound push
        // can saturate the session stream and stall the in-stream ping behind
        // ≤100 MB index responses; this keeps Sewn's `lastSeen` fresh regardless
        // so the Thread isn't evicted mid-push.
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 15_000_000_000)
                guard !Task.isCancelled else { break }
                await self?.sendUnaryHeartbeat()
            }
        }
    }

    public func stop() {
        sessionTask?.cancel()
        sessionTask = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    // MARK: - Transport

    /// Builds the HTTP/2 transport with keepalive enabled. NIO sends PING frames
    /// after `time` of inactivity and tears the connection down if they aren't
    /// answered within `timeout`, which fails the in-flight RPC so the reconnect
    /// loop can run. PING frames are connection-level control frames, so they
    /// keep flowing — and detect a dead peer — even while the session stream is
    /// saturated by a large push. Without this, a silent drop / peer restart is
    /// never observed and `runSession()` hangs forever.
    private func makeTransport() throws -> HTTP2ClientTransport.Posix {
        try .http2NIOPosix(
            target: .ipv4(host: mothershipHost, port: mothershipGRPCPort),
            transportSecurity: .plaintext,
            config: .defaults { c in
                c.connection.keepalive = .init(
                    time: .seconds(15),
                    timeout: .seconds(10),
                    allowWithoutCalls: true
                )
                // This node is the CLIENT of the bidi session, so its large
                // index/search/library responses travel as client→server
                // messages. Match the mothership's opened window/frames, and
                // gzip the throttle-prone direction (payloads are text-heavy;
                // embeddings never cross the wire).
                c.http2.targetWindowSize = 16 * 1024 * 1024
                c.http2.maxFrameSize = 1 << 20
                c.compression.algorithm = .gzip
                c.compression.enabledAlgorithms = [.gzip, .none]
            }
        )
    }

    // MARK: - Out-of-band heartbeat

    /// Sends a single unary Heartbeat on its own connection. Decoupled from the
    /// session stream so it can never be queued behind large index responses.
    private func sendUnaryHeartbeat() async {
        do {
            try await withGRPCClient(transport: makeTransport(), interceptors: interceptors) { [self] client in
                let stub = Thread_V1_ThreadRegistration.Client(wrapping: client)
                var req = Thread_V1_HeartbeatRequest()
                req.threadID = threadId.uuidString
                var options = GRPCCore.CallOptions.defaults
                options.timeout = .seconds(10)
                _ = try await stub.heartbeat(req, options: options)
            }
        } catch {
            logger.warning("MothershipRegistrationClient: out-of-band heartbeat failed — \(error)")
        }
    }

    // MARK: - Availability (one-shot, own connection)

    public func sendAvailabilityUpdate(acceptingStorage: Bool) async {
        do {
            try await withGRPCClient(transport: makeTransport(), interceptors: interceptors) { client in
                let stub = Thread_V1_ThreadRegistration.Client(wrapping: client)
                var req = Thread_V1_AvailabilityUpdateRequest()
                req.threadID = self.threadId.uuidString
                req.acceptingStorage = acceptingStorage
                _ = try await stub.updateAvailability(req)
                self.logger.info("MothershipRegistrationClient: availability updated — accepting_storage=\(acceptingStorage)")
            }
        } catch {
            logger.error("MothershipRegistrationClient: availability update failed — \(error)")
        }
    }

    // MARK: - Session loop

    /// Opens one persistent gRPC connection, registers, then opens the bidirectional
    /// session stream. Sewn sends fan-out requests down the stream; this Thread dispatches
    /// them locally and sends responses back. Reconnects automatically on failure.
    private func runSession() async {
        do {
            try await withGRPCClient(transport: makeTransport(), interceptors: interceptors) { [self] client in
                let stub = Thread_V1_ThreadRegistration.Client(wrapping: client)

                // ── 1. Register (one attempt per fresh connection) ───────────
                // `waitForReady` lets this attempt ride out transient connection
                // failures and register the moment the mothership/Fleet comes up
                // (up to `timeout`), instead of aborting immediately. If it still
                // fails, the error propagates out of `withGRPCClient`, tearing this
                // connection down so the outer loop reconnects with a *fresh*
                // client. Previously the register retry reused the same client, so a
                // Thread started before its mothership never connected until restarted.
                guard !Task.isCancelled else { return }
                var registerOptions = GRPCCore.CallOptions.defaults
                registerOptions.waitForReady = true
                registerOptions.timeout = .seconds(60)

                var req = Thread_V1_RegisterRequest()
                req.threadID  = threadId.uuidString
                req.host     = threadHost
                req.grpcPort = Int32(threadGRPCPort)
                req.httpPort = Int32(threadHTTPPort)
                let resp = try await stub.register(req, options: registerOptions)
                guard resp.accepted else {
                    logger.error("MothershipRegistrationClient: registration rejected (invalid thread ID?)")
                    return
                }
                logger.info("MothershipRegistrationClient: registered with mothership \(resp.mothershipID)")

                // ── 2. Bidirectional session stream ──────────────────────────
                let (outgoing, continuation) = AsyncStream.makeStream(of: Thread_V1_ThreadSessionMessage.self)
                let myThreadId  = threadId
                let dispatcher = requestDispatcher

                // Refreshed on every inbound message (a busy push is itself proof
                // of life); read by the watchdog below.
                let pongTracker = PongTracker()

                let sessionOptions: GRPCCore.CallOptions = {
                    var o = GRPCCore.CallOptions.defaults
                    o.maxRequestMessageBytes = 100 * 1024 * 1024
                    return o
                }()

                // Run the session under a watchdog. Keepalive (above) detects a
                // dead connection; this catches the case where the connection is
                // healthy but the session is application-wedged — if no message
                // arrives for `stalenessSeconds`, tear it down so the outer loop
                // reconnects. Kept < 60 s to stay inside Sewn's active-node window.
                let stalenessSeconds: TimeInterval = 45
                try await withThrowingTaskGroup(of: Void.self) { group in
                  group.addTask { [self] in
                    try await stub.session(
                    options: sessionOptions,
                    requestProducer: { [self] writer in
                        var ping = Thread_V1_ThreadSessionMessage()
                        ping.threadID = myThreadId.uuidString
                        ping.payload = .ping(Thread_V1_ThreadSessionPing())
                        logger.info("MothershipRegistrationClient: session stream opened — sending initial ping")
                        try await writer.write(ping)
                        logger.info("MothershipRegistrationClient: initial ping sent — stream active")

                        do {
                            for await msg in outgoing {
                                logger.info("MothershipRegistrationClient: → Sewn \(payloadName(msg.payload)) [\(msg.correlationID.prefix(8))]")
                                try await writer.write(msg)
                                // Outbound progress is liveness too: during a
                                // long one-way push nothing arrives from Sewn,
                                // and the watchdog must not tear the session
                                // down mid-transfer.
                                pongTracker.touch()
                                logger.info("MothershipRegistrationClient: → Sewn write complete \(payloadName(msg.payload)) [\(msg.correlationID.prefix(8))]")
                            }
                        } catch {
                            logger.warning("MothershipRegistrationClient: requestProducer write error — \(error)")
                            throw error
                        }
                        logger.info("MothershipRegistrationClient: requestProducer outgoing channel finished")
                    },
                    onResponse: { [self] streamingResponse in
                        logger.info("MothershipRegistrationClient: onResponse handler entered")

                        let pingTask = Task {
                            while !Task.isCancelled {
                                try? await Task.sleep(nanoseconds: 30_000_000_000)
                                guard !Task.isCancelled else { break }
                                var ping = Thread_V1_ThreadSessionMessage()
                                ping.threadID = myThreadId.uuidString
                                ping.payload = .ping(Thread_V1_ThreadSessionPing())
                                continuation.yield(ping)
                            }
                            logger.info("MothershipRegistrationClient: pingTask ended")
                        }
                        defer {
                            pingTask.cancel()
                            continuation.finish()
                            logger.info("MothershipRegistrationClient: onResponse defer — pingTask cancelled, outgoing finished")
                        }

                        do {
                            for try await msg in streamingResponse.messages {
                                // Any inbound message proves the peer is alive.
                                pongTracker.touch()
                                switch msg.payload {
                                case .pong:
                                    logger.info("MothershipRegistrationClient: ← pong [\(msg.correlationID.prefix(8))]")
                                case .none:
                                    logger.warning("MothershipRegistrationClient: ← message with no payload [\(msg.correlationID.prefix(8))]")
                                default:
                                    let pname = payloadName(msg.payload)
                                    logger.info("MothershipRegistrationClient: ← Sewn request \(pname) [\(msg.correlationID.prefix(8))] — dispatching")
                                    Task {
                                        if let resp = await dispatcher.handle(msg) {
                                            logger.info("MothershipRegistrationClient: dispatch complete \(pname) [\(msg.correlationID.prefix(8))] — queuing response")
                                            continuation.yield(resp)
                                        } else {
                                            logger.warning("MothershipRegistrationClient: dispatch returned nil for \(pname) [\(msg.correlationID.prefix(8))]")
                                        }
                                    }
                                }
                            }
                            logger.info("MothershipRegistrationClient: response stream ended cleanly (Sewn closed its send side)")
                        } catch {
                            logger.warning("MothershipRegistrationClient: response stream error — \(error)")
                            throw error
                        }
                        return ()
                    }
                    )
                  }

                  // Watchdog: poll the tracker and throw to collapse the group
                  // (cancelling the session task) when the peer goes silent.
                  group.addTask { [self] in
                      while !Task.isCancelled {
                          do {
                              try await Task.sleep(nanoseconds: 5_000_000_000)
                          } catch {
                              return  // cancelled — session ended normally
                          }
                          if Date().timeIntervalSince(pongTracker.value) > stalenessSeconds {
                              logger.warning("MothershipRegistrationClient: no message from Sewn in \(Int(stalenessSeconds))s — tearing down session to force reconnect")
                              throw SessionStalledError()
                          }
                      }
                  }

                  // Whichever child finishes first (session ended, or watchdog
                  // fired) tears down the other; a thrown error propagates out and
                  // the outer loop reconnects after its 5 s backoff.
                  _ = try await group.next()
                  group.cancelAll()
                }
            }
        } catch is CancellationError {
            // Normal shutdown — don't log.
        } catch let error as RPCError where error.code == .alreadyExists {
            logger.warning("MothershipRegistrationClient: mothership still holds a live session for this node id — another Thread with the same id, or one it hasn't reaped yet; retrying in 5 s (\(error.message))")
        } catch let error as RPCError where error.code == .unauthenticated {
            logger.error("MothershipRegistrationClient: mothership refused the stack secret — this node presents its launcher's AMBIENT_STACK_SECRET; a one-app stack needs the same value in both processes, a shared ~/.rao stack must know it as secrets/<app>. Retrying in 5 s")
        } catch let error as RPCError where error.code == .permissionDenied {
            logger.error("MothershipRegistrationClient: mothership refused this node — its id is registered to another app, or this peer isn't loopback; retrying in 5 s (\(error.message))")
        } catch let error as RPCError where error.code == .failedPrecondition {
            logger.warning("MothershipRegistrationClient: mothership doesn't know this node yet — re-registering in 5 s (\(error.message))")
        } catch {
            logger.warning("MothershipRegistrationClient: session ended — \(error)")
        }
    }
}

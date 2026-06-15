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
    public let totemId: UUID
    public let totemHost: String
    public let totemGRPCPort: Int
    public let totemHTTPPort: Int
    public let requestDispatcher: any SessionRequestHandling
    private let logger: any ConduitLogger
    private var sessionTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?

    public init(
        mothershipHost: String,
        mothershipGRPCPort: Int,
        totemId: UUID,
        totemHost: String,
        totemGRPCPort: Int,
        totemHTTPPort: Int,
        requestDispatcher: any SessionRequestHandling,
        logger: any ConduitLogger
    ) {
        self.mothershipHost      = mothershipHost
        self.mothershipGRPCPort  = mothershipGRPCPort
        self.totemId             = totemId
        self.totemHost           = totemHost
        self.totemGRPCPort       = totemGRPCPort
        self.totemHTTPPort       = totemHTTPPort
        self.requestDispatcher   = requestDispatcher
        self.logger              = logger
    }

    // MARK: - Lifecycle

    /// Starts the registration + session stream loop. Reconnects automatically on
    /// connection loss. Call once at startup; registration retries until Seer is reachable.
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
        // ≤100 MB index responses; this keeps Seer's `lastSeen` fresh regardless
        // so the Totem isn't evicted mid-push.
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
            }
        )
    }

    // MARK: - Out-of-band heartbeat

    /// Sends a single unary Heartbeat on its own connection. Decoupled from the
    /// session stream so it can never be queued behind large index responses.
    private func sendUnaryHeartbeat() async {
        do {
            try await withGRPCClient(transport: makeTransport()) { [self] client in
                let stub = Totem_V1_TotemRegistration.Client(wrapping: client)
                var req = Totem_V1_HeartbeatRequest()
                req.totemID = totemId.uuidString
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
            try await withGRPCClient(transport: makeTransport()) { client in
                let stub = Totem_V1_TotemRegistration.Client(wrapping: client)
                var req = Totem_V1_AvailabilityUpdateRequest()
                req.totemID = self.totemId.uuidString
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
    /// session stream. Seer sends fan-out requests down the stream; this Totem dispatches
    /// them locally and sends responses back. Reconnects automatically on failure.
    private func runSession() async {
        do {
            try await withGRPCClient(transport: makeTransport()) { [self] client in
                let stub = Totem_V1_TotemRegistration.Client(wrapping: client)

                // ── 1. Register (one attempt per fresh connection) ───────────
                // `waitForReady` lets this attempt ride out transient connection
                // failures and register the moment the mothership/Fleet comes up
                // (up to `timeout`), instead of aborting immediately. If it still
                // fails, the error propagates out of `withGRPCClient`, tearing this
                // connection down so the outer loop reconnects with a *fresh*
                // client. Previously the register retry reused the same client, so a
                // Totem started before its mothership never connected until restarted.
                guard !Task.isCancelled else { return }
                var registerOptions = GRPCCore.CallOptions.defaults
                registerOptions.waitForReady = true
                registerOptions.timeout = .seconds(60)

                var req = Totem_V1_RegisterRequest()
                req.totemID  = totemId.uuidString
                req.host     = totemHost
                req.grpcPort = Int32(totemGRPCPort)
                req.httpPort = Int32(totemHTTPPort)
                let resp = try await stub.register(req, options: registerOptions)
                guard resp.accepted else {
                    logger.error("MothershipRegistrationClient: registration rejected (invalid totem ID?)")
                    return
                }
                logger.info("MothershipRegistrationClient: registered with mothership \(resp.mothershipID)")

                // ── 2. Bidirectional session stream ──────────────────────────
                let (outgoing, continuation) = AsyncStream.makeStream(of: Totem_V1_TotemSessionMessage.self)
                let myTotemId  = totemId
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
                // reconnects. Kept < 60 s to stay inside Seer's active-node window.
                let stalenessSeconds: TimeInterval = 45
                try await withThrowingTaskGroup(of: Void.self) { group in
                  group.addTask { [self] in
                    try await stub.session(
                    options: sessionOptions,
                    requestProducer: { [self] writer in
                        var ping = Totem_V1_TotemSessionMessage()
                        ping.totemID = myTotemId.uuidString
                        ping.payload = .ping(Totem_V1_TotemSessionPing())
                        logger.info("MothershipRegistrationClient: session stream opened — sending initial ping")
                        try await writer.write(ping)
                        logger.info("MothershipRegistrationClient: initial ping sent — stream active")

                        do {
                            for await msg in outgoing {
                                logger.info("MothershipRegistrationClient: → Seer \(payloadName(msg.payload)) [\(msg.correlationID.prefix(8))]")
                                try await writer.write(msg)
                                logger.info("MothershipRegistrationClient: → Seer write complete \(payloadName(msg.payload)) [\(msg.correlationID.prefix(8))]")
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
                                var ping = Totem_V1_TotemSessionMessage()
                                ping.totemID = myTotemId.uuidString
                                ping.payload = .ping(Totem_V1_TotemSessionPing())
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
                                    logger.info("MothershipRegistrationClient: ← Seer request \(pname) [\(msg.correlationID.prefix(8))] — dispatching")
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
                            logger.info("MothershipRegistrationClient: response stream ended cleanly (Seer closed its send side)")
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
                              logger.warning("MothershipRegistrationClient: no message from Seer in \(Int(stalenessSeconds))s — tearing down session to force reconnect")
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
        } catch {
            logger.warning("MothershipRegistrationClient: session ended — \(error)")
        }
    }
}

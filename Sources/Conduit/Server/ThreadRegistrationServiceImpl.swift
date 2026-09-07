import Foundation
import GRPCCore
import GRPCProtobuf

public final class ThreadRegistrationServiceImpl: Thread_V1_ThreadRegistration.SimpleServiceProtocol, Sendable {
    public let registry: any ThreadRegistry
    public let sessionManager: ThreadSessionManager
    public let mothershipId: UUID
    private let logger: any ConduitLogger

    public init(registry: any ThreadRegistry, mothershipId: UUID, sessionManager: ThreadSessionManager, logger: any ConduitLogger) {
        self.registry = registry
        self.mothershipId = mothershipId
        self.sessionManager = sessionManager
        self.logger = logger
    }

    public func register(
        request: Thread_V1_RegisterRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_RegisterResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_RegisterResponse()
            resp.accepted = false
            resp.mothershipID = mothershipId.uuidString
            return resp
        }

        let node = ThreadNode(
            threadId: threadId,
            host: request.host,
            grpcPort: Int(request.grpcPort),
            httpPort: Int(request.httpPort)
        )
        await registry.registerNode(node)
        logger.info("ThreadRegistration", "Registered Thread \(threadId) at \(request.host) grpc:\(request.grpcPort) http:\(request.httpPort)")

        var resp = Thread_V1_RegisterResponse()
        resp.accepted = true
        resp.mothershipID = mothershipId.uuidString
        return resp
    }

    public func heartbeat(
        request: Thread_V1_HeartbeatRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_HeartbeatResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_HeartbeatResponse()
            resp.alive = false
            return resp
        }

        await registry.heartbeatNode(threadId: threadId)

        var resp = Thread_V1_HeartbeatResponse()
        resp.alive = true
        return resp
    }

    public func updateAvailability(
        request: Thread_V1_AvailabilityUpdateRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Thread_V1_AvailabilityUpdateResponse {
        guard let threadId = UUID(uuidString: request.threadID) else {
            var resp = Thread_V1_AvailabilityUpdateResponse()
            resp.acknowledged = false
            return resp
        }

        await registry.updateNodeAvailability(threadId: threadId, accepting: request.acceptingStorage)
        logger.info("ThreadRegistration", "Thread \(threadId) availability → acceptingStorage=\(request.acceptingStorage)")

        var resp = Thread_V1_AvailabilityUpdateResponse()
        resp.acknowledged = true
        return resp
    }

    // MARK: - Bidirectional session

    public func session(
        request: GRPCCore.RPCAsyncSequence<Thread_V1_ThreadSessionMessage, any Swift.Error>,
        response: GRPCCore.RPCWriter<Thread_V1_ThreadSessionMessage>,
        context: GRPCCore.ServerContext
    ) async throws {
        // First message must be a Ping carrying the Thread's UUID.
        var iter = request.makeAsyncIterator()
        guard let first = try await iter.next(),
              case .ping = first.payload,
              let threadId = UUID(uuidString: first.threadID) else { return }

        // Open the managed outgoing channel. The writer task below is the ONLY
        // code that calls response.write(), and it only runs while session() is
        // executing, so the gRPC stream is guaranteed open for every write.
        let outgoing = await sessionManager.openSession(for: threadId)
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
        await sessionManager.closeSession(for: threadId)
        logger.info("ThreadSession", "Session closed for Thread \(threadId)")
    }
}

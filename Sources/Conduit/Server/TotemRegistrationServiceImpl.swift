import Foundation
import GRPCCore
import GRPCProtobuf

public final class TotemRegistrationServiceImpl: Totem_V1_TotemRegistration.SimpleServiceProtocol, Sendable {
    public let registry: any TotemRegistry
    public let sessionManager: TotemSessionManager
    public let mothershipId: UUID
    private let logger: any ConduitLogger

    public init(registry: any TotemRegistry, mothershipId: UUID, sessionManager: TotemSessionManager, logger: any ConduitLogger) {
        self.registry = registry
        self.mothershipId = mothershipId
        self.sessionManager = sessionManager
        self.logger = logger
    }

    public func register(
        request: Totem_V1_RegisterRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_RegisterResponse {
        guard let totemId = UUID(uuidString: request.totemID) else {
            var resp = Totem_V1_RegisterResponse()
            resp.accepted = false
            resp.mothershipID = mothershipId.uuidString
            return resp
        }

        let node = TotemNode(
            totemId: totemId,
            host: request.host,
            grpcPort: Int(request.grpcPort),
            httpPort: Int(request.httpPort)
        )
        await registry.registerNode(node)
        logger.info("TotemRegistration", "Registered Totem \(totemId) at \(request.host) grpc:\(request.grpcPort) http:\(request.httpPort)")

        var resp = Totem_V1_RegisterResponse()
        resp.accepted = true
        resp.mothershipID = mothershipId.uuidString
        return resp
    }

    public func heartbeat(
        request: Totem_V1_HeartbeatRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_HeartbeatResponse {
        guard let totemId = UUID(uuidString: request.totemID) else {
            var resp = Totem_V1_HeartbeatResponse()
            resp.alive = false
            return resp
        }

        await registry.heartbeatNode(totemId: totemId)

        var resp = Totem_V1_HeartbeatResponse()
        resp.alive = true
        return resp
    }

    public func updateAvailability(
        request: Totem_V1_AvailabilityUpdateRequest,
        context: GRPCCore.ServerContext
    ) async throws -> Totem_V1_AvailabilityUpdateResponse {
        guard let totemId = UUID(uuidString: request.totemID) else {
            var resp = Totem_V1_AvailabilityUpdateResponse()
            resp.acknowledged = false
            return resp
        }

        await registry.updateNodeAvailability(totemId: totemId, accepting: request.acceptingStorage)
        logger.info("TotemRegistration", "Totem \(totemId) availability → acceptingStorage=\(request.acceptingStorage)")

        var resp = Totem_V1_AvailabilityUpdateResponse()
        resp.acknowledged = true
        return resp
    }

    // MARK: - Bidirectional session

    public func session(
        request: GRPCCore.RPCAsyncSequence<Totem_V1_TotemSessionMessage, any Swift.Error>,
        response: GRPCCore.RPCWriter<Totem_V1_TotemSessionMessage>,
        context: GRPCCore.ServerContext
    ) async throws {
        // First message must be a Ping carrying the Totem's UUID.
        var iter = request.makeAsyncIterator()
        guard let first = try await iter.next(),
              case .ping = first.payload,
              let totemId = UUID(uuidString: first.totemID) else { return }

        // Open the managed outgoing channel. The writer task below is the ONLY
        // code that calls response.write(), and it only runs while session() is
        // executing, so the gRPC stream is guaranteed open for every write.
        let outgoing = await sessionManager.openSession(for: totemId)
        await registry.heartbeatNode(totemId: totemId)
        logger.info("TotemSession", "Session opened for Totem \(totemId)")

        // Acknowledge the first ping via the managed channel.
        var pong = Totem_V1_TotemSessionMessage()
        pong.correlationID = first.correlationID
        pong.payload = .pong(Totem_V1_TotemSessionPong())
        await sessionManager.send(pong, to: totemId)

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
                    self.logger.warning("TotemSession: writer task error for Totem \(totemId): \(error)")
                }
            }

            // Reader: process messages until Totem closes its send side or errors.
            do {
                while let msg = try await iter.next() {
                    switch msg.payload {
                    case .ping:
                        await registry.heartbeatNode(totemId: totemId)
                        var pong = Totem_V1_TotemSessionMessage()
                        pong.correlationID = msg.correlationID
                        pong.payload = .pong(Totem_V1_TotemSessionPong())
                        await sessionManager.send(pong, to: totemId)
                    case .none:
                        break
                    default:
                        // Any message from the Totem keeps the node alive, not only pings.
                        await registry.heartbeatNode(totemId: totemId)
                        logger.info("TotemSession", "← Totem \(totemId) delivered \(payloadName(msg.payload))")
                        await sessionManager.deliver(msg)
                    }
                }
                logger.info("TotemSession", "Totem \(totemId) closed its send side cleanly")
            } catch {
                logger.warning("TotemSession: reader error from Totem \(totemId): \(error)")
            }

            // Reader done: cancel the writer task (it's blocked on the channel).
            group.cancelAll()
        }

        // Close the session and cancel pending continuations BEFORE returning.
        // This must happen while session() is still on the call stack — the moment
        // session() returns, gRPC marks the stream closed and any write would crash.
        await sessionManager.closeSession(for: totemId)
        logger.info("TotemSession", "Session closed for Totem \(totemId)")
    }
}

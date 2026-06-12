import Foundation
import GRPCCore

public enum TotemSessionError: Error {
    case noSession(UUID)
    case unexpectedPayload
    case timeout
}

/// Manages the per-Totem outgoing message channels and correlates in-flight
/// requests with their responses.
///
/// Instead of storing the raw RPCWriter (which crashes if written to after the
/// gRPC stream is closed), we store an AsyncStream.Continuation.  The session
/// handler owns a writer task that drains the stream and writes to the gRPC
/// response writer while session() is still running — guaranteeing no write
/// ever happens after the handler returns and gRPC marks the stream closed.
public actor TotemSessionManager {

    private let logger: any ConduitLogger

    // Per registered Totem: outgoing message channel drained by the session handler.
    private var channels: [UUID: AsyncStream<Totem_V1_TotemSessionMessage>.Continuation] = [:]

    // In-flight requests: correlationId → continuation awaiting the response.
    private var pending: [String: CheckedContinuation<Totem_V1_TotemSessionMessage, any Error>] = [:]

    // Reverse map so closeSession can cancel all pending for a disconnected Totem.
    private var totemCorrelations: [UUID: Set<String>] = [:]

    public init(logger: any ConduitLogger) {
        self.logger = logger
    }

    // MARK: - Session lifecycle

    /// Opens a managed outgoing channel for a Totem.  Returns the AsyncStream
    /// the session handler's writer task should drain and write to the gRPC stream.
    public func openSession(for totemId: UUID) -> AsyncStream<Totem_V1_TotemSessionMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: Totem_V1_TotemSessionMessage.self)
        channels[totemId] = continuation
        return stream
    }

    /// Finishes the outgoing channel and cancels all in-flight requests for
    /// this Totem.  Must be called BEFORE the session handler returns so that
    /// no writes are attempted after the gRPC stream is closed.
    public func closeSession(for totemId: UUID) {
        channels[totemId]?.finish()
        channels.removeValue(forKey: totemId)
        if let ids = totemCorrelations.removeValue(forKey: totemId) {
            if !ids.isEmpty {
                logger.warning("TotemSession: cancelled \(ids.count) in-flight request(s) for Totem \(totemId)")
            }
            for id in ids {
                pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Enqueues a message for the session handler's writer task (e.g. a Pong).
    public func send(_ message: Totem_V1_TotemSessionMessage, to totemId: UUID) {
        channels[totemId]?.yield(message)
    }

    // MARK: - Request / response

    /// Send a request to a specific Totem and wait for the correlated response.
    /// The message is enqueued synchronously via yield() — no inner Task is
    /// spawned, so the write can never escape past the session handler's lifetime.
    /// A timeout Task is scheduled so the caller never hangs indefinitely if the
    /// Totem is slow or its handler is blocked.
    public func request(
        _ message: Totem_V1_TotemSessionMessage,
        to totemId: UUID,
        timeoutSeconds: Double = 120
    ) async throws -> Totem_V1_TotemSessionMessage {
        guard channels[totemId] != nil else {
            logger.warning("TotemSession: no active session for Totem \(totemId) — dropping \(payloadName(message.payload))")
            throw TotemSessionError.noSession(totemId)
        }
        var msg = message
        let correlationId = UUID().uuidString
        msg.correlationID = correlationId

        logger.info("TotemSession", "→ Totem \(totemId) [\(correlationId.prefix(8))] \(payloadName(message.payload))")

        return try await withCheckedThrowingContinuation { cont in
            pending[correlationId] = cont
            totemCorrelations[totemId, default: []].insert(correlationId)
            channels[totemId]?.yield(msg)

            // Schedule a timeout: if no response arrives within timeoutSeconds,
            // remove the pending entry and resume the caller with .timeout so
            // fanout callers fail fast instead of hanging indefinitely.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self.cancelPending(correlationId: correlationId, totemId: totemId)
            }
        }
    }

    /// Cancels a pending request by correlation ID.  No-ops if the response
    /// already arrived (entry already removed by deliver()).
    private func cancelPending(correlationId: String, totemId: UUID) {
        guard let cont = pending.removeValue(forKey: correlationId) else { return }
        totemCorrelations[totemId]?.remove(correlationId)
        logger.warning("TotemSession: request [\(correlationId.prefix(8))] to Totem \(totemId) timed out")
        cont.resume(throwing: TotemSessionError.timeout)
    }

    /// Deliver an incoming response message to the waiting continuation.
    public func deliver(_ message: Totem_V1_TotemSessionMessage) {
        let id = message.correlationID
        guard let cont = pending.removeValue(forKey: id) else {
            logger.warning("TotemSession: received \(payloadName(message.payload)) with no matching pending request [\(id.prefix(8))]")
            return
        }
        logger.info("TotemSession", "← Response [\(id.prefix(8))] \(payloadName(message.payload))")
        cont.resume(returning: message)
    }
}

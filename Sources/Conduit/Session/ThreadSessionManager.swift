import Foundation
import GRPCCore

public enum ThreadSessionError: Error {
    case noSession(UUID)
    case unexpectedPayload
    case timeout
}

/// Manages the per-Thread outgoing message channels and correlates in-flight
/// requests with their responses.
///
/// Instead of storing the raw RPCWriter (which crashes if written to after the
/// gRPC stream is closed), we store an AsyncStream.Continuation.  The session
/// handler owns a writer task that drains the stream and writes to the gRPC
/// response writer while session() is still running — guaranteeing no write
/// ever happens after the handler returns and gRPC marks the stream closed.
public actor ThreadSessionManager {

    private let logger: any ConduitLogger

    // Per registered Thread: outgoing message channel drained by the session handler.
    private var channels: [UUID: AsyncStream<Thread_V1_ThreadSessionMessage>.Continuation] = [:]

    // In-flight requests: correlationId → continuation awaiting the response.
    private var pending: [String: CheckedContinuation<Thread_V1_ThreadSessionMessage, any Error>] = [:]

    // Reverse map so closeSession can cancel all pending for a disconnected Thread.
    private var threadCorrelations: [UUID: Set<String>] = [:]

    public init(logger: any ConduitLogger) {
        self.logger = logger
    }

    // MARK: - Session lifecycle

    /// Opens a managed outgoing channel for a Thread.  Returns the AsyncStream
    /// the session handler's writer task should drain and write to the gRPC stream.
    public func openSession(for threadId: UUID) -> AsyncStream<Thread_V1_ThreadSessionMessage> {
        let (stream, continuation) = AsyncStream.makeStream(of: Thread_V1_ThreadSessionMessage.self)
        channels[threadId] = continuation
        return stream
    }

    /// Finishes the outgoing channel and cancels all in-flight requests for
    /// this Thread.  Must be called BEFORE the session handler returns so that
    /// no writes are attempted after the gRPC stream is closed.
    public func closeSession(for threadId: UUID) {
        channels[threadId]?.finish()
        channels.removeValue(forKey: threadId)
        if let ids = threadCorrelations.removeValue(forKey: threadId) {
            if !ids.isEmpty {
                logger.warning("ThreadSession: cancelled \(ids.count) in-flight request(s) for Thread \(threadId)")
            }
            for id in ids {
                pending.removeValue(forKey: id)?.resume(throwing: CancellationError())
            }
        }
    }

    /// Enqueues a message for the session handler's writer task (e.g. a Pong).
    public func send(_ message: Thread_V1_ThreadSessionMessage, to threadId: UUID) {
        channels[threadId]?.yield(message)
    }

    // MARK: - Request / response

    /// Send a request to a specific Thread and wait for the correlated response.
    /// The message is enqueued synchronously via yield() — no inner Task is
    /// spawned, so the write can never escape past the session handler's lifetime.
    /// A timeout Task is scheduled so the caller never hangs indefinitely if the
    /// Thread is slow or its handler is blocked.
    public func request(
        _ message: Thread_V1_ThreadSessionMessage,
        to threadId: UUID,
        timeoutSeconds: Double = 120
    ) async throws -> Thread_V1_ThreadSessionMessage {
        guard channels[threadId] != nil else {
            logger.warning("ThreadSession: no active session for Thread \(threadId) — dropping \(payloadName(message.payload))")
            throw ThreadSessionError.noSession(threadId)
        }
        var msg = message
        let correlationId = UUID().uuidString
        msg.correlationID = correlationId

        logger.info("ThreadSession", "→ Thread \(threadId) [\(correlationId.prefix(8))] \(payloadName(message.payload))")

        return try await withCheckedThrowingContinuation { cont in
            pending[correlationId] = cont
            threadCorrelations[threadId, default: []].insert(correlationId)
            channels[threadId]?.yield(msg)

            // Schedule a timeout: if no response arrives within timeoutSeconds,
            // remove the pending entry and resume the caller with .timeout so
            // fanout callers fail fast instead of hanging indefinitely.
            Task {
                try? await Task.sleep(nanoseconds: UInt64(timeoutSeconds * 1_000_000_000))
                await self.cancelPending(correlationId: correlationId, threadId: threadId)
            }
        }
    }

    /// Cancels a pending request by correlation ID.  No-ops if the response
    /// already arrived (entry already removed by deliver()).
    private func cancelPending(correlationId: String, threadId: UUID) {
        guard let cont = pending.removeValue(forKey: correlationId) else { return }
        threadCorrelations[threadId]?.remove(correlationId)
        logger.warning("ThreadSession: request [\(correlationId.prefix(8))] to Thread \(threadId) timed out")
        cont.resume(throwing: ThreadSessionError.timeout)
    }

    /// Deliver an incoming response message to the waiting continuation.
    public func deliver(_ message: Thread_V1_ThreadSessionMessage) {
        let id = message.correlationID
        guard let cont = pending.removeValue(forKey: id) else {
            logger.warning("ThreadSession: received \(payloadName(message.payload)) with no matching pending request [\(id.prefix(8))]")
            return
        }
        logger.info("ThreadSession", "← Response [\(id.prefix(8))] \(payloadName(message.payload))")
        cont.resume(returning: message)
    }
}

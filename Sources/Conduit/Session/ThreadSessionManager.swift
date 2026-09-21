import Foundation
import GRPCCore

public enum ThreadSessionError: Error {
    case noSession(UUID)
    case sessionAlreadyOpen(UUID)
    case unexpectedPayload
    case timeout
}

/// Names one opening of a Thread's session. ``ThreadSessionManager/closeSession(_:)``
/// acts only when the handle's generation is still the live one, so a handler
/// that is tearing down late can never close the session that replaced it.
public struct SessionHandle: Sendable, Hashable {
    public let threadId: UUID
    let generation: UInt64
}

/// Manages the per-Thread outgoing message channels and correlates in-flight
/// requests with their responses.
///
/// Instead of storing the raw RPCWriter (which crashes if written to after the
/// gRPC stream is closed), we store an AsyncStream.Continuation.  The session
/// handler owns a writer task that drains the stream and writes to the gRPC
/// response writer while session() is still running — guaranteeing no write
/// ever happens after the handler returns and gRPC marks the stream closed.
///
/// One session per Thread: a second `openSession` for an id that is already
/// live throws rather than silently replacing the channel underneath the
/// handler that owns it.
public actor ThreadSessionManager {

    private let logger: any ConduitLogger

    /// A Thread's live outgoing channel, stamped with the generation that opened it.
    private struct Channel {
        let generation: UInt64
        let continuation: AsyncStream<Thread_V1_ThreadSessionMessage>.Continuation
    }

    // Per registered Thread: outgoing message channel drained by the session handler.
    private var channels: [UUID: Channel] = [:]

    // Monotonic stamp handed out by openSession; never reused within a process.
    private var nextGeneration: UInt64 = 0

    // In-flight requests: correlationId → continuation awaiting the response.
    private var pending: [String: CheckedContinuation<Thread_V1_ThreadSessionMessage, any Error>] = [:]

    // Reverse map so closeSession can cancel all pending for a disconnected Thread.
    private var threadCorrelations: [UUID: Set<String>] = [:]

    public init(logger: any ConduitLogger) {
        self.logger = logger
    }

    // MARK: - Session lifecycle

    /// Opens a managed outgoing channel for a Thread.  Returns the handle the
    /// session handler must close with, and the AsyncStream its writer task
    /// should drain and write to the gRPC stream.
    ///
    /// - Throws: ``ThreadSessionError/sessionAlreadyOpen(_:)`` if this Thread
    ///   already has a live channel.
    public func openSession(
        for threadId: UUID
    ) throws -> (handle: SessionHandle, outgoing: AsyncStream<Thread_V1_ThreadSessionMessage>) {
        guard channels[threadId] == nil else {
            throw ThreadSessionError.sessionAlreadyOpen(threadId)
        }
        nextGeneration += 1
        let (stream, continuation) = AsyncStream.makeStream(of: Thread_V1_ThreadSessionMessage.self)
        channels[threadId] = Channel(generation: nextGeneration, continuation: continuation)
        return (SessionHandle(threadId: threadId, generation: nextGeneration), stream)
    }

    /// Finishes the outgoing channel and cancels all in-flight requests for
    /// this Thread.  Must be called BEFORE the session handler returns so that
    /// no writes are attempted after the gRPC stream is closed.
    ///
    /// A handle whose generation is no longer the live one (its session was
    /// already closed, and possibly reopened by a newer handler) is ignored.
    public func closeSession(_ handle: SessionHandle) {
        let threadId = handle.threadId
        guard channels[threadId]?.generation == handle.generation else {
            logger.warning("ThreadSession: ignoring close from a stale handler for Thread \(threadId)")
            return
        }
        channels[threadId]?.continuation.finish()
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

    /// Whether this Thread currently has a live outgoing channel.
    public func hasSession(for threadId: UUID) -> Bool {
        channels[threadId] != nil
    }

    /// Enqueues a message for the session handler's writer task (e.g. a Pong).
    public func send(_ message: Thread_V1_ThreadSessionMessage, to threadId: UUID) {
        channels[threadId]?.continuation.yield(message)
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
            channels[threadId]?.continuation.yield(msg)

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

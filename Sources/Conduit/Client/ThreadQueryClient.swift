import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor ThreadQueryClient: Sendable {

    private let sessionManager: ThreadSessionManager

    public init(sessionManager: ThreadSessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Helpers

    /// Per-RPC timeouts, not the session manager's blanket 120 s: a wedged
    /// node otherwise stalls every fan-out — i.e. every chat turn — for two
    /// minutes before silently degrading. Interactive reads fail fast; index
    /// keeps the long budget because it legitimately awaits embedding.
    private enum Timeout {
        static let interactive: Double = 30   // search, graph, stats, updates, documents
        static let library: Double = 90       // whole-group pages can be large
        static let index: Double = 120        // embedding round-trips per item
    }

    private func send(
        _ build: (inout Thread_V1_ThreadSessionMessage) -> Void,
        to thread: ThreadNode,
        timeoutSeconds: Double
    ) async throws -> Thread_V1_ThreadSessionMessage {
        var msg = Thread_V1_ThreadSessionMessage()
        build(&msg)
        return try await sessionManager.request(msg, to: thread.threadId, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Search / Index / Remove

    public func search(_ request: Thread_V1_ThreadSearchRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadSearchResponse {
        let resp = try await send({ $0.payload = .searchRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .searchResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    public func index(_ request: Thread_V1_ThreadIndexRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadIndexResponse {
        let resp = try await send({ $0.payload = .indexRequest(request) }, to: thread, timeoutSeconds: Timeout.index)
        guard case .indexResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    public func remove(_ request: Thread_V1_ThreadRemoveRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadRemoveResponse {
        let resp = try await send({ $0.payload = .removeRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .removeResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Library

    public func library(_ request: Thread_V1_ThreadLibraryRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadLibraryResponse {
        let resp = try await send({ $0.payload = .libraryRequest(request) }, to: thread, timeoutSeconds: Timeout.library)
        guard case .libraryResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    /// Full document content by id (partition texts in stored order).
    public func documents(_ request: Thread_V1_ThreadDocumentsRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadDocumentsResponse {
        let resp = try await send({ $0.payload = .documentsRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .documentsResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Graph

    public func graph(_ request: Thread_V1_ThreadGraphQueryRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadGraphQueryResponse {
        let resp = try await send({ $0.payload = .graphRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .graphResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Update

    public func updateGroup(_ request: Thread_V1_ThreadUpdateGroupRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadUpdateGroupResponse {
        let resp = try await send({ $0.payload = .updateGroupRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .updateGroupResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    public func updateDocument(_ request: Thread_V1_ThreadUpdateDocumentRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadUpdateDocumentResponse {
        let resp = try await send({ $0.payload = .updateDocumentRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .updateDocumentResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }

    public func stats(_ request: Thread_V1_ThreadStatsRequest, thread: ThreadNode) async throws -> Thread_V1_ThreadStatsResponse {
        let resp = try await send({ $0.payload = .statsRequest(request) }, to: thread, timeoutSeconds: Timeout.interactive)
        guard case .statsResponse(let r) = resp.payload else { throw ThreadSessionError.unexpectedPayload }
        return r
    }
}

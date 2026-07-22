import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor TotemQueryClient: Sendable {

    private let sessionManager: TotemSessionManager

    public init(sessionManager: TotemSessionManager) {
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
        _ build: (inout Totem_V1_TotemSessionMessage) -> Void,
        to totem: TotemNode,
        timeoutSeconds: Double
    ) async throws -> Totem_V1_TotemSessionMessage {
        var msg = Totem_V1_TotemSessionMessage()
        build(&msg)
        return try await sessionManager.request(msg, to: totem.totemId, timeoutSeconds: timeoutSeconds)
    }

    // MARK: - Search / Index / Remove

    public func search(_ request: Totem_V1_TotemSearchRequest, totem: TotemNode) async throws -> Totem_V1_TotemSearchResponse {
        let resp = try await send({ $0.payload = .searchRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .searchResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func index(_ request: Totem_V1_TotemIndexRequest, totem: TotemNode) async throws -> Totem_V1_TotemIndexResponse {
        let resp = try await send({ $0.payload = .indexRequest(request) }, to: totem, timeoutSeconds: Timeout.index)
        guard case .indexResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func remove(_ request: Totem_V1_TotemRemoveRequest, totem: TotemNode) async throws -> Totem_V1_TotemRemoveResponse {
        let resp = try await send({ $0.payload = .removeRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .removeResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Library

    public func library(_ request: Totem_V1_TotemLibraryRequest, totem: TotemNode) async throws -> Totem_V1_TotemLibraryResponse {
        let resp = try await send({ $0.payload = .libraryRequest(request) }, to: totem, timeoutSeconds: Timeout.library)
        guard case .libraryResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    /// Full document content by id (partition texts in stored order).
    public func documents(_ request: Totem_V1_TotemDocumentsRequest, totem: TotemNode) async throws -> Totem_V1_TotemDocumentsResponse {
        let resp = try await send({ $0.payload = .documentsRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .documentsResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Graph

    public func graph(_ request: Totem_V1_TotemGraphQueryRequest, totem: TotemNode) async throws -> Totem_V1_TotemGraphQueryResponse {
        let resp = try await send({ $0.payload = .graphRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .graphResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Update

    public func updateGroup(_ request: Totem_V1_TotemUpdateGroupRequest, totem: TotemNode) async throws -> Totem_V1_TotemUpdateGroupResponse {
        let resp = try await send({ $0.payload = .updateGroupRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .updateGroupResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func updateDocument(_ request: Totem_V1_TotemUpdateDocumentRequest, totem: TotemNode) async throws -> Totem_V1_TotemUpdateDocumentResponse {
        let resp = try await send({ $0.payload = .updateDocumentRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .updateDocumentResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func stats(_ request: Totem_V1_TotemStatsRequest, totem: TotemNode) async throws -> Totem_V1_TotemStatsResponse {
        let resp = try await send({ $0.payload = .statsRequest(request) }, to: totem, timeoutSeconds: Timeout.interactive)
        guard case .statsResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }
}

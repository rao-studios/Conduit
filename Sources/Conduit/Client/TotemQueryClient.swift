import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

public actor TotemQueryClient: Sendable {

    private let sessionManager: TotemSessionManager

    public init(sessionManager: TotemSessionManager) {
        self.sessionManager = sessionManager
    }

    // MARK: - Helpers

    private func send(
        _ build: (inout Totem_V1_TotemSessionMessage) -> Void,
        to totem: TotemNode
    ) async throws -> Totem_V1_TotemSessionMessage {
        var msg = Totem_V1_TotemSessionMessage()
        build(&msg)
        return try await sessionManager.request(msg, to: totem.totemId)
    }

    // MARK: - Search / Index / Remove

    public func search(_ request: Totem_V1_TotemSearchRequest, totem: TotemNode) async throws -> Totem_V1_TotemSearchResponse {
        let resp = try await send({ $0.payload = .searchRequest(request) }, to: totem)
        guard case .searchResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func index(_ request: Totem_V1_TotemIndexRequest, totem: TotemNode) async throws -> Totem_V1_TotemIndexResponse {
        let resp = try await send({ $0.payload = .indexRequest(request) }, to: totem)
        guard case .indexResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func remove(_ request: Totem_V1_TotemRemoveRequest, totem: TotemNode) async throws -> Totem_V1_TotemRemoveResponse {
        let resp = try await send({ $0.payload = .removeRequest(request) }, to: totem)
        guard case .removeResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Library

    public func library(_ request: Totem_V1_TotemLibraryRequest, totem: TotemNode) async throws -> Totem_V1_TotemLibraryResponse {
        let resp = try await send({ $0.payload = .libraryRequest(request) }, to: totem)
        guard case .libraryResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - HNSW

    public func hnswStats(_ request: Totem_V1_TotemHNSWStatsRequest, totem: TotemNode) async throws -> Totem_V1_TotemHNSWStatsResponse {
        let resp = try await send({ $0.payload = .hnswStatsRequest(request) }, to: totem)
        guard case .hnswStatsResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func hnswGraph(_ request: Totem_V1_TotemHNSWGraphRequest, totem: TotemNode) async throws -> Totem_V1_TotemHNSWGraphResponse {
        let resp = try await send({ $0.payload = .hnswGraphRequest(request) }, to: totem)
        guard case .hnswGraphResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func hnswNodeBatch(_ request: Totem_V1_TotemHNSWNodeBatchRequest, totem: TotemNode) async throws -> Totem_V1_TotemHNSWNodeBatchResponse {
        let resp = try await send({ $0.payload = .hnswNodeBatchRequest(request) }, to: totem)
        guard case .hnswNodeBatchResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func hnswNode(_ request: Totem_V1_TotemHNSWNodeRequest, totem: TotemNode) async throws -> Totem_V1_TotemHNSWNodeResponse {
        let resp = try await send({ $0.payload = .hnswNodeRequest(request) }, to: totem)
        guard case .hnswNodeResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func hnswDeleteNode(_ request: Totem_V1_TotemHNSWDeleteNodeRequest, totem: TotemNode) async throws -> Totem_V1_TotemHNSWDeleteNodeResponse {
        let resp = try await send({ $0.payload = .hnswDeleteNodeRequest(request) }, to: totem)
        guard case .hnswDeleteNodeResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    // MARK: - Update

    public func updateGroup(_ request: Totem_V1_TotemUpdateGroupRequest, totem: TotemNode) async throws -> Totem_V1_TotemUpdateGroupResponse {
        let resp = try await send({ $0.payload = .updateGroupRequest(request) }, to: totem)
        guard case .updateGroupResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func updateDocument(_ request: Totem_V1_TotemUpdateDocumentRequest, totem: TotemNode) async throws -> Totem_V1_TotemUpdateDocumentResponse {
        let resp = try await send({ $0.payload = .updateDocumentRequest(request) }, to: totem)
        guard case .updateDocumentResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }

    public func stats(_ request: Totem_V1_TotemStatsRequest, totem: TotemNode) async throws -> Totem_V1_TotemStatsResponse {
        let resp = try await send({ $0.payload = .statsRequest(request) }, to: totem)
        guard case .statsResponse(let r) = resp.payload else { throw TotemSessionError.unexpectedPayload }
        return r
    }
}

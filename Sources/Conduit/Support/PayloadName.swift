/// Human-readable name for a session payload, used in logs on both sides of
/// the stream.
public func payloadName(_ payload: Totem_V1_TotemSessionMessage.OneOf_Payload?) -> String {
    switch payload {
    case .ping:                  return "ping"
    case .pong:                  return "pong"
    case .searchRequest:         return "searchRequest"
    case .searchResponse:        return "searchResponse"
    case .indexRequest:          return "indexRequest"
    case .indexResponse:         return "indexResponse"
    case .removeRequest:         return "removeRequest"
    case .removeResponse:        return "removeResponse"
    case .libraryRequest:        return "libraryRequest"
    case .libraryResponse:       return "libraryResponse"
    case .hnswStatsRequest:      return "hnswStatsRequest"
    case .hnswStatsResponse:     return "hnswStatsResponse"
    case .hnswGraphRequest:      return "hnswGraphRequest"
    case .hnswGraphResponse:     return "hnswGraphResponse"
    case .hnswNodeBatchRequest:  return "hnswNodeBatchRequest"
    case .hnswNodeBatchResponse: return "hnswNodeBatchResponse"
    case .hnswNodeRequest:       return "hnswNodeRequest"
    case .hnswNodeResponse:      return "hnswNodeResponse"
    case .hnswDeleteNodeRequest:   return "hnswDeleteNodeRequest"
    case .hnswDeleteNodeResponse:  return "hnswDeleteNodeResponse"
    case .updateGroupRequest:      return "updateGroupRequest"
    case .updateGroupResponse:     return "updateGroupResponse"
    case .updateDocumentRequest:   return "updateDocumentRequest"
    case .updateDocumentResponse:  return "updateDocumentResponse"
    case .statsRequest:            return "statsRequest"
    case .statsResponse:           return "statsResponse"
    case .none:                    return "none"
    }
}

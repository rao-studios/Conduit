/// Human-readable name for a session payload, used in logs on both sides of
/// the stream.
public func payloadName(_ payload: Thread_V1_ThreadSessionMessage.OneOf_Payload?) -> String {
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
    case .graphRequest:          return "graphRequest"
    case .graphResponse:         return "graphResponse"
    case .updateGroupRequest:      return "updateGroupRequest"
    case .updateGroupResponse:     return "updateGroupResponse"
    case .updateDocumentRequest:   return "updateDocumentRequest"
    case .updateDocumentResponse:  return "updateDocumentResponse"
    case .statsRequest:            return "statsRequest"
    case .statsResponse:           return "statsResponse"
    case .documentsRequest:        return "documentsRequest"
    case .documentsResponse:       return "documentsResponse"
    case .none:                    return "none"
    }
}

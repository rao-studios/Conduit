/// Handles fan-out requests arriving on the bidirectional session stream and
/// returns the correlated response message (nil if the payload is unsupported).
public protocol SessionRequestHandling: Sendable {
    func handle(_ msg: Totem_V1_TotemSessionMessage) async -> Totem_V1_TotemSessionMessage?
}

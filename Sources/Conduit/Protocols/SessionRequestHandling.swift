/// Handles fan-out requests arriving on the bidirectional session stream and
/// returns the correlated response message (nil if the payload is unsupported).
public protocol SessionRequestHandling: Sendable {
    func handle(_ msg: Thread_V1_ThreadSessionMessage) async -> Thread_V1_ThreadSessionMessage?
}

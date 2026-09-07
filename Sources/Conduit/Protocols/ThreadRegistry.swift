import Foundation

/// Node registry maintained by the mothership. ThreadRegistrationServiceImpl
/// writes registration, heartbeat, and availability updates through this seam.
public protocol ThreadRegistry: Sendable {
    func registerNode(_ node: ThreadNode) async
    func heartbeatNode(threadId: UUID) async
    func updateNodeAvailability(threadId: UUID, accepting: Bool) async
}

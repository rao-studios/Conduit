import Foundation

/// Node registry maintained by the mothership. TotemRegistrationServiceImpl
/// writes registration, heartbeat, and availability updates through this seam.
public protocol TotemRegistry: Sendable {
    func registerNode(_ node: TotemNode) async
    func heartbeatNode(totemId: UUID) async
    func updateNodeAvailability(totemId: UUID, accepting: Bool) async
}

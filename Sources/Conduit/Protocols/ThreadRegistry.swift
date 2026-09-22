import Foundation

/// Node registry maintained by the mothership. ThreadRegistrationServiceImpl
/// writes registration, heartbeat, and availability updates through this seam.
public protocol ThreadRegistry: Sendable {
    func registerNode(_ node: ThreadNode) async
    func heartbeatNode(threadId: UUID) async
    func updateNodeAvailability(threadId: UUID, accepting: Bool) async

    /// The node registered under `threadId`, active or not. A shared stack's
    /// mothership reads it to check that an RPC comes from the app the node
    /// belongs to. The default knows no nodes, so a registry that doesn't
    /// implement it refuses every app-scoped session rather than guessing.
    func registeredNode(threadId: UUID) async -> ThreadNode?
}

public extension ThreadRegistry {
    func registeredNode(threadId: UUID) async -> ThreadNode? { nil }
}

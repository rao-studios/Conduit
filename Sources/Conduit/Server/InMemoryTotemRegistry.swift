import Foundation

/// In-memory ``TotemRegistry`` for destinations that don't persist node state
/// (e.g. the Fleet client). Tracks connected Totems and broadcasts the active
/// list on every change so a UI can react.
public actor InMemoryTotemRegistry: TotemRegistry {

    private var nodes: [UUID: TotemNode] = [:]
    private var subscribers: [UUID: AsyncStream<[TotemNode]>.Continuation] = [:]

    public init() {}

    // MARK: - TotemRegistry

    public func registerNode(_ node: TotemNode) async {
        var node = node
        node.lastSeen = .now
        nodes[node.totemId] = node
        broadcast()
    }

    public func heartbeatNode(totemId: UUID) async {
        guard var node = nodes[totemId] else { return }
        node.lastSeen = .now
        nodes[totemId] = node
        broadcast()
    }

    public func updateNodeAvailability(totemId: UUID, accepting: Bool) async {
        guard var node = nodes[totemId] else { return }
        node.acceptingStorage = accepting
        nodes[totemId] = node
        broadcast()
    }

    // MARK: - Reads

    /// Totems seen recently enough to be considered connected.
    public var activeNodes: [TotemNode] {
        nodes.values
            .filter(\.isActive)
            .sorted { $0.totemId.uuidString < $1.totemId.uuidString }
    }

    public func node(_ id: UUID) -> TotemNode? { nodes[id] }

    /// Emits the active-node list now and on every registry change.
    public func changes() -> AsyncStream<[TotemNode]> {
        let id = UUID()
        return AsyncStream { continuation in
            subscribers[id] = continuation
            continuation.yield(activeNodes)
            continuation.onTermination = { [weak self] _ in
                Task { await self?.removeSubscriber(id) }
            }
        }
    }

    private func removeSubscriber(_ id: UUID) {
        subscribers[id] = nil
    }

    private func broadcast() {
        let active = activeNodes
        for continuation in subscribers.values { continuation.yield(active) }
    }
}

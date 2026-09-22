import Foundation

/// In-memory ``ThreadRegistry`` for destinations that don't persist node state
/// (e.g. the Fleet client). Tracks connected Threads and broadcasts the active
/// list on every change so a UI can react.
public actor InMemoryThreadRegistry: ThreadRegistry {

    private var nodes: [UUID: ThreadNode] = [:]
    private var subscribers: [UUID: AsyncStream<[ThreadNode]>.Continuation] = [:]

    public init() {}

    // MARK: - ThreadRegistry

    public func registerNode(_ node: ThreadNode) async {
        var node = node
        node.lastSeen = .now
        nodes[node.threadId] = node
        broadcast()
    }

    public func heartbeatNode(threadId: UUID) async {
        guard var node = nodes[threadId] else { return }
        // heartbeatNode fires on EVERY session message; broadcasting (a full
        // filter+sort fanned out to all subscribers) only makes sense when a
        // node's active state actually flips, not per message.
        let wasActive = node.isActive
        node.lastSeen = .now
        nodes[threadId] = node
        if !wasActive { broadcast() }
    }

    public func updateNodeAvailability(threadId: UUID, accepting: Bool) async {
        guard var node = nodes[threadId] else { return }
        node.acceptingStorage = accepting
        nodes[threadId] = node
        broadcast()
    }

    public func registeredNode(threadId: UUID) async -> ThreadNode? {
        nodes[threadId]
    }

    // MARK: - Reads

    /// Threads seen recently enough to be considered connected.
    public var activeNodes: [ThreadNode] {
        nodes.values
            .filter(\.isActive)
            .sorted { $0.threadId.uuidString < $1.threadId.uuidString }
    }

    public func node(_ id: UUID) -> ThreadNode? { nodes[id] }

    /// Emits the active-node list now and on every registry change.
    public func changes() -> AsyncStream<[ThreadNode]> {
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

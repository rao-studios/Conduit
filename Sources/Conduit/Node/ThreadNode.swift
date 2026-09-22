import Foundation

public struct ThreadNode: Sendable {
    public let threadId: UUID
    public var host: String
    public let grpcPort: Int
    public let httpPort: Int
    public var lastSeen: Date
    public var acceptingStorage: Bool
    /// The app this node belongs to on a shared ~/.rao stack — `"ambient"`,
    /// `"craft"`, `"veil"` — taken from the stack secret it registered with,
    /// never from anything the node says about itself. Nil on a single-app or
    /// open mothership, where every node belongs to the one caller.
    public let app: String?

    public init(threadId: UUID, host: String, grpcPort: Int, httpPort: Int,
                lastSeen: Date = .now, acceptingStorage: Bool = true, app: String? = nil) {
        self.threadId = threadId
        self.host = host
        self.grpcPort = grpcPort
        self.httpPort = httpPort
        self.lastSeen = lastSeen
        self.acceptingStorage = acceptingStorage
        self.app = app
    }

    public var isActive: Bool {
        Date().timeIntervalSince(lastSeen) < 60
    }
}

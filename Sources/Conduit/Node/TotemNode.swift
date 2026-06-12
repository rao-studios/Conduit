import Foundation

public struct TotemNode: Sendable {
    public let totemId: UUID
    public var host: String
    public let grpcPort: Int
    public let httpPort: Int
    public var lastSeen: Date
    public var acceptingStorage: Bool

    public init(totemId: UUID, host: String, grpcPort: Int, httpPort: Int,
                lastSeen: Date = .now, acceptingStorage: Bool = true) {
        self.totemId = totemId
        self.host = host
        self.grpcPort = grpcPort
        self.httpPort = httpPort
        self.lastSeen = lastSeen
        self.acceptingStorage = acceptingStorage
    }

    public var isActive: Bool {
        Date().timeIntervalSince(lastSeen) < 60
    }
}

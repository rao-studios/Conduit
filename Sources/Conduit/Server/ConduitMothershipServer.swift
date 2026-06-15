import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Reusable mothership gRPC server. Binds the `TotemRegistration` service so any
/// destination (Seer, Fleet, …) can accept Totem connections and their session
/// streams without re-writing the NIO bootstrap.
///
/// Generalizes Seer's `SeerGRPCServer` — a consumer supplies a ``TotemRegistry``,
/// a ``TotemSessionManager``, and a ``ConduitLogger``.
public actor ConduitMothershipServer {

    private let registry: any TotemRegistry
    private let mothershipId: UUID
    private let sessionManager: TotemSessionManager
    private let logger: any ConduitLogger
    private var serverTask: Task<Void, Error>?

    public init(
        registry: any TotemRegistry,
        mothershipId: UUID,
        sessionManager: TotemSessionManager,
        logger: any ConduitLogger
    ) {
        self.registry = registry
        self.mothershipId = mothershipId
        self.sessionManager = sessionManager
        self.logger = logger
    }

    public var isRunning: Bool { serverTask != nil }

    /// Start listening on `port`. No-op if already running.
    public func start(port: Int) {
        guard serverTask == nil else { return }
        let service = TotemRegistrationServiceImpl(
            registry: registry, mothershipId: mothershipId,
            sessionManager: sessionManager, logger: logger)
        let logger = self.logger
        serverTask = Task {
            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .ipv4(host: "0.0.0.0", port: port),
                    transportSecurity: .plaintext,
                    config: .defaults {
                        $0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024
                        // Send keepalive PINGs to detect dead Totem connections,
                        // and permit the client's keepalive (its 15 s interval is
                        // above this minimum, so it won't be struck off).
                        $0.connection.keepalive.time = .seconds(15)
                        $0.connection.keepalive.timeout = .seconds(10)
                        $0.connection.keepalive.clientBehavior.allowWithoutCalls = true
                        $0.connection.keepalive.clientBehavior.minPingIntervalWithoutCalls = .seconds(10)
                    }
                ),
                services: [service]
            )
            logger.info("ConduitMothershipServer", "gRPC server listening on port \(port)")
            try await server.serve()
        }
    }

    public func stop() {
        serverTask?.cancel()
        serverTask = nil
    }
}

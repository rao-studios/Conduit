import Foundation
import GRPCCore
import GRPCNIOTransportHTTP2

/// Reusable mothership gRPC server. Binds the `ThreadRegistration` service so any
/// destination (Sewn, Fleet, …) can accept Thread connections and their session
/// streams without re-writing the NIO bootstrap.
///
/// Generalizes Sewn's `SewnGRPCServer` — a consumer supplies a ``ThreadRegistry``,
/// a ``ThreadSessionManager``, a ``ConduitLogger`` and, optionally, server
/// interceptors applied to every RPC (e.g. ``StackSecretServerInterceptor``
/// in Ambient's local stack).
public actor ConduitMothershipServer {

    private let registry: any ThreadRegistry
    private let mothershipId: UUID
    private let sessionManager: ThreadSessionManager
    private let logger: any ConduitLogger
    private let interceptors: [any ServerInterceptor]
    private var serverTask: Task<Void, Error>?

    public init(
        registry: any ThreadRegistry,
        mothershipId: UUID,
        sessionManager: ThreadSessionManager,
        logger: any ConduitLogger,
        interceptors: [any ServerInterceptor] = []
    ) {
        self.registry = registry
        self.mothershipId = mothershipId
        self.sessionManager = sessionManager
        self.logger = logger
        self.interceptors = interceptors
    }

    public var isRunning: Bool { serverTask != nil }

    /// Start listening on `port`. No-op if already running.
    public func start(port: Int) {
        guard serverTask == nil else { return }
        let service = ThreadRegistrationServiceImpl(
            registry: registry, mothershipId: mothershipId,
            sessionManager: sessionManager, logger: logger)
        let logger = self.logger
        let interceptors = self.interceptors
        serverTask = Task {
            let server = GRPCServer(
                transport: .http2NIOPosix(
                    address: .ipv4(host: "0.0.0.0", port: port),
                    transportSecurity: .plaintext,
                    config: .defaults {
                        $0.rpc.maxRequestPayloadSize = 100 * 1024 * 1024
                        // Send keepalive PINGs to detect dead Thread connections,
                        // and permit the client's keepalive (its 15 s interval is
                        // above this minimum, so it won't be struck off).
                        $0.connection.keepalive.time = .seconds(15)
                        $0.connection.keepalive.timeout = .seconds(10)
                        $0.connection.keepalive.clientBehavior.allowWithoutCalls = true
                        $0.connection.keepalive.clientBehavior.minPingIntervalWithoutCalls = .seconds(10)
                        // The big payloads (index/search/library responses, up to
                        // the 100 MB cap above) arrive client→server on the bidi
                        // session stream — and the server's DEFAULT receive window
                        // is 64 KiB, capping throughput at ~window/RTT and
                        // producing congestion-like throttling on every large
                        // push. Open the window and fatten frames to match.
                        $0.http2.targetWindowSize = 16 * 1024 * 1024
                        $0.http2.maxFrameSize = 1 << 20
                        // Session payloads are text-heavy (embeddings never cross
                        // the wire) — accept gzip from nodes.
                        $0.compression.enabledAlgorithms = [.gzip, .none]
                    }
                ),
                services: [service],
                interceptors: interceptors
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

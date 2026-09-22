//
//  TestSupport.swift
//  ConduitTests
//
//  Shared scaffolding: a logger that keeps what Conduit said, a mothership on
//  grpc-swift's in-process transport, and a poll-until helper for the moments
//  a test must let the server finish tearing something down.
//

import Foundation
import GRPCCore
import GRPCInProcessTransport
import XCTest
@testable import Conduit

/// `ConduitLogger` that records every line so a test can assert on what was
/// said — and, for the stack secret, on what was not.
final class RecordingLogger: ConduitLogger, @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [(level: String, message: String)] = []

    /// Every line, any level.
    var lines: [String] { lock.withLock { entries.map(\.message) } }
    var warnings: [String] { lock.withLock { entries.filter { $0.level == "warning" }.map(\.message) } }

    func debug(_ label: String?, _ message: String)   { record("debug", message) }
    func info(_ label: String?, _ message: String)    { record("info", message) }
    func warning(_ label: String?, _ message: String) { record("warning", message) }
    func error(_ label: String?, _ message: String)   { record("error", message) }

    private func record(_ level: String, _ message: String) {
        lock.withLock { entries.append((level, message)) }
    }
}

/// Thread-safe box for a value a `@Sendable` stub hands back to its test.
final class Box<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value

    init(_ value: Value) { stored = value }

    var value: Value {
        get { lock.withLock { stored } }
        set { lock.withLock { stored = newValue } }
    }
}

/// A mothership (``ThreadRegistrationServiceImpl`` behind a `GRPCServer`) on
/// the in-process transport, with a client bound to it. `run` serves for the
/// duration of `body`, then shuts both ends down gracefully.
struct InProcessMothership {
    let logger: RecordingLogger
    let registry = InMemoryThreadRegistry()
    let sessionManager: ThreadSessionManager
    let mothershipId = UUID()

    init(logger: RecordingLogger = RecordingLogger()) {
        self.logger = logger
        self.sessionManager = ThreadSessionManager(logger: logger)
    }

    typealias Stub = Thread_V1_ThreadRegistration.Client<InProcessTransport.Client>

    func run<Result: Sendable>(
        serverInterceptors: [any ServerInterceptor] = [],
        clientInterceptors: [any ClientInterceptor] = [],
        callerResolver: StackSecretResolver? = nil,
        _ body: (Stub) async throws -> Result
    ) async throws -> Result {
        let transport = InProcessTransport()
        let service = ThreadRegistrationServiceImpl(
            registry: registry, mothershipId: mothershipId,
            sessionManager: sessionManager, logger: logger,
            callerResolver: callerResolver)
        let server = GRPCServer(transport: transport.server, services: [service], interceptors: serverInterceptors)
        let client = GRPCClient(transport: transport.client, interceptors: clientInterceptors)

        return try await withThrowingTaskGroup(of: Void.self, returning: Result.self) { group in
            group.addTask { try await server.serve() }
            group.addTask { try await client.runConnections() }
            // Both ends queue work that arrives before they are running, so
            // `body` may issue its first RPC straight away.
            defer {
                client.beginGracefulShutdown()
                server.beginGracefulShutdown()
            }
            return try await body(Stub(wrapping: client))
        }
    }
}

/// Polls `condition` until it holds or `timeout` passes; returns whether it held.
func waitUntil(
    timeout: Duration = .seconds(2),
    _ condition: () async -> Bool
) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

extension Thread_V1_ThreadSessionMessage {
    /// The first message of every session: a ping naming the Thread.
    static func ping(threadId: UUID, correlationId: String = UUID().uuidString) -> Self {
        var msg = Thread_V1_ThreadSessionMessage()
        msg.threadID = threadId.uuidString
        msg.correlationID = correlationId
        msg.payload = .ping(Thread_V1_ThreadSessionPing())
        return msg
    }
}

extension Thread_V1_RegisterRequest {
    static func sample(threadId: UUID = UUID()) -> Self {
        var req = Thread_V1_RegisterRequest()
        req.threadID = threadId.uuidString
        req.host = "127.0.0.1"
        req.grpcPort = 47001
        req.httpPort = 47002
        return req
    }
}

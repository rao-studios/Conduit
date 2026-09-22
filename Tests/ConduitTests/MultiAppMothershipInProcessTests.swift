//
//  MultiAppMothershipInProcessTests.swift
//  ConduitTests
//
//  One mothership, several apps' Threads: each app's secret registers its
//  own nodes, and no app can re-register, heartbeat, flip, or hold the
//  session of another app's node.
//

import Foundation
import GRPCCore
import XCTest
@testable import Conduit

final class MultiAppMothershipInProcessTests: XCTestCase {

    private let secrets = ["ambient-secret": "ambient", "craft-secret": "craft"]
    private var resolver: StackSecretResolver {
        let secrets = self.secrets
        return { secrets[$0] }
    }


    private func metadata(_ secret: String) -> Metadata { [StackSecretMetadata.key: .string(secret)] }

    func testEachAppsSecretRegistersItsNodeUnderThatApp() async throws {
        let mothership = InProcessMothership()
        let ambientNode = UUID()
        let craftNode = UUID()
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver, logger: mothership.logger),
            callerResolver: resolver
        ) { stub in
            let first = try await stub.register(.sample(threadId: ambientNode), metadata: metadata("ambient-secret"))
            let second = try await stub.register(.sample(threadId: craftNode), metadata: metadata("craft-secret"))
            XCTAssertTrue(first.accepted)
            XCTAssertTrue(second.accepted)
        }
        let ambient = await mothership.registry.node(ambientNode)
        let craft = await mothership.registry.node(craftNode)
        XCTAssertEqual(ambient?.app, "ambient")
        XCTAssertEqual(craft?.app, "craft")
    }

    func testAnUnknownSecretIsUnauthenticatedAndNeverLogged() async throws {
        let mothership = InProcessMothership()
        let guess = "guess-7d1e"
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver, logger: mothership.logger),
            callerResolver: resolver
        ) { stub in
            do {
                _ = try await stub.register(.sample(), metadata: metadata(guess))
                XCTFail("expected UNAUTHENTICATED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .unauthenticated)
            }
        }
        XCTAssertFalse(mothership.logger.lines.contains { $0.contains(guess) })
    }

    func testAnotherAppCannotReRegisterANode() async throws {
        let mothership = InProcessMothership()
        let node = UUID()
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver),
            callerResolver: resolver
        ) { stub in
            _ = try await stub.register(.sample(threadId: node), metadata: metadata("ambient-secret"))
            do {
                _ = try await stub.register(.sample(threadId: node), metadata: metadata("craft-secret"))
                XCTFail("expected PERMISSION_DENIED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
            // The owner may re-register (a restart).
            let again = try await stub.register(.sample(threadId: node), metadata: metadata("ambient-secret"))
            XCTAssertTrue(again.accepted)
        }
        let owner = await mothership.registry.node(node)?.app
        XCTAssertEqual(owner, "ambient")
    }

    func testAnotherAppCannotHeartbeatOrFlipANode() async throws {
        let mothership = InProcessMothership()
        let node = UUID()
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver),
            callerResolver: resolver
        ) { stub in
            _ = try await stub.register(.sample(threadId: node), metadata: metadata("ambient-secret"))

            var heartbeat = Thread_V1_HeartbeatRequest()
            heartbeat.threadID = node.uuidString
            do {
                _ = try await stub.heartbeat(heartbeat, metadata: metadata("craft-secret"))
                XCTFail("expected PERMISSION_DENIED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
            let own = try await stub.heartbeat(heartbeat, metadata: metadata("ambient-secret"))
            XCTAssertTrue(own.alive)

            var availability = Thread_V1_AvailabilityUpdateRequest()
            availability.threadID = node.uuidString
            availability.acceptingStorage = false
            do {
                _ = try await stub.updateAvailability(availability, metadata: metadata("craft-secret"))
                XCTFail("expected PERMISSION_DENIED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
        }
        let accepting = await mothership.registry.node(node)?.acceptingStorage
        XCTAssertEqual(accepting, true, "craft's refused update changed nothing")
    }

    func testAnotherAppCannotOpenANodesSession() async throws {
        let mothership = InProcessMothership()
        let node = UUID()
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver),
            callerResolver: resolver
        ) { stub in
            _ = try await stub.register(.sample(threadId: node), metadata: metadata("ambient-secret"))
            do {
                try await stub.session(metadata: metadata("craft-secret"), requestProducer: { writer in
                    try await writer.write(.ping(threadId: node))
                }, onResponse: { response in
                    for try await _ in response.messages {}
                })
                XCTFail("expected PERMISSION_DENIED")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .permissionDenied)
            }
        }
        let open = await mothership.sessionManager.hasSession(for: node)
        XCTAssertFalse(open, "the refused session never took the slot")
    }

    func testASessionForAnUnregisteredNodeMustRegisterFirst() async throws {
        let mothership = InProcessMothership()
        try await mothership.run(
            serverInterceptors: StackSecretServerInterceptor.forLocalMode(resolver: resolver),
            callerResolver: resolver
        ) { stub in
            do {
                try await stub.session(metadata: metadata("ambient-secret"), requestProducer: { writer in
                    try await writer.write(.ping(threadId: UUID()))
                }, onResponse: { response in
                    for try await _ in response.messages {}
                })
                XCTFail("expected FAILED_PRECONDITION")
            } catch let error as RPCError {
                XCTAssertEqual(error.code, .failedPrecondition)
            }
        }
    }

    func testWithoutAResolverNodesHaveNoAppAndNothingIsChecked() async throws {
        let mothership = InProcessMothership()
        let node = UUID()
        try await mothership.run { stub in
            _ = try await stub.register(.sample(threadId: node))
            _ = try await stub.register(.sample(threadId: node))
        }
        let app = await mothership.registry.node(node)?.app
        XCTAssertNil(app)
        XCTAssertTrue(StackSecretServerInterceptor.forLocalMode(resolver: nil).isEmpty)
    }

    func testFleetsFourArgumentNodeStillHasNoApp() {
        let node = ThreadNode(threadId: UUID(), host: "127.0.0.1", grpcPort: 1, httpPort: 2)
        XCTAssertNil(node.app)
    }
}

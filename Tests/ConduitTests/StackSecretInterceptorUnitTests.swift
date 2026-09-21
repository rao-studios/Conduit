//
//  StackSecretInterceptorUnitTests.swift
//  ConduitTests
//
//  The interceptors driven by hand, no transport: the peer check runs before
//  the secret is read, a refusal never reaches `next` and never logs the
//  value, and the client stamps exactly one header when it has a secret.
//

import Foundation
import GRPCCore
import XCTest
@testable import Conduit

final class StackSecretInterceptorUnitTests: XCTestCase {

    private static let descriptor = MethodDescriptor(
        fullyQualifiedService: "thread.v1.ThreadRegistration", method: "Register")

    private static func serverContext(peer: String) -> ServerContext {
        ServerContext(
            descriptor: descriptor, remotePeer: peer,
            localPeer: "ipv4:127.0.0.1:50051", cancellation: .init())
    }

    private static func serverRequest(metadata: Metadata) -> StreamingServerRequest<String> {
        StreamingServerRequest(
            metadata: metadata,
            messages: RPCAsyncSequence(wrapping: AsyncThrowingStream<String, any Error> { $0.finish() }))
    }

    /// Runs the interceptor and reports whether `next` ran (`.success`) or
    /// what it threw (`.failure`). Fails the test if both happened.
    private static func run(
        _ interceptor: StackSecretServerInterceptor,
        metadata: Metadata,
        peer: String,
        file: StaticString = #filePath, line: UInt = #line
    ) async -> Result<Bool, any Error> {
        let reachedNext = Box(false)
        do {
            _ = try await interceptor.intercept(
                request: serverRequest(metadata: metadata),
                context: serverContext(peer: peer)
            ) { _, _ in
                reachedNext.value = true
                return StreamingServerResponse(of: String.self, metadata: [:]) { _ in [:] }
            }
            return .success(reachedNext.value)
        } catch {
            XCTAssertFalse(reachedNext.value, "next must not run on a refusal", file: file, line: line)
            return .failure(error)
        }
    }

    private static func assertRefused(
        _ result: Result<Bool, any Error>, with code: RPCError.Code,
        file: StaticString = #filePath, line: UInt = #line
    ) {
        switch result {
        case .success:
            XCTFail("expected \(code), but next ran", file: file, line: line)
        case .failure(let error):
            guard let rpcError = error as? RPCError else {
                return XCTFail("expected RPCError, got \(error)", file: file, line: line)
            }
            XCTAssertEqual(rpcError.code, code, file: file, line: line)
        }
    }

    // MARK: - Server

    func testNonLoopbackPeerIsDeniedEvenWithTheRightSecret() async {
        let interceptor = StackSecretServerInterceptor(secret: "s")
        let result = await Self.run(interceptor, metadata: ["x-ambient-secret": "s"], peer: "ipv4:10.0.0.4:52344")
        Self.assertRefused(result, with: .permissionDenied)
    }

    func testLoopbackWithoutTheHeaderIsUnauthenticated() async {
        let interceptor = StackSecretServerInterceptor(secret: "s")
        let result = await Self.run(interceptor, metadata: [:], peer: "ipv4:127.0.0.1:52344")
        Self.assertRefused(result, with: .unauthenticated)
    }

    func testLoopbackWithTheWrongSecretIsUnauthenticated() async {
        let interceptor = StackSecretServerInterceptor(secret: "s")
        let result = await Self.run(interceptor, metadata: ["x-ambient-secret": "t"], peer: "ipv6:[::1]:52344")
        Self.assertRefused(result, with: .unauthenticated)
    }

    func testLoopbackWithTheRightSecretReachesNext() async throws {
        let interceptor = StackSecretServerInterceptor(secret: "s")
        let result = await Self.run(interceptor, metadata: ["x-ambient-secret": "s"], peer: "in-process:7")
        XCTAssertTrue(try result.get())
    }

    func testLoopbackRequirementCanBeTurnedOff() async throws {
        let interceptor = StackSecretServerInterceptor(secret: "s", requireLoopbackPeer: false)
        let result = await Self.run(interceptor, metadata: ["x-ambient-secret": "s"], peer: "ipv4:10.0.0.4:52344")
        XCTAssertTrue(try result.get())
    }

    func testRefusalsNameTheMethodAndPeerButNeverTheValue() async {
        let logger = RecordingLogger()
        let interceptor = StackSecretServerInterceptor(secret: "s", logger: logger)
        let guess = "wrong-guess-7f3a"
        _ = await Self.run(interceptor, metadata: ["x-ambient-secret": .string(guess)], peer: "ipv4:127.0.0.1:52344")
        _ = await Self.run(interceptor, metadata: ["x-ambient-secret": "s"], peer: "ipv4:10.0.0.4:52344")

        XCTAssertEqual(logger.warnings.count, 2)
        XCTAssertTrue(logger.warnings.allSatisfy { $0.contains("thread.v1.ThreadRegistration/Register") })
        XCTAssertTrue(logger.warnings.contains { $0.contains("ipv4:127.0.0.1:52344") })
        XCTAssertTrue(logger.warnings.contains { $0.contains("ipv4:10.0.0.4:52344") })
        XCTAssertFalse(logger.lines.contains { $0.contains(guess) }, "the presented value must never be logged")
    }

    // MARK: - Client

    private static func stampedMetadata(
        by interceptor: StackSecretClientInterceptor, starting metadata: Metadata
    ) async throws -> Metadata {
        let seen = Box<Metadata?>(nil)
        let request = StreamingClientRequest<String>(metadata: metadata) { _ in }
        let context = ClientContext(descriptor: descriptor, remotePeer: "ipv4:127.0.0.1:50051", localPeer: "ipv4:127.0.0.1:52344")
        _ = try await interceptor.intercept(request: request, context: context) { request, _ in
            seen.value = request.metadata
            return StreamingClientResponse(of: String.self, error: RPCError(code: .cancelled, message: "stub"))
        }
        return try XCTUnwrap(seen.value, "next was not invoked")
    }

    func testClientWithoutASecretLeavesMetadataUntouched() async throws {
        let interceptor = StackSecretClientInterceptor(secret: { nil })
        let metadata = try await Self.stampedMetadata(by: interceptor, starting: ["other": "kept"])
        XCTAssertTrue(Array(metadata[stringValues: StackSecretMetadata.key]).isEmpty)
        XCTAssertEqual(Array(metadata[stringValues: "other"]), ["kept"])
        XCTAssertEqual(metadata.count, 1)
    }

    func testClientWithAnEmptySecretLeavesMetadataUntouched() async throws {
        let interceptor = StackSecretClientInterceptor(secret: "")
        let metadata = try await Self.stampedMetadata(by: interceptor, starting: [:])
        XCTAssertTrue(Array(metadata[stringValues: StackSecretMetadata.key]).isEmpty)
    }

    func testClientStampsExactlyOneSecret() async throws {
        let interceptor = StackSecretClientInterceptor(secret: { "s" })
        // A stale value already on the request is replaced, not joined.
        let metadata = try await Self.stampedMetadata(by: interceptor, starting: ["x-ambient-secret": "stale"])
        XCTAssertEqual(Array(metadata[stringValues: StackSecretMetadata.key]), ["s"])
    }
}

//
//  StackSecretMetadataTests.swift
//  ConduitTests
//
//  The pure checks behind the stack-secret interceptors: only the exact
//  secret matches, only this machine counts as loopback, and a server with
//  no secret gets no interceptor.
//

import GRPCCore
import XCTest
@testable import Conduit

final class StackSecretMetadataTests: XCTestCase {

    func testOnlyTheExactSecretMatches() {
        XCTAssertTrue(StackSecretMetadata.matches("s", secret: "s"))
        XCTAssertFalse(StackSecretMetadata.matches("s ", secret: "s"), "trailing space")
        XCTAssertFalse(StackSecretMetadata.matches("s3c", secret: "s3cret"), "prefix of the secret")
        XCTAssertFalse(StackSecretMetadata.matches("s3cret-and-more", secret: "s3cret"), "secret as a prefix")
        XCTAssertFalse(StackSecretMetadata.matches(nil, secret: "s"))
        XCTAssertFalse(StackSecretMetadata.matches("", secret: "s"))
    }

    func testPresentedReadsTheAgreedKey() {
        var metadata = Metadata()
        XCTAssertNil(StackSecretMetadata.presented(in: metadata))
        metadata.addString("s", forKey: "some-other-key")
        XCTAssertNil(StackSecretMetadata.presented(in: metadata))
        metadata.addString("s", forKey: StackSecretMetadata.key)
        XCTAssertEqual(StackSecretMetadata.presented(in: metadata), "s")
        XCTAssertEqual(StackSecretMetadata.key, "x-ambient-secret")
    }

    func testOnlyLoopbackPeersCount() {
        for peer in ["ipv4:127.0.0.1:1", "ipv6:[::1]:1", "ipv6:[::ffff:127.0.0.1]:1", "unix:/x", "in-process:7"] {
            XCTAssertTrue(StackSecretMetadata.isLoopbackPeer(peer), peer)
        }
        for peer in ["ipv4:10.0.0.4:1", "ipv6:[fe80::1]:1", "", "ipv4:127", "127.0.0.1:1", "ipv6:[::2]:1"] {
            XCTAssertFalse(StackSecretMetadata.isLoopbackPeer(peer), peer)
        }
    }

    func testForLocalModeInstallsAnInterceptorOnlyWithASecret() {
        XCTAssertTrue(StackSecretServerInterceptor.forLocalMode(secret: nil).isEmpty)
        XCTAssertTrue(StackSecretServerInterceptor.forLocalMode(secret: "").isEmpty)
        let installed = StackSecretServerInterceptor.forLocalMode(secret: "s")
        XCTAssertEqual(installed.count, 1)
        XCTAssertTrue(installed.first is StackSecretServerInterceptor)
    }
}
